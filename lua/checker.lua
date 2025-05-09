-- lua/checker.lua
local _M = {}

function _M.new(opts)
    return setmetatable({
        dict_name = opts.dict_name,
        interval = opts.interval,
        http_path = opts.http_path,
        healthy_threshold = opts.healthy_threshold,
        unhealthy_threshold = opts.unhealthy_threshold,
        http_timeout = opts.http_timeout,
        nodes = {}
    }, { __index = _M })
end

function _M:add_node(host, port, weight)
    table.insert(self.nodes, {
        host = host,
        port = port,
        weight = weight
    })
end

function _M:report_success(host, port)
    local key = host .. ":" .. port
    ngx.shared[self.dict_name]:set(key, "UP")
end

function _M:report_failure(host, port)
    local key = host .. ":" .. port
    ngx.shared[self.dict_name]:set(key, "DOWN")
end

function _M:get_nodes()
    return self.nodes
end

return _M
