local _M = {}

local shared = ngx.shared
local cjson = require("cjson.safe")
local roundrobin = require("roundrobin")
local chash = require("chash")
local checker = require("checker")
local resty_http = require("resty.http")
local response = require("response")

local routes = shared.routes
local upstreams = shared.upstreams
local route_key_maps = shared.route_key_maps

-- 健康检查状态存储
local checker_dict = shared.checker_status

-- 节点状态常量
local STATUS_UP = "UP"
local STATUS_DOWN = "DOWN"

-- 负载均衡器缓存
local balancers = {}

-- 初始化健康检查器
local function init_checker(upstream)
    if not upstream.checks or not upstream.checks.active then
        return nil
    end

    local checker = checker:new({
        dict_name = "checker_status",
        interval = upstream.checks.active.unhealthy.interval or 1,
        http_path = upstream.checks.active.http_path or "/",
        healthy_threshold = upstream.checks.active.healthy.successes or 1,
        unhealthy_threshold = upstream.checks.active.unhealthy.http_failures or 1,
        http_timeout = upstream.timeout and upstream.timeout.connect or 15
    })

    for addr, weight in pairs(upstream.nodes) do
        local host, port = addr:match("([^:]+):?(%d*)")
        port = port or 80
        ngx.log(ngx.ERR, "nodes: ", host .. ":" .. port)
        checker:add_node(host, tonumber(port), weight)
    end

    return checker
end

