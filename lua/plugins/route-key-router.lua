-- plugins/route_key_router.lua
local cjson = require "cjson.safe"
local extractor = require "extractor"
local ngx = ngx
local route_key_maps = ngx.shared.route_key_maps

local _M = {
    priority = 1000,  -- 高优先级，确保在负载均衡前执行
    name = "route-key-router",
    schema = {
        type = "object",
        properties = {
            route_key_source = { type = "string" },
            route_key_map = { type = "string" },
            rewrite = {
                type = "array",
                items = {
                    type = "object",
                    properties = {
                        regex = { type = "string" },
                        replacement = { type = "string" },
                        upstream_ids = {  -- 新增字段：指定应用此规则的上游ID列表
                            type = "array",
                            items = { type = "string" }
                        },
                        ["break"] = { type = "boolean", default = false }
                    },
                    required = { "regex", "replacement" }
                }
            }
        },
        required = { "route_key_map" }
    }
}

-- 检查当前upstream是否匹配规则
local function match_upstream(upstream_name, rule)
    if not rule.upstream_ids then
        return true  -- 未指定upstream_ids则默认匹配所有
    end

    for _, id in ipairs(rule.upstream_ids) do
        if id == upstream_name then
            return true
        end
    end
    return false
end

-- 带upstream条件判断的重写逻辑
local function apply_conditional_rewrite(uri, rules, upstream_name)
    local new_uri = uri
    for _, rule in ipairs(rules or {}) do
        -- 检查upstream匹配条件
        if match_upstream(upstream_name, rule) then
            local from = rule.regex
            local to = rule.replacement

            local sub_uri, n = ngx.re.sub(new_uri, from, to, "jo")
            if n > 0 then
                new_uri = sub_uri
                ngx.log(ngx.INFO, "rewrite applied for upstream[",
                       upstream_name, "]: ", uri, " -> ", new_uri)
                if rule["break"] then break end
            end
        end
    end
    return new_uri
end

-- 插件执行入口
function _M.execute(conf)
    -- 获取当前路由上下文
    local ctx = ngx.ctx.route_ctx or {
        uri = ngx.var.uri,
        headers = ngx.req.get_headers(),
        uri_args = ngx.req.get_uri_args(),
    }

    -- 读取请求体（仅当需要时）
    if conf.route_key_source and
       (conf.route_key_source:match("JSONBODY") or conf.route_key_source:match("BODY")) then
        ngx.req.read_body()
        ctx.body = ngx.req.get_body_data()
    end

    -- 提取路由键
    local route_key = extractor.extract_route_key(ctx, conf)
    if not route_key then
        ngx.log(ngx.ERR, "failed to extract route key")
        return
    end
    ngx.log(ngx.INFO, "route_key: ", route_key)

    -- 从路由键映射表中查找上游
    local map_name = conf.route_key_map
    local upstream_name
    if map_name then
        local map = route_key_maps:get(map_name)
        if map then
            map = cjson.decode(map)
            upstream_name = map[route_key] or map["*"]
        end
    end

    upstream_name = upstream_name or conf.upstream
    if not upstream_name then
        ngx.log(ngx.ERR, "upstream_name not found.")
        return
    end

    -- 2. 只在获取到upstream_name后执行条件重写
    if conf.rewrite then
        local new_uri = apply_conditional_rewrite(ctx.uri, conf.rewrite, upstream_name)
        if new_uri ~= ctx.uri then
            ngx.var.uri = new_uri
            ctx.uri = new_uri
        end
    end

    -- 3. 设置最终upstream
    ngx.ctx.upstream_name = upstream_name
end

return _M
