local cjson = require "cjson.safe"
local utils = require "utils"
local ngx = ngx

local _M = {
    MAX_ITEMS = 1000,  -- 最大返回条目数限制
    CACHE_TTL = 5      -- 缓存时间(秒)
}

-- 本地缓存状态数据
local status_cache = require "resty.lrucache".new(1)  -- 仅缓存最新状态

-- 获取所有URI路由规则
local function get_uri_rules()
    local data = {}
    local keys = ngx.shared.uri_rules:get_keys(_M.MAX_ITEMS)

    for _, uri in ipairs(keys) do
        data[uri] = true
    end

    return data
end

-- 获取路由键映射
--local function get_route_key_maps()
--    local data = {}
--    local keys = ngx.shared.route_key_maps:get_keys(_M.MAX_ITEMS)
--
--    for _, key in ipairs(keys) do
--        local val = ngx.shared.route_key_maps:get(key)
--        data[key] = val and cjson.decode(val) or val
--    end
--
--    return data
--end
local function get_route_key_maps()
    local data = {}
    local keys = ngx.shared.route_key_maps:get_keys()

    for _, key in ipairs(keys) do
        local val = ngx.shared.route_key_maps:get(key)
        if val then
            data[key] = {
                uris = utils.split(key, ","),
                config = cjson.decode(val)
            }
        end
    end

    return data
end

-- 获取路由配置
local function get_route_configs()
    local data = {}
    local keys = ngx.shared.route_configs:get_keys(_M.MAX_ITEMS)

    for _, key in ipairs(keys) do
        local val = ngx.shared.route_configs:get(key)
        data[key] = val and cjson.decode(val) or val
    end

    return data
end

-- 获取上游节点配置
local function get_upstreams()
    local data = {}
    local keys = ngx.shared.upstreams:get_keys(_M.MAX_ITEMS)

    for _, key in ipairs(keys) do
        local val = ngx.shared.upstreams:get(key)
        data[key] = val and cjson.decode(val) or val
    end

    return data
end

-- 获取完整的规则快照
local function get_full_snapshot()
    local snapshot = {
        timestamp = ngx.time(),
        uri_rules = get_uri_rules(),
        route_key_maps = get_route_key_maps(),
        route_configs = get_route_configs(),
        upstreams = get_upstreams(),
        rules_api_url = ngx.shared.rules_api_url:get("rules_api_url"),
        memory_stats = {
            uri_rules = ngx.shared.uri_rules:capacity(),
            route_key_maps = ngx.shared.route_key_maps:capacity(),
            route_configs = ngx.shared.route_configs:capacity(),
            upstreams = ngx.shared.upstreams:capacity()
        }
    }

    -- 添加版本信息
    snapshot._version = "1.1.0"
    snapshot._schema = "enhanced"

    return snapshot
end

-- 获取过滤后的状态数据
function _M.query(args)
    -- 检查缓存
    local cached = status_cache:get("last_snapshot")
    if cached and not args.nocache then
        return cached
    end

    local response

    if args.full or not (args.uri_rules or args.route_key_maps or args.routes or args.upstreams) then
        -- 返回完整快照
        response = get_full_snapshot()
    else
        -- 按需返回部分数据
        response = {
            timestamp = ngx.time(),
            uri_rules = args.uri_rules and get_uri_rules() or nil,
            route_key_maps = args.route_key_maps and get_route_key_maps() or nil,
            route_configs = args.routes and get_route_configs() or nil,
            upstreams = args.upstreams and get_upstreams() or nil
        }
    end

    -- 更新缓存
    status_cache:set("last_snapshot", response, _M.CACHE_TTL)

    return response
end

-- 获取健康状态
function _M.health()
    return {
        status = "ok",
        timestamp = ngx.time(),
        memory = {
            uri_rules = ngx.shared.uri_rules:capacity(),
            route_key_maps = ngx.shared.route_key_maps:capacity(),
            route_configs = ngx.shared.route_configs:capacity(),
            upstreams = ngx.shared.upstreams:capacity()
        },
        uptime = ngx.now() - ngx.req.start_time()
    }
end

-- response.data.rules_api_url = ngx.shared.rules_api_url:get("rules_api_url")
return _M
