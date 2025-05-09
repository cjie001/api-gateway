
local _M = {}

_M.ADMIN_LOCAL_KEY         = "a30ff9b92796beac5c9c831769fd7606"

_M.IP_RANGES_INTERNAL      = { "127.0.0.1/32", "10.0.0.0/8" }

_M.IP_RANGES_VIP           = { "172.16.1.0/24" }

_M.RULES_API_URL           = "http://127.0.0.1:9001/mock/latest_rules"

return _M
