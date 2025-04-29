
# 一. 路由管理接口认证 token 设置方法
echo -e "\n设置所有 IP 共用认证 token"
curl -s -X POST -H "X-Auth-Token: SUNYARD_LOCAL_SECRET" http://localhost:9100/admin/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "token": "PUBLIC_TOKEN", 
    "ips": "*"
  }'

echo -e "\n设置指定地址段的认证 token"
curl -s -X POST -H "X-Auth-Token: SUNYARD_LOCAL_SECRET" http://localhost:9100/admin/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "token": "API_TOKEN_123",
    "ips": ["172.16.1.0/24", "10.2.3.4"]
  }'

# 二. 接收 HTTP POST 请求更新路由规则
# 默认 token: SUNYARD_LOCAL_SECRET 仅能够在本地使用, 其他 token 可通过第 1 步设置 
# curl -s -X POST -H "X-Auth-Token: PUBLIC_TOKEN" http://localhost:9100/admin/update_rules -d @test/rule_1.json
echo -e "\n接收 HTTP POST 请求更新路由规则"
curl -s -X POST http://localhost:9100/admin/update_rules \
  -H "X-Auth-Token: SUNYARD_LOCAL_SECRET" \
  -d @test/rule_gateway.json

# 三. 主动从后台服务获取路由信息并加载, 后台服务地址在 dpay/router/update.lua
echo -e "\n主动从后台服务获取路由信息并加载"
curl -s http://localhost:9100/admin/update_rules \
  -H "X-Auth-Token: SUNYARD_LOCAL_SECRET" 

# 四. 查询当前工作路由规则信息
echo -e "\n查询当前工作路由规则信息"
curl -s http://localhost:9100/status \
  -H "X-Auth-Token: SUNYARD_LOCAL_SECRET" | jq

# 五. 路由规则说明
echo -e "\n路由规则配置说明"
cat <<EOF
{
  # 商户号与路由ID映射关系
  "merchant_map": {     
    "123": "route_trade_activity",
    "1234567890": "route_trade_activity",
    "9876543210": "route_trade_activity",
    "*": "route_default"
  },

  # 部署于后台的路由查询服务
  "rules_api_url": "http://127.0.0.1:9001/mock/latest_rules",

  # 路由规则，支持uri重写、动态upstream负载均衡、限流、熔断等配置
  "routes": { 
    "route_trade_activity": {
      "rewrite": "^/api/trade(.*)$ /mock/trade-activity$1"
    },
    "route_default": {
      "rewrite": "^/api/trade(.*)$ /mock/trade$1"
    }
  }
}
EOF

# 六. 向网关发送交易请求示例
curl -i -X POST http://localhost:9000/api/trade -d @test/request-A.json
#curl -i -X POST http://localhost:9000/api/trade -d @test/request-B.json
#curl -i -X POST http://localhost:9000/api/trade -d @test/request-Gray.json