local function parse_upstream_address(addr)
    -- 处理完整的URL格式 (http://host:port)
    if addr:find("://") then
        local protocol, rest = addr:match("^(%w+)://(.+)$")
        local host, port = rest:match("^([^:]+):?(%d*)$")
        port = port ~= "" and tonumber(port) or
              (protocol == "https" and 443 or 80)
        return host, port, protocol
    end

    -- 处理 host:port 格式
    local host, port = addr:match("^([^:]+):?(%d*)$")
    port = port ~= "" and tonumber(port) or 80
    ngx.log(ngx.ERR, "parse nodes: ", host .. ":" .. port)
    return host, port, "http"
end

-- 获取健康节点列表
local function get_healthy_nodes(upstream)
    if not upstream.checks or not upstream.checks.active then
        return upstream.nodes
    end
    
    local healthy_nodes = {}
    for addr, weight in pairs(upstream.nodes) do
        local host, port = parse_upstream_address(addr)
        local status_key = host .. ":" .. port
        ngx.log(ngx.ERR, "status_key: ", status_key)
        local status = checker_dict:get(status_key)
        if status ~= STATUS_DOWN then
            healthy_nodes[addr] = weight
        end
    end
    
    return next(healthy_nodes) and healthy_nodes or upstream.nodes
end

-- 更新 init_balancer 函数
local function init_balancer(upstream)
    -- 确保有健康的节点
    local nodes = get_healthy_nodes(upstream)
    if not nodes or not next(nodes) then
        ngx.log(ngx.ERR, "no healthy nodes available for upstream: ", upstream.id)
        return nil, "no healthy nodes"
    end

    -- 转换节点格式（同时保留原始地址用于proxy_pass）
    local normalized_nodes = {}
    local original_addresses = {} -- 新增：保留原始地址映射
    
    for addr, weight in pairs(nodes) do
        local host, port, protocol = parse_upstream_address(addr)
        local normalized_addr = host..":"..port
        ngx.log(ngx.ERR, "normalized_addr: ", normalized_addr)
        normalized_nodes[normalized_addr] = weight
        original_addresses[normalized_addr] = addr -- 保存原始地址
    end

    upstream.original_addresses = original_addresses -- 将映射保存到upstream对象中

    -- 确保 upstream.type 有默认值
    upstream.type = upstream.type or "roundrobin"

    -- 调试日志
    ngx.log(ngx.DEBUG, "initializing balancer for upstream: ", upstream.id, 
            " type: ", upstream.type, " nodes: ", cjson.encode(nodes))

    local balancer, err
    
    if upstream.type == "roundrobin" then
        -- 安全调用 roundrobin.new
        local ok, rr = pcall(roundrobin.new, normalized_nodes)
        if not ok or not rr then
            err = "failed to create roundrobin: " .. (rr or "unknown error")
            ngx.log(ngx.ERR, err)
            return nil, err
        end
        balancer = rr
    elseif upstream.type == "chash" then
        -- 安全调用 chash.new
        local servers = {}
        for addr, weight in pairs(normalized_nodes) do
            table.insert(servers, {key = addr, weight = weight})
        end
        
        local ok, ch = pcall(chash.new, servers)
        if not ok or not ch then
            err = "failed to create chash: " .. (ch or "unknown error")
            ngx.log(ngx.ERR, err)
            return nil, err
        end
        balancer = ch
    elseif upstream.type == "least_conn" then
        -- 最少连接数实现
        balancer = {
            nodes = normalized_nodes,
            get = function(self)
                local min_conn = math.huge
                local selected
                
                for addr, weight in pairs(self.nodes) do
                    local conn = (ngx.ctx.conn_counts[addr] or 0) + 1
                    local score = conn / weight
                    
                    if score < min_conn then
                        min_conn = score
                        selected = addr
                    end
                end
                
                ngx.ctx.conn_counts = ngx.ctx.conn_counts or {}
                ngx.ctx.conn_counts[selected] = (ngx.ctx.conn_counts[selected] or 0) + 1
                return selected
            end
        }
    elseif upstream.type == "ewma" then
        -- EWMA 实现
        balancer = {
            nodes = normalized_nodes,
            latencies = {},
            get = function(self)
                local min_latency = math.huge
                local selected
                
                for addr in pairs(self.nodes) do
                    local latency = self.latencies[addr] or 0
                    if latency < min_latency then
                        min_latency = latency
                        selected = addr
                    end
                end
                
                return selected or next(self.nodes)
            end,
            report_latency = function(self, addr, latency)
                local α = 0.3  -- 平滑系数
                self.latencies[addr] = α * latency + (1 - α) * (self.latencies[addr] or 0)
            end
        }
    else
        err = "unknown balancer type: " .. (upstream.type or "nil")
        ngx.log(ngx.ERR, err)
        return nil, err
    end

    return balancer
end

local function get_balancer(upstream)
    if not upstream or not upstream.id then
        ngx.log(ngx.ERR, "upstream id is missing")
        return nil, "upstream id missing"
    end

    -- 检查是否已有缓存的负载均衡器
    if balancers[upstream.id] then
        return balancers[upstream.id]
    end

    -- 初始化新的负载均衡器
    local ok, balancer, err = pcall(init_balancer, upstream)
    if not ok or not balancer then
        ngx.log(ngx.ERR, "failed to init balancer for upstream: ", upstream.id, 
                " err: ", err or (not ok and "pcall failed" or "unknown error"))
        return nil, err or "balancer init failed"
    end

    balancers[upstream.id] = balancer
    return balancer
end

---- 获取负载均衡器
--local function get_balancer(upstream)
--    if not upstream or not upstream.id then
--        ngx.log(ngx.ERR, "upstream id is missing")
--        return nil
--    end
--
--    -- 确保有健康的节点
--    local nodes = get_healthy_nodes(upstream)
--    if not nodes or not next(nodes) then
--        ngx.log(ngx.ERR, "no healthy nodes available for upstream: ", upstream.id)
--        return nil
--    end
--
--    -- 初始化或获取缓存的负载均衡器
--    if not balancers[upstream.id] then
--        local ok, balancer = pcall(init_balancer, upstream)
--        if not ok or not balancer then
--            ngx.log(ngx.ERR, "failed to init balancer for upstream: ", upstream.id, " err: ", balancer)
--            return nil
--        end
--        balancers[upstream.id] = balancer
--    end
--
--    return balancers[upstream.id]
--end


-- 执行健康检查
local function perform_health_check(checker)
    if not checker then return end

    local httpc = resty_http.new()
    local nodes = checker:get_nodes()

    for _, node in ipairs(nodes) do
        ngx.log(ngx.ERR, "health_check: ", node.host .. ":" .. node.port)
        local ok, err = httpc:connect(node.host, node.port)
        if ok then
            local res, err = httpc:request({
                path = checker.http_path,
                method = "GET",
                headers = {
                    ["Host"] = node.host
                }
            })

            if res and res.status == 200 then
                checker:report_success(node.host, node.port)
            else
                checker:report_failure(node.host, node.port)
            end
            httpc:close()
        else
            checker:report_failure(node.host, node.port)
        end
    end
end

-- 定时健康检查
local function health_check_timer(premature)
    if premature then return end

    local all_upstreams = upstreams:get_keys()
    for _, id in ipairs(all_upstreams) do
        local upstream = upstreams:get(id)
        if upstream then
            upstream = cjson.decode(upstream)
            local checker = init_checker(upstream)
            perform_health_check(checker)
        end
    end

    -- 每分钟检查一次
    ngx.timer.at(60, health_check_timer)
end

-- 启动健康检查定时器
ngx.timer.at(0, health_check_timer)

-- 获取route_key
local function get_route_key(route_key_source, body)
    -- 实现从请求体中提取route_key的逻辑
    -- 使用正则表达式匹配route_key_source模式
    -- 返回提取到的route_key或nil
end

-- 设置超时
local function setup_timeout(upstream)
    if upstream.timeout then
        ngx.var.upstream_connect_timeout = upstream.timeout.connect or 15
        ngx.var.upstream_send_timeout = upstream.timeout.send or 15
        ngx.var.upstream_read_timeout = upstream.timeout.read or 15
    end
end

-- 设置重试
local function setup_retries(upstream)
    if upstream.retries and upstream.retries > 0 then
        ngx.var.upstream_max_fails = upstream.retries
        ngx.var.upstream_fail_timeout = "10s" -- 默认失败超时
    end
end

function _M.route()
    local uri = ngx.var.uri
    local method = ngx.req.get_method()

    -- 获取所有路由
    local all_routes = routes:get_keys()

    for _, route_id in ipairs(all_routes) do
        local route = routes:get(route_id)
        if route then
            route = cjson.decode(route)

            -- 检查方法和URI是否匹配
            local method_match = false
            for _, m in ipairs(route.methods) do
                if m == method or m == "*" then
                    method_match = true
                    break
                end
            end

            local uri_match = ngx.re.match(uri, route.uri)

            if method_match and uri_match then
                -- 初始化插件上下文
                ngx.ctx.route_ctx = {
                    uri = uri,
                    method = method,
                    headers = ngx.req.get_headers(),
                    uri_args = ngx.req.get_uri_args(),
                }

                -- 执行插件链
                if route.plugins then
                    for plugin_name, plugin_conf in pairs(route.plugins) do
                        local plugin = require("plugins." .. plugin_name)
                        plugin.execute(plugin_conf)
                    end
                end

                -- 确定上游（优先使用插件设置的上游）
                local upstream_name = ngx.ctx.upstream_name or route.upstream
                if not upstream_name then
                    response.exit(500, "no upstream for route: " .. route_id)
                end

                local upstream = upstreams:get(upstream_name)
                if not upstream then
                    response.exit(502, "upstream not found: " .. upstream_name)
                    return
                end

                upstream = cjson.decode(upstream)
                if not upstream or not upstream.nodes then
                    response.exit(502, "invalid upstream config: " .. upstream_name)
                    return
                end

                -- 确保有id字段
                upstream.id = upstream.id or upstream_name

                -- 设置超时和重试
                setup_timeout(upstream)
                setup_retries(upstream)

                -- 获取负载均衡器
                local balancer = get_balancer(upstream)
                if not balancer then
                    response.exit(502, "failed to get balancer for upstream:: " .. upstream.id)
                    return
                end

                ngx.log(ngx.DEBUG, "select balancer...")
                -- 选择节点
                local selected
                ngx.log(ngx.DEBUG, "upstream.type: ", upstream.type)
                if upstream.type == "chash" then
                    local key = upstream.key or ngx.var.remote_addr
                    selected = balancer:find(key)
                    ngx.log(ngx.DEBUG, "11111")
                else
                    selected = balancer:get()
                    ngx.log(ngx.DEBUG, "22222")
                end

                if selected then
                    -- 设置上游
                    local scheme = upstream.scheme or "http"
                    ngx.var.upstream = scheme .. "://" .. selected

                    ngx.log(ngx.DEBUG, "ngx.var.upstream: ", ngx.var.upstream)
                    -- 记录开始时间用于EWMA计算
                    if upstream.type == "ewma" then
                        ngx.ctx.request_start_time = ngx.now()
                    end

                    return
                end
            end
        end
    end

    response.exit(404, "The request did not match the route.")
end

-- 在请求结束后更新EWMA延迟
function _M.after_route()
    if ngx.var.upstream and ngx.ctx.request_start_time then
        local latency = ngx.now() - ngx.ctx.request_start_time
        local upstream_name = ngx.var.upstream:match("://([^/]+)")
        local all_upstreams = upstreams:get_keys()

        for _, id in ipairs(all_upstreams) do
            local upstream = upstreams:get(id)
            if upstream then
                upstream = cjson.decode(upstream)
                if upstream.type == "ewma" then
                    for addr in pairs(upstream.nodes) do
                        if addr == upstream_name then
                            local balancer = get_balancer(upstream)
                            balancer:report_latency(addr, latency)
                            break
                        end
                    end
                end
            end
        end
    end
end

return _M
