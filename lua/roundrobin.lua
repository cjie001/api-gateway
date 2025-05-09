-- lua/roundrobin.lua
local _M = {}
local math = math

local function gcd_of(a, b)
    while b ~= 0 do
        a, b = b, a % b
    end
    return a
end

function _M.new(nodes)
    -- 首先确保nodes是table且包含有效的权重值
    if type(nodes) ~= "table" then
        return nil, "nodes must be a table"
    end

    -- 转换节点格式并验证权重
    local node_list = {}
    local total_weight = 0
    local max_weight = 0
    local gcd = 0

    for addr, weight in pairs(nodes) do
        -- 确保weight是数字
        local w = tonumber(weight) or 1
        node_list[addr] = w
        total_weight = total_weight + w
        if w > max_weight then
            max_weight = w
        end
        gcd = gcd_of(gcd, w)
    end

    -- 构建标准化节点列表
    local normalized_nodes = {}
    local idx = 1

    for addr, weight in pairs(node_list) do
        local norm_weight = weight / gcd
        for i = 1, norm_weight do
            normalized_nodes[idx] = addr
            idx = idx + 1
        end
    end

    -- 随机打乱节点顺序
    math.randomseed(os.time())
    for i = #normalized_nodes, 2, -1 do
        local j = math.random(i)
        normalized_nodes[i], normalized_nodes[j] = normalized_nodes[j], normalized_nodes[i]
    end

    return setmetatable({
        nodes = normalized_nodes,
        index = 0,
        count = #normalized_nodes
    }, { __index = _M })
end

function _M.get(self)
    self.index = self.index + 1
    if self.index > self.count then
        self.index = 1
    end
    return self.nodes[self.index]
end

return _M
