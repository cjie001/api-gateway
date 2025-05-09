-- access.lua
local extractor   = require "router.extractor"
local balancer    = require "router.balancer"
local circuit     = require "router.circuit_break"
local cjson       = require "cjson.safe"
local utils       = require "utils"
local ngx         = ngx

-- 共享字典配置
local LIMIT_SHARED_DICT = "limit_shared_dict"
local shared_dict = ngx.shared[LIMIT_SHARED_DICT]

local _M = {}

-- 统一错误响应
local function error_response(status, message, headers)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"

    if headers then
        for k, v in pairs(headers) do
            ngx.header[k] = v
        end
    end

    ngx.say(cjson.encode({
        error = {
            code = status,
            message = message,
            request_id = ngx.var.request_id or ""
        }
    }))
    ngx.exit(status)
end

-- 初始化限流器（按需初始化）
local limiters
local function get_limiter(strategy)
    if not limiters then
        limiters = {
            conn = require("resty.limit.conn").new(LIMIT_SHARED_DICT, 10000, 100, 0.5),
            req  = require("resty.limit.req").new(LIMIT_SHARED_DICT, 10000, 100),
            count = require("resty.limit.count").new(LIMIT_SHARED_DICT, 10000, 100)
        }
    end
    return limiters[strategy]
end

-- 构建请求上下文
local function build_context()
    ngx.req.read_body()
    local body = string.sub(ngx.req.get_body_data() or "", 1, 1024)

    return {
        uri = ngx.var.uri,
        headers = ngx.req.get_headers(),
        uri_args = ngx.req.get_uri_args(),
        method = ngx.req.get_method(),
        body = body
    }
end

-- 查找匹配的路由规则
local function find_matched_route(ctx)
    local matched_uris = {}
    for _, uri in pairs(ngx.shared.uri_rules:get_keys()) do
        if ctx.uri:match("^"..uri) then
            table.insert(matched_uris, uri)
        end
    end

    table.sort(matched_uris, function(a, b) return #a > #b end)

    if #matched_uris == 0 then
        return nil, "No matching URI rule found"
    end

    return matched_uris
end

-- 获取路由配置
local function get_route_config(route_id)
    local config_str = ngx.shared.route_configs:get(route_id)
    if not config_str then
        return nil, "No config found for route_id"
    end

    return cjson.decode(config_str)
end

-- 应用重写规则
local function apply_rewrite(config)
    if config.rewrite then
        require("router.rewrite").apply(config.rewrite)
    end
end

-- 执行限流检查（仅在配置存在时执行）
local function check_rate_limit(config, route_id, ctx)
    -- 检查是否配置了限流
    if not config or not config.rate_limit then
        return -- 未配置限流规则，直接跳过
    end

    local limit_key = ctx.route_key
    if config.rate_limit.key_template then
        limit_key = extractor.build_limit_key(config.rate_limit.key_template, ctx)
    end

    -- 组合限流键
    local composite_key = route_id .. ":" .. limit_key
    ngx.log(ngx.INFO, "composite_key: ", composite_key)
    local strategy = config.rate_limit.strategy or "req"

    -- 延迟初始化限流器
    local limiter = get_limiter(strategy)
    if not limiter then
        ngx.log(ngx.ERR, "Invalid rate limit strategy: ", strategy)
        return
    end

    -- 根据策略获取配置
    local limit_config
    if strategy == "conn" then
        limit_config = {
            burst = config.rate_limit.burst or 100,
            default_conn_delay = config.rate_limit.delay or 0.5
        }
    elseif strategy == "count" then
        limit_config = {
            window = config.rate_limit.window or 60,
            count = config.rate_limit.count or 1000
        }
    else -- req
        limit_config = {
            rate = config.rate_limit.rate or 100,
            burst = config.rate_limit.burst or 50
        }
    end

    -- 执行限流检查
    local delay, err = limiter:incoming(composite_key, true, limit_config)
    if not delay then
        if err == "rejected" then
            local headers = {
                ["X-RateLimit-Limit"] = limit_config.rate or limit_config.count,
                ["X-RateLimit-Strategy"] = strategy
            }
            error_response(429, "Rate limit exceeded", headers)
        else
            ngx.log(ngx.ERR, "Rate limit error: ", err)
        end
    elseif delay > 0 then
        -- 需要延迟处理
        ngx.sleep(delay)
    end
end

-- 执行熔断检查（仅在配置存在时执行）
local function check_circuit_break(config, route_id)
    -- 检查是否配置了熔断
    if not config or not config.circuit_break then
        return -- 未配置熔断规则，直接跳过
    end

    local is_open, stats = circuit.is_open(route_id, config.circuit_break)
    if is_open then
        error_response(503, "Service unavailable (circuit breaker open)", {
            ["X-Circuit-Break"] = "open",
            ["X-Circuit-Break-Retry-After"] = stats.retry_after
        })
    end
end

-- 获取路由组配置（包含key_map_ref和key_source）
local function get_route_group(matched_uris)
    for _, uri in ipairs(matched_uris) do
        local group_str = ngx.shared.route_key_maps:get("uri:"..uri)
        if group_str then
            return cjson.decode(group_str)
        end
    end
    return nil
end

-- 获取路由键映射
local function get_route_key_map(map_name)
    local map_str = ngx.shared.route_key_maps:get("map:"..map_name)
    if not map_str then
        return nil, "No route key map found for: "..map_name
    end
    return cjson.decode(map_str)
end

function _M.handle()
    -- 1. 构建请求上下文
    local ctx = build_context()

    -- 2. 查找匹配的路由规则
    local matched_uris, err = find_matched_route(ctx)
    if not matched_uris then
        error_response(404, err)
    end

    -- 3. 获取路由组配置（包含key_map_ref和key_source）
    local route_group = get_route_group(matched_uris)
    if not route_group then
        error_response(404, "No route group found")
        return
    end

    -- 4. 获取路由键映射
    local route_key_map, err = get_route_key_map(route_group.key_map_ref)
    if not route_key_map then
        error_response(404, err)
        return
    end

    -- 5. 提取路由因子
    local route_key = extractor.extract_route_key(ctx, {
        route_key_source = route_group.key_source
    })
    if not route_key then
        error_response(400, "Failed to extract route key")
        return
    end
    ngx.req.set_header("X-Route-Key", route_key)

    -- 6. 获取路由ID
    local route_id = route_key_map[route_key] or route_key_map["*"]
    if not route_id then
        error_response(404, "No route mapping for key: "..route_key)
        return
    end
    ngx.var.route_id = route_id
    ngx.req.set_header("X-Route-Id", route_id)

    -- 7. 获取路由配置
    local config, err = get_route_config(route_id)
    if not config then
        error_response(404, err)
    end

    -- 8. 应用重写规则
    apply_rewrite(config)

    -- 9. 限流检查（仅在配置存在时执行）
    check_rate_limit(config, route_id, ctx)

    -- 10. 熔断检查（仅在配置存在时执行）
    check_circuit_break(config, route_id)

    -- 11. 负载均衡处理
    local node, err = balancer.select_node(config.upstream_id)
    if not node then
        error_response(503, "No available upstream nodes: " .. (err or "unknown"))
    end

    -- 设置后端节点变量
    ngx.var.backend_host = node.host
    ngx.var.backend_port = node.port
end

return _M
