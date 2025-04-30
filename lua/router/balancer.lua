-- balancer.lua
local _M = {}
local balancer = require "ngx.balancer"
local cjson = require "cjson.safe"
local ngx = ngx
local resty_lrucache = require "resty.lrucache"

-- 初始化缓存
local node_cache = resty_lrucache.new(1000)  -- 缓存1000条路由的节点配置
local upstream_cache = resty_lrucache.new(1000)  -- 缓存1000个upstream配置

-- 生成加权随机选择表（预计算优化）
local function build_weight_table(nodes)
    local weight_table = {}
    local total_weight = 0

    for _, node in ipairs(nodes) do
        local weight = node.weight or 1  -- 默认权重为1
        if weight > 0 then
            total_weight = total_weight + weight
            table.insert(weight_table, {
                node = node,
                upper = total_weight
            })
        end
    end

    return weight_table, total_weight
end

-- 带权重的随机选择算法（O(1)时间复杂度）
local function weighted_random(nodes)
    local weight_table, total_weight = build_weight_table(nodes)
    if #weight_table == 0 then
        return nil, "no available nodes"
    end

    local rand = math.random() * total_weight
    local left, right = 1, #weight_table

    -- 二分查找优化
    while left <= right do
        local mid = math.floor((left + right) / 2)
        if rand <= weight_table[mid].upper then
            if mid == 1 or rand > weight_table[mid-1].upper then
                return weight_table[mid].node
            end
            right = mid - 1
        else
            left = mid + 1
        end
    end

    return weight_table[#weight_table].node  -- 兜底返回最后一个
end

-- 获取节点配置（支持直接nodes和upstream_id两种方式）
local function get_nodes(route_id, route_config)
    -- 1. 检查是否有直接配置的nodes
    if route_config.nodes then
        return route_config.nodes
    end

    -- 2. 检查是否有upstream_id配置
    if route_config.upstream_id then
        -- 先从缓存获取
        local cached = upstream_cache:get(route_config.upstream_id)
        if cached then return cached end

        -- 从共享内存获取
        local upstream_str = ngx.shared.upstreams:get(route_config.upstream_id)
        if upstream_str then
            local nodes = cjson.decode(upstream_str)
            if nodes then
                -- 缓存5秒
                upstream_cache:set(route_config.upstream_id, nodes, 5)
                return nodes
            end
        end
    end

    return nil
end

-- 获取路由配置（带缓存优化）
local function get_route_config(route_id)
    -- 优先从缓存读取
    local cached = node_cache:get(route_id)
    if cached then return cached end

    local config_str = ngx.shared.route_configs:get(route_id)
    if not config_str then return nil end

    local ok, config = pcall(cjson.decode, config_str)
    if not ok then return nil end

    -- 缓存配置（有效期5秒）
    node_cache:set(route_id, config, 5)
    return config
end

-- 健康检查标记（简单实现，生产环境建议使用更复杂的健康检查机制）
local function mark_unhealthy(node)
    -- 这里可以扩展实现健康检查逻辑
    -- 例如将不健康节点记录到共享内存中
    ngx.log(ngx.WARN, "Marking node as unhealthy: ",
           node.host, ":", node.port)
end

function _M.select_node(route_id)
    -- 获取路由配置
    local route_config = get_route_config(route_id)
    if not route_config then
        return nil, "route config not found"
    end

    -- 获取节点列表
    local nodes = get_nodes(route_id, route_config)
    if not nodes or #nodes == 0 then
        return nil, "no available nodes"
    end

    -- 选择节点
    local node, err = weighted_random(nodes)
    if not node then
        return nil, err
    end

    return node
end

function _M.set_peer(node)
    -- 设置上游节点
    local ok, err = balancer.set_current_peer(node.host, node.port)
    if not ok then
        mark_unhealthy(node)
        return false, err
    end

    -- 设置超时参数（生产推荐值）
    balancer.set_timeouts(3000, 5000, 10000)  -- 连接3s/发送5s/读取10s

    -- 记录调试信息（生产环境建议关闭）
    ngx.ctx.selected_node = node
    ngx.log(ngx.DEBUG, "Selected node: ",
           node.host, ":", node.port, " weight:", node.weight or 1)

    return true
end

function _M.route()
    local route_id = ngx.var.route_id
    if not route_id then
        ngx.log(ngx.ERR, "route_id not found in ngx.var")
        return ngx.exit(503)
    end

    -- 选择节点
    local node, err = _M.select_node(route_id)
    if not node then
        ngx.log(ngx.ERR, "node select failed: ", err)
        return ngx.exit(503)
    end

    -- 设置节点
    local ok, err = _M.set_peer(node)
    if not ok then
        ngx.log(ngx.ERR, "set peer failed: ", err)
        return ngx.exit(502)
    end
end

return _M
