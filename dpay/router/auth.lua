local _M = {}
local cjson = require "cjson.safe"
local iputils = require "resty.iputils"

-- 初始化IP匹配器（支持CIDR）
local ip_ranges = {
    ["internal"] = iputils.parse_cidrs({"127.0.0.1/32", "10.0.0.0/8", "192.168.0.0/16", "154.81.156.0/24"}),
    ["vip"] = iputils.parse_cidrs({"172.16.1.0/24"})
}

-- 检查IP是否在CIDR范围内
local function check_ip_whitelist(ip, range_group)
    return iputils.ip_in_cidrs(ip, ip_ranges[range_group])
end

-- 从共享内存获取Token绑定的IP列表
local function get_token_ips(token)
    local data = ngx.shared.token_ips:get(token)
    if not data then return nil end
    return cjson.decode(data)
end

-- IP匹配逻辑
local function is_ip_allowed(ip, allowed_ips)
    -- 允许配置为"*"时放行所有IP
    if allowed_ips == "*" then return true end

    -- 检查具体IP/CIDR
    if type(allowed_ips) == "table" then
        for _, pattern in ipairs(allowed_ips) do
            if pattern == ip or iputils.ip_in_cidr(ip, pattern) then
                return true
            end
        end
    end

    return false
end

-- 认证主逻辑
function _M.check()
    -- 1. 获取Token和客户端IP
    local token = ngx.req.get_headers()["X-Auth-Token"]
    if not token then
        ngx.log(ngx.WARN, "Missing X-Auth-Token header")
        return false
    end

    local client_ip = ngx.var.remote_addr

    -- 2. 本地固定Token验证
    if token == "SUNYARD_LOCAL_SECRET" then
        return check_ip_whitelist(client_ip, "internal")
    end

    -- 3. 动态Token-IP绑定验证
    local allowed_ips = get_token_ips(token)
    if not allowed_ips then
        ngx.log(ngx.WARN, "Invalid token: ", token)
        return false
    end

    return is_ip_allowed(client_ip, allowed_ips)
end

return _M
