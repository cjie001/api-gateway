local _M = {}
local limit_req = require("resty.limit.req")

function _M.execute(conf)
    local lim, err = limit_req.new("limit_req_store", conf.rate, conf.burst)
    if not lim then
        ngx.log(ngx.ERR, "failed to instantiate a resty.limit.req object: ", err)
        return
    end
    
    local key = conf.key
    if conf.key_type == "var" then
        key = ngx.var[key]
    end
    
    local delay, err = lim:incoming(key, true)
    if not delay then
        if err == "rejected" then
            ngx.exit(conf.rejected_code or 503)
        end
        ngx.log(ngx.ERR, "failed to limit req: ", err)
        return
    end
    
    if delay > 0 then
        ngx.sleep(delay)
    end
end

return _M
