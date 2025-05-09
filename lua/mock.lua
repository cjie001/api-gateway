local cjson = require "cjson"
local _M = {}

function _M.mock_response()
    -- 获取共享字典中的延时参数
    local delay_dict = ngx.shared.delay_dict
    local delay = delay_dict:get("delay") or 0 -- 默认无延时

    -- 模拟延时
    if delay > 0 then
        ngx.sleep(delay)
    end

    -- 获取请求URI
    local uri = ngx.var.uri

    -- 获取请求头并转换为JSON字段
    local headers = ngx.req.get_headers()
    local request_headers = {}
    for k, v in pairs(headers) do
        -- 如果头部有多个值（如Set-Cookie），则合并为一个字符串
        if type(v) == "table" then
            request_headers[k] = table.concat(v, ", ")
        else
            request_headers[k] = v
        end
    end

    -- 读取请求体
    ngx.req.read_body() -- 强制读取请求体
    local body_data = ngx.req.get_body_data()

    -- 如果请求体是大文件，则可能存储在临时文件中
    if not body_data then
        local file_name = ngx.req.get_body_file()
        if file_name then
            local f = io.open(file_name, "rb")
            if f then
                body_data = f:read("*a")
                f:close()
            end
        end
    end

    -- 将请求体解析为JSON格式，如果它已经是JSON则直接使用
    local request_body_json
    if body_data then
        local ok, result = pcall(cjson.decode, body_data)
        if ok then
            -- 请求体已经是有效的JSON，直接使用
            request_body_json = result
        else
            -- 请求体不是有效的JSON，将其作为字符串处理
            request_body_json = {raw_body = body_data}
        end
    else
        request_body_json = {}
    end

    -- 自定义响应报文内容
    local response_body = {
        message = "Hello, " .. uri .. " this is a mock response",
        code = 200,
        request_headers = request_headers, -- 原始请求头
        request_body = request_body_json   -- 请求体作为子节点
    }

    -- 输出响应
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(response_body))
end

function _M.mock_last_rules()
    local DEFAULT_RULES = {
        rules = {
            {
                uris = {"/api"},
                route_key_map = {
                    ["*"] = "route_default"
                },
                routes = {
                    route_default = {
                        rewrite = "^/(.*)$ /$1",
                        upstream_id = "default_servers"
                    }
                }
            }
        },
        upstreams = {
            default_servers = {
                {
                    host = "127.0.0.1", 
                    port = 9001, 
                    weight = 1
                }
            }
        },
        settings = {
            rules_api_url = const.RULES_API_URL
        }
    }

    local current_rules = DEFAULT_RULES
    -- 从文件读取响应报文内容
    local filename = ngx.config.prefix() .. "/test/rule.json"
    local file, err = io.open(filename, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local json_dict = cjson.decode(content)
        if json_dict then
            current_rules = json_dict
        end
    else
        ngx.log(ngx.ERR, filename .. "not found, use DEFAULT_RULES.")
    end

    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(current_rules))
end

return _M
