local _M = {}
local circuit_breaker = require("circuit_breaker")

function _M.execute(conf)
    local breaker = circuit_breaker:new(
        conf.unhealthy.http_statuses,
        conf.unhealthy.failures,
        conf.healthy.http_statuses,
        conf.healthy.successes
    )
    
    if breaker:is_open() then
        ngx.exit(conf.break_response_code or 502)
    end
    
    -- 在log阶段检查响应状态
    ngx.ctx.api_breaker = breaker
end

-- 需要在log阶段调用的函数
function _M.after_execute()
    local breaker = ngx.ctx.api_breaker
    if breaker then
        breaker:record_status(ngx.status)
    end
end

return _M
