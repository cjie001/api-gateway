local re = require "ngx.re"

local _M = {}


-- 封装split函数
function _M.split(str, pattern)
    local parts, err = re.split(str, pattern, "jo")  -- "jo"表示返回所有匹配项（包括空字符串）
    if not parts then
        ngx.log(ngx.ERR, "split error: ", err)
        return nil, err
    end
    return parts
end

return _M
