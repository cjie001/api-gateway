-- rate_limit.lua
local _M = { _VERSION = '1.0' }

local resty_lock = require "resty.lock"
local shared_dict = ngx.shared.rate_limit_cache
local math = math
local string = string
local tonumber = tonumber
local ngx_now = ngx.now
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR

-- 替换模板变量
local function render_key_template(template, route_id, limit_key)
    return string.gsub(template, "%${(%w+)}", {
        route_id = route_id,
        limit_key = limit_key
    })
end

-- Token Bucket 算法实现
local function token_bucket_check(route_id, limit_key, conf)
    local now = ngx_now()
    local rate = tonumber(conf.rate)           -- 每秒生成令牌数
    local burst = tonumber(conf.burst)         -- 桶容量
    local interval = 1 / rate                  -- 令牌生成间隔

    local cache_key = "tb:" .. route_id .. ":" .. limit_key
    local lock_key = "lock:" .. cache_key

    -- 获取分布式锁
    local lock = resty_lock:new("rate_limit_locks", {
        exptime = 0.1,
        timeout = 0.01
    })
    local elapsed, err = lock:lock(lock_key)
    if not elapsed then
        ngx_log(ngx_ERR, "failed to acquire lock: ", err)
        return true -- 获取锁失败时放行
    end

    -- 从共享内存获取当前桶状态
    local bucket = shared_dict:get(cache_key)
    local last_fill, tokens

    if bucket then
        last_fill, tokens = string.match(bucket, "([^|]+)|([^|]+)")
        last_fill = tonumber(last_fill)
        tokens = tonumber(tokens)
    else
        last_fill = now
        tokens = burst
    end

    -- 计算新增令牌
    local delta = math.floor((now - last_fill) / interval)
    tokens = math.min(tokens + delta, burst)
    last_fill = last_fill + delta * interval

    -- 检查令牌是否足够
    local allowed = tokens >= 1
    if allowed then
        tokens = tokens - 1
    end

    -- 更新桶状态
    shared_dict:set(cache_key, last_fill .. "|" .. tokens)
    lock:unlock()

    return allowed, {
        max_requests = burst,
        remaining = math.floor(tokens),
        reset = math.ceil(last_fill + interval)
    }
end

-- Fixed Window 算法实现
local function fixed_window_check(route_id, limit_key, conf)
    local interval = tonumber(conf.interval) or 1   -- 窗口大小（秒）
    local max_requests = tonumber(conf.max_requests) -- 窗口内最大请求数

    local now = ngx_now()
    local window_start = math.floor(now / interval) * interval
    local cache_key = "fw:" .. route_id .. ":" .. limit_key .. ":" .. window_start

    -- 原子递增计数器
    local current, err = shared_dict:incr(cache_key, 1, 0, interval * 2)
    if not current then
        ngx_log(ngx_ERR, "failed to incr counter: ", err)
        return true -- 出错时放行
    end

    return current <= max_requests, {
        max_requests = max_requests,
        remaining = math.max(0, max_requests - current),
        reset = window_start + interval
    }
end

-- 主检查函数
function _M.check(route_id, limit_key, rate_limit)
    if not rate_limit or not rate_limit.strategy then
        return true -- 未配置限流策略时放行
    end

    -- 渲染限流key
    local rendered_key = render_key_template(
        rate_limit.key_template or "${route_id}|${limit_key}",
        route_id,
        limit_key
    )

    local allowed, info
    local strategy = rate_limit.strategy:lower()

    if strategy == "token_bucket" then
        allowed, info = token_bucket_check(route_id, rendered_key, {
            rate = rate_limit.rate,
            burst = rate_limit.burst
        })
    elseif strategy == "fixed_window" then
        allowed, info = fixed_window_check(route_id, rendered_key, {
            max_requests = rate_limit.max_requests,
            interval = rate_limit.interval
        })
    else
        ngx_log(ngx_ERR, "unknown rate limit strategy: ", strategy)
        return true -- 未知策略时放行
    end

    -- 添加响应头
    if info then
        ngx.header["X-RateLimit-Limit"] = info.max_requests
        ngx.header["X-RateLimit-Remaining"] = info.remaining
        ngx.header["X-RateLimit-Reset"] = info.reset
    end

    return allowed
end

return _M
