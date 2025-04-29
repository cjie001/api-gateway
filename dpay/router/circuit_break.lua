local ngx = ngx
local cjson = require "cjson.safe"
local math = math

local _M = {}
local shared_dict = ngx.shared.circuit_breaker

-- 熔断状态常量
local STATE_CLOSED = "closed"
local STATE_OPEN = "open"
local STATE_HALF_OPEN = "half_open"

-- 默认配置
local DEFAULT_CONFIG = {
    failure_threshold = 5,     -- 失败次数阈值
    success_threshold = 3,     -- 半开状态下成功次数阈值
    timeout = 30,              -- 熔断持续时间(秒)
    window_size = 60           -- 统计窗口(秒)
}

-- 检查熔断状态
function _M.is_open(route_id, config)
    config = config or {}
    for k, v in pairs(DEFAULT_CONFIG) do
        if config[k] == nil then
            config[k] = v
        end
    end

    local now = ngx.now()
    local state_key = "cb:" .. route_id .. ":state"
    local stats_key = "cb:" .. route_id .. ":stats"

    -- 获取当前状态
    local state = shared_dict:get(state_key) or STATE_CLOSED
    local stats_str = shared_dict:get(stats_key) or "{}"
    local stats = cjson.decode(stats_str) or {}

    -- 状态转换逻辑
    if state == STATE_OPEN then
        if now > (stats.last_updated + config.timeout) then
            state = STATE_HALF_OPEN
            stats = {
                successes = 0,
                failures = 0,
                last_updated = now
            }
        else
            return true, {
                state = STATE_OPEN,
                retry_after = math.ceil(stats.last_updated + config.timeout - now)
            }
        end
    end

    -- 更新共享字典
    shared_dict:set(state_key, state)
    shared_dict:set(stats_key, cjson.encode(stats))

    return false, {
        state = state,
        stats = stats
    }
end

-- 上报请求结果
function _M.report(route_id, success)
    local state_key = "cb:" .. route_id .. ":state"
    local stats_key = "cb:" .. route_id .. ":stats"
    local config_key = "cb:" .. route_id .. ":config"

    local state = shared_dict:get(state_key) or STATE_CLOSED
    local stats_str = shared_dict:get(stats_key) or "{}"
    local stats = cjson.decode(stats_str) or {}
    local config_str = shared_dict:get(config_key) or "{}"
    local config = cjson.decode(config_str) or DEFAULT_CONFIG

    -- 初始化统计
    stats.successes = stats.successes or 0
    stats.failures = stats.failures or 0
    stats.last_updated = stats.last_updated or ngx.now()

    -- 更新统计
    if success then
        stats.successes = stats.successes + 1
    else
        stats.failures = stats.failures + 1
    end

    -- 状态转换
    if state == STATE_CLOSED then
        if stats.failures >= config.failure_threshold then
            state = STATE_OPEN
            stats.last_updated = ngx.now()
        end
    elseif state == STATE_HALF_OPEN then
        if success then
            if stats.successes >= config.success_threshold then
                state = STATE_CLOSED
                stats = { failures = 0, successes = 0 }
            end
        else
            state = STATE_OPEN
            stats.last_updated = ngx.now()
        end
    end

    -- 保存状态
    shared_dict:set(state_key, state)
    shared_dict:set(stats_key, cjson.encode(stats))

    return true
end

return _M
