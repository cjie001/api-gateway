local cjson = require "cjson.safe"
local ngx = ngx

local _M = {}

-- 解析JSON body（带缓存优化）
local json_cache = require "resty.lrucache".new(100)
local function parse_json_body(body)
    if not body or body == "" then return nil end

    -- 检查缓存
    local cached = json_cache:get(body)
    if cached then return cached end

    -- 解析JSON
    local ok, data = pcall(cjson.decode, body)
    if ok and data then
        json_cache:set(body, data, 5)  -- 缓存5秒
        return data
    end
    return nil
end

-- 从请求中提取变量值
function _M.extract_var(key, ctx)
    -- 支持 HEADER['X-Merchant-Id'] 格式
    if key:match("^HEADER%[") then
        local header_name = key:match("^HEADER%['([^']+)'%]") or
                           key:match('^HEADER%["([^"]+)"%]')
        if header_name then
            return ctx.headers[header_name:lower()]
        end

    -- 支持 QUERY['mchntCd'] 格式
    elseif key:match("^QUERY%[") then
        local param = key:match("^QUERY%['([^']+)'%]") or
                     key:match('^QUERY%["([^"]+)"%]')
        if param and ctx.uri_args then
            return ctx.uri_args[param]
        end

    -- 支持 BODY['merchant_id'] 格式
    elseif key:match("^BODY%[") then
        local param = key:match("^BODY%['([^']+)'%]") or
                     key:match('^BODY%["([^"]+)"%]')
        if param and ctx.body then
            -- 尝试解析JSON
            local json_data = parse_json_body(ctx.body)
            if json_data and json_data[param] then
                return json_data[param]
            end

            -- 简单模式匹配（兼容非JSON格式）
            local value = ctx.body:match('"'..param..'"%s*:%s*"([^"]+)"') or  -- "key":"value"
                         ctx.body:match("'"..param.."'%s*:%s*'([^']+)'") or  -- 'key':'value'
                         ctx.body:match('"'..param..'"%s*:%s*([^,}]+)')     -- "key":123
            return value
        end

    -- 支持直接变量引用
    elseif key == "${route_key}" then
        return ctx.route_key
    elseif key == "${uri}" then
        return ctx.uri
    end

    return nil
end

-- 解析路由因子模板
function _M.build_route_key(template, ctx)
    if not template or template == "" then
        return nil
    end

    -- 如果是简单字符串，直接返回
    if not template:match("[%[%]{}]") then
        return template
    end

    -- 处理 ${HEADER['X-Merchant-Id']} 格式
    if template:match("^%${.*}$") then
        local key = template:match("^%${(.*)}$")
        return _M.extract_var(key, ctx)
    end

    -- 处理复合表达式 ${HEADER['X-Merchant-Id']}_${QUERY['type']}
    return (template:gsub("%${([^}]+)}", function(inner)
        return _M.extract_var(inner, ctx) or ""
    end))
end

-- 从路由配置中提取路由因子
function _M.extract_route_key(ctx, route_config)
    -- 如果没有配置route_key_source，使用默认route_key
    if not route_config or not route_config.route_key_source then
        return "default"
    end

    -- 根据配置提取路由因子
    return _M.build_route_key(route_config.route_key_source, ctx) or "default"
end

-- 解析限流键模板
function _M.build_limit_key(template, ctx)
    return (template:gsub("${([^}]+)}", function(var)
        return _M.extract_var("${"..var.."}", ctx) or ""
    end))
end

return _M
