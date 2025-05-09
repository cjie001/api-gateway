local _M = {}
local setmetatable = setmetatable
local cjson = require("cjson.safe")
local shared = ngx.shared
local breaker_dict = shared.circuit_breaker

local mt = { __index = _M }

function _M.new(unhealthy_statuses, unhealthy_threshold, healthy_statuses, healthy_threshold)
    return setmetatable({
        unhealthy_statuses = unhealthy_statuses,
        unhealthy_threshold = unhealthy_threshold,
        healthy_statuses = healthy_statuses,
        healthy_threshold = healthy_threshold,
        failures = 0,
        successes = 0,
        state = "closed" -- closed, open, half-open
    }, mt)
end

function _M:is_open()
    if self.state == "open" then
        return true
    end
    return false
end

function _M:record_status(status)
    if self.state == "open" then
        -- 在半开状态下测试请求
        if self:is_healthy_status(status) then
            self.successes = self.successes + 1
            if self.successes >= self.healthy_threshold then
                self:reset()
            end
        else
            self.state = "open"
        end
        return
    end
    
    if self:is_unhealthy_status(status) then
        self.failures = self.failures + 1
        self.successes = 0
        
        if self.failures >= self.unhealthy_threshold then
            self.state = "open"
            ngx.timer.at(60, function() -- 60秒后进入半开状态
                self.state = "half-open"
            end)
        end
    elseif self:is_healthy_status(status) then
        self.successes = self.successes + 1
        self.failures = 0
    end
end

function _M:is_unhealthy_status(status)
    for _, s in ipairs(self.unhealthy_statuses) do
        if s == status then
            return true
        end
    end
    return false
end

function _M:is_healthy_status(status)
    for _, s in ipairs(self.healthy_statuses) do
        if s == status then
            return true
        end
    end
    return false
end

function _M:reset()
    self.state = "closed"
    self.failures = 0
    self.successes = 0
end

return _M
