local cjson = require "cjson.safe"
local update = require "router.update"
local const = require "const"

-- 初始示例规则
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

-- 加载规则
local current_rules = DEFAULT_RULES
local filename = ngx.config.prefix() .. "rule.json"
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

update.update_shared_dict(current_rules)
