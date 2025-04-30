local _M = {}
local ngx_re = ngx.re

-- 应用重写规则
function _M.apply(rule)
    if not rule then return end

    -- 分离正则匹配和替换
    local from, to = rule:match("^(%S+)%s+(%S+)")
    if from and to then
        -- 正则重写
        local new_uri, _, err = ngx_re.sub(ngx.var.uri, from, to, "jo")
        if new_uri then
            ngx.req.set_uri(new_uri, false)  -- 不跳转
            -- ngx.log(ngx.INFO, "URI rewritten: ", ngx.var.uri, " -> ", new_uri)
        end
    else
        -- 前缀替换
        ngx.req.set_uri(rule .. ngx.var.uri)
    end
end

return _M
