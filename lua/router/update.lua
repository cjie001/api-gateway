local _M = {}
local cjson = require "cjson.safe"
local http = require "resty.http"

local HTTP_TIMEOUT = 30000 -- 30秒超时

-- 保存规则到本地文件
local function save_rules(json_str)
    local file, err = io.open(ngx.config.prefix() .. "rule.json", "w+")
    if not file then
        ngx.log(ngx.ERR, "Cannot open file: ", err)
        return
    end
    file:write(json_str)
    file:close()
end

-- 从外部API获取规则
local function fetch_rules_from_api()
    local httpc = http.new()
    httpc:set_timeouts(3, 10, HTTP_TIMEOUT)

    local rules_api_url = ngx.shared.settings:get("rules_api_url")
    if not rules_api_url then
        return nil, "The rule service URL is not set."
    end

    local res, err = httpc:request_uri(rules_api_url, {
        method = "GET",
        headers = {
            ["X-Node-ID"] = ngx.var.hostname,
            ["Authorization"] = ngx.var.http_authorization
        },
        ssl_verify = false
    })

    if not res then
        return nil, "API request failed: " .. (err or "unknown")
    end

    if res.status ~= 200 then
        return nil, "API returned " .. res.status
    end

    save_rules(res.body)
    return cjson.decode(res.body)
end

-- 更新共享内存
function _M.update_shared_dict(rules)
    -- 清除旧数据
    --ngx.shared.uri_rules:flush_all()
    --ngx.shared.route_key_maps:flush_all()
    --ngx.shared.route_configs:flush_all()
    --ngx.shared.upstreams:flush_all()

    -- 首先存储所有路由键映射
    if rules.route_key_maps then
        for map_name, key_map in pairs(rules.route_key_maps) do
            ngx.shared.route_key_maps:set("map:"..map_name, cjson.encode(key_map))
        end
    end

    -- 存储规则
    local rule_groups = rules.rules or {}
    for _, rule in ipairs(rule_groups) do
        -- 存储URI映射
        for _, uri in ipairs(rule.uris) do
            ngx.shared.uri_rules:set(uri, true)

            -- 存储路由键映射引用和提取规则
            local route_group = {
                key_map_ref = rule.route_key_map,  -- 引用route_key_maps中的映射名称
                key_source = rule.route_key_source  -- 键提取规则
            }
            ngx.shared.route_key_maps:set("uri:"..uri, cjson.encode(route_group))
        end

        -- 存储路由配置（排除nodes）
        for route_id, config in pairs(rule.routes) do
            -- 确保不存储上游节点信息
            local route_config = {
                rewrite = config.rewrite,
                upstream_id = config.upstream_id,
                rate_limit = config.rate_limit,
                circuit_break = config.circuit_break
                -- 不包含nodes信息
            }
            ngx.shared.route_configs:set(route_id, cjson.encode(route_config))
        end
    end

    -- 存储upstreams
    if rules.upstreams then
        for upstream_id, nodes in pairs(rules.upstreams) do
            ngx.shared.upstreams:set(upstream_id, cjson.encode(nodes))
        end
    end

    -- 设置settings参数
    if rules.settings then
        for key, value in pairs(rules.settings) do
            ngx.shared.settings:set(key, value)
        end
    end
end

-- POST 更新接口
function _M.handle_post()
    ngx.req.read_body()
    local json_str = ngx.req.get_body_data()
    local rules = cjson.decode(json_str)

    if rules then
        save_rules(cjson.encode(rules, {indent = true}))
        _M.update_shared_dict(rules)
        ngx.say('{ "code": 200, "message": "OK"}')
    else
        ngx.say('{ "code": 400, "message": "Invalid rules format"}')
    end
end

-- 主动拉取
function _M.sync_rules()
    local rules, err = fetch_rules_from_api()
    if rules then
        _M.update_shared_dict(rules)
        ngx.log(ngx.INFO, "Rules updated from API")
    else
        ngx.log(ngx.ERR, "Failed to fetch rules: ", err)
    end
end

return _M
