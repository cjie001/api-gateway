local _M = {}
local limit_count = require("resty.limit.count")

function _M.execute(conf)
    local lim, err = limit_count.new("limit_count_store", conf.count, conf.time_window)
    if not lim then
        ngx.log(ngx.ERR, "failed to instantiate a resty.limit.count object: ", err)
        return
    end
    
    local key = conf.key
    if conf.key_type == "var" then
        key = ngx.var[key]
    end
    
    local delay, remaining = lim:incoming(key, conf.count, conf.time_window)
    if not delay then
        ngx.exit(conf.rejected_code or 429)
    end
end

return _M
