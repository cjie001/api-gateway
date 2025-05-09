local _M = {}

local shared = ngx.shared
local cjson = require("cjson.safe")
local const = require "const"
local response = require "response"

-- 从环境变量获取管理密钥（示例中简化处理）
local ADMIN_KEY = os.getenv("ADMIN_API_KEY") or const.ADMIN_LOCAL_KEY

-- 资源类型白名单
local RESOURCES = {
    routes = true,
    upstreams = true,
    settings = true,
    route_key_maps = true
}

function _M.init()
    -- 初始化共享字典默认值
    if not shared.settings:get("default") then
        shared.settings:set("default", cjson.encode({
            rules_api_url = const.RULES_API_URL,
            enable_admin_api = true
        }))
    end
end

-- 鉴权检查
local function check_auth()
    local admin_key = ngx.req.get_headers()["X-Admin-Key"] or
                     ngx.req.get_headers()["Authorization"] and
                     ngx.req.get_headers()["Authorization"]:match("^Bearer%s+(.+)")

    if admin_key ~= ADMIN_KEY then
        ngx.header["WWW-Authenticate"] = 'Bearer realm="Admin API"'
        response.exit(403, "Authentication failed.")
    end
end

-- 从URI解析资源和ID
local function get_resource_from_uri()
    local uri = ngx.var.uri
    local m = ngx.re.match(uri, [[^/admin/([^/]+)(?:/([^/]+))?$]])
    if m and RESOURCES[m[1]] then
        return m[1], m[2]
    end
    return nil, nil
end

-- 获取所有资源键（带分页支持）
local function get_all_keys(dict, page, page_size)
    page = tonumber(page) or 1
    page_size = tonumber(page_size) or 50

    local keys = dict:get_keys(0)  -- 0表示获取所有键
    table.sort(keys)

    -- 分页处理
    local total = #keys
    local start_idx = (page - 1) * page_size + 1
    local end_idx = math.min(page * page_size, total)

    local result = {
        data = {},
        meta = {
            total = total,
            page = page,
            page_size = page_size,
            has_next = end_idx < total
        }
    }

    for i = start_idx, end_idx do
        table.insert(result.data, keys[i])
    end

    return result
end

-- 处理GET请求（查询操作）
local function handle_get(resource, id)
    local dict = shared[resource]
    if not dict then
        response.exit(404, "resource: " .. resource .. " not found.")
    end

    -- 查询单个资源
    if id then
        local value = dict:get(id)
        if not value then
            response.exit(404, "id: " .. id .. " not found.")
        end

        local data, err = cjson.decode(value)
        if not data then
            ngx.log(ngx.ERR, "Failed to decode JSON: ", err)
            response.exit(500, "Failed to decode JSON: " .. err)
        end

        -- 添加资源ID（便于客户端使用）
        data.id = id
        return data
    end

    -- 查询资源列表（带分页参数）
    local page = tonumber(ngx.var.arg_page) or 1
    local page_size = tonumber(ngx.var.arg_page_size) or 50

    return get_all_keys(dict, page, page_size)
end

-- 处理PUT请求（创建/更新操作）
local function handle_put(resource, id, data)
    if not id then
        response.exit(400, "id not found.")
    end

    local dict = shared[resource]
    if not dict then
        response.exit(404, "resource not found: " .. resource)
    end

    -- 验证数据格式（示例：routes必须有uri字段）
    if resource == "routes" and (not data.uri or not data.methods) then
        response.exit(400, "Route must have uri and methods")
    end

    local ok, err = dict:set(id, cjson.encode(data))
    if not ok then
        ngx.log(ngx.ERR, "Failed to set data: ", err)
        response.exit(500, "Failed to set data.")
    end

    return { id = id, status = "success" }
end

-- 处理DELETE请求
local function handle_delete(resource, id)
    if not id then
        response.exit(400, "id not found.")
    end

    local dict = shared[resource]
    if not dict then
        response.exit(404, "resource not found: " .. resource)
    end

    if not dict:get(id) then
        response.exit(404, "id dict not found: " .. id)
    end

    dict:delete(id)
    return { id = id, status = "deleted" }
end

-- 主请求处理函数
function _M.handle_request()
    check_auth()

    local resource, id = get_resource_from_uri()
    if not resource then
        response.exit(404, "resource not found.")
    end

    local method = ngx.req.get_method()
    local content_type = ngx.req.get_headers()["Content-Type"]

    -- GET请求不需要body
    if method ~= "GET" then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()

        -- 验证Content-Type
        if not content_type or not content_type:match("application/json") then
            response.exit(415, "Unsupported media typ.") 
        end

        if not body or body == "" then
            response.exit(400, "body not found.")
        end
    end

    -- 根据请求方法路由处理逻辑
    local response
    if method == "GET" then
        response = handle_get(resource, id)
    elseif method == "PUT" then
        local data = cjson.decode(ngx.req.get_body_data())
        if not data then
            response.exit(400, "body invalid.")
        end
        response = handle_put(resource, id, data)
    elseif method == "DELETE" then
        response = handle_delete(resource, id)
    else
        ngx.header["Allow"] = "GET, PUT, DELETE"
        response.exit(405, "Method invalid.")
    end

    -- 返回JSON响应
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.say(cjson.encode(response))
end

return _M
