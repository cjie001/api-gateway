-- lua/chash.lua
local _M = {}

function _M.new(servers)
    return setmetatable({
        servers = servers,
        keys = {},
        sorted_keys = {}
    }, { __index = _M })
end

function _M.find(self, key)
    -- 简单哈希实现
    local hash = 0
    for i = 1, #key do
        hash = (hash * 31 + string.byte(key, i)) % 2147483647
    end
    
    if #self.servers == 0 then
        return nil
    end
    
    local idx = (hash % #self.servers) + 1
    return self.servers[idx].key
end

return _M
