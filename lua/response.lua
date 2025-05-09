local _M = {}

local cjson = require("cjson.safe")

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
        code = status,
        message = message,
        request_id = ngx.var.request_id or ""
    }))
    ngx.exit(status)
end

function _M.exit(status, message, headers)
    error_response(status, message, headers)
end

return _M
