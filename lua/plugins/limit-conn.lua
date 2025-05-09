local _M = {}
local limit_conn = require("resty.limit.conn")

function _M.execute(conf)
    local lim, err = limit_conn.new("limit_conn_store", conf.conn, conf.burst, conf.default_conn_delay)
    if not lim then
        ngx.log(ngx.ERR, "failed to instantiate a resty.limit.conn object: ", err)
        return
    end
    
    local key = conf.key
    if conf.key_type == "var" then
        key = ngx.var[key]
    elseif conf.key_type == "var_combination" then
        -- 替换变量如 $remote_addr
        key = string.gsub(key, "%$(%w+)", function(var)
            return ngx.var[var] or ""
        end)
    end
    
    local ctx = lim:incoming(key, true)
    if not ctx then
        ngx.exit(conf.rejected_code or 503)
    end
    
    -- 在log阶段记录连接释放
    ngx.ctx.limit_conn = lim
    ngx.ctx.limit_conn_ctx = ctx
    ngx.ctx.limit_conn_key = key
end

-- 需要在log阶段调用的函数
function _M.after_execute()
    local lim = ngx.ctx.limit_conn
    local ctx = ngx.ctx.limit_conn_ctx
    local key = ngx.ctx.limit_conn_key
    
    if lim and ctx then
        local ok, err = lim:leave(ctx, key)
        if not ok then
            ngx.log(ngx.ERR, "failed to record the connection leaving: ", err)
        end
    end
end

return _M
