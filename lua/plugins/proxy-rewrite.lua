local _M = {}

function _M.execute(conf)
    -- URI 重写
    if conf.uri then
        -- 使用 ngx.req.set_uri 修改 URI
        ngx.req.set_uri(conf.uri, false)  -- false 表示不跳转

        -- 如果需要完全替换（包括参数），使用：
        -- ngx.req.set_uri(conf.uri, true)
    end

    -- Host 重写
    if conf.host then
        ngx.var.upstream_host = conf.host  -- 这是可修改的特殊变量
    end

    -- 头部处理
    if conf.headers then
        local headers = ngx.req.get_headers()

        -- 设置头部
        if conf.headers.set then
            for k, v in pairs(conf.headers.set) do
                if v ~= "" then
                    ngx.req.set_header(k, v)
                else
                    ngx.req.clear_header(k)
                end
            end
        end

        -- 添加头部（不会覆盖已有头部）
        if conf.headers.add then
            for k, v in pairs(conf.headers.add) do
                ngx.req.set_header(k, v)
            end
        end

        -- 删除头部
        if conf.headers.remove then
            for _, k in ipairs(conf.headers.remove) do
                ngx.req.clear_header(k)
            end
        end
    end
end

return _M
