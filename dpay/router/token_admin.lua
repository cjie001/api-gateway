local _M = {}
local cjson = require "cjson.safe"

-- 添加/更新Token
function _M.add_token()
    ngx.req.read_body()
    local args = ngx.req.get_uri_args()
    local data = cjson.decode(ngx.req.get_body_data())

    -- 参数校验
    if not data.token or not data.ips then
        ngx.exit(400)
    end

    -- 支持两种IP格式：
    -- 1. 字符串 "*" 表示允许所有IP
    -- 2. 数组 {"1.1.1.1", "192.168.0.0/24"}
    ngx.shared.token_ips:set(data.token, cjson.encode(data.ips))
    ngx.say('{ "code": 200, "message": "OK"}')
end

-- 删除Token
function _M.revoke_token()
    local token = ngx.req.get_uri_args().token
    if not token then ngx.exit(400) end

    ngx.shared.token_ips:delete(token)
    ngx.say('{ "code": 200, "message": "OK"}')
end

-- 根据请求方法路由
if ngx.req.get_method() == "POST" then
    _M.add_token()
elseif ngx.req.get_method() == "DELETE" then
    _M.revoke_token()
else
    ngx.exit(405) -- Method Not Allowed
end
