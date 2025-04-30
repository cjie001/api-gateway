
LOCAL_ADMIN_KEY=a30ff9b92796beac5c9c831769fd7606
PUBLIC_TOKEN_1=42f787fcaa935867b877cf472bd3b3db
PUBLIC_TOKEN_2=4114957a54aac402d12bfba07d7f102d

# 一. 路由管理接口认证 token 设置方法
echo -e "\n设置所有 IP 共用认证 token"
curl -s -X POST -H "X-Auth-Token: $LOCAL_ADMIN_KEY" http://localhost:9100/admin/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "token": "$PUBLIC_TOKEN_1", 
    "ips": "*"
  }'

echo -e "\n设置指定地址段的认证 token"
curl -s -X POST -H "X-Auth-Token: $LOCAL_ADMIN_KEY" http://localhost:9100/admin/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "token": "$PUBLIC_TOKEN_2",
    "ips": ["172.16.1.0/24", "10.2.3.4"]
  }'

# 二. 接收 HTTP POST 请求更新路由规则
# 默认 token: $LOCAL_ADMIN_KEY 仅能够在本地使用, 其他 token 可通过第 1 步设置 
echo -e "\n接收 HTTP POST 请求更新路由规则"
curl -s -X POST http://localhost:9100/admin/update_rules \
  -H "X-Auth-Token: $LOCAL_ADMIN_KEY" \
  -d @rule.json

# 三. 主动从后台服务获取路由信息并加载, 后台服务地址在路由规则中设置
echo -e "\n主动从后台服务获取路由信息并加载"
curl -s http://localhost:9100/admin/update_rules \
  -H "X-Auth-Token: $LOCAL_ADMIN_KEY" 

# 四. 查询当前工作路由规则信息
echo -e "\n查询当前工作路由规则信息"
curl -s http://localhost:9100/admin/status \
  -H "X-Auth-Token: $LOCAL_ADMIN_KEY" | jq

# 六. 向网关发送交易请求示例
curl -i -X POST http://localhost:9000/api_prod -d @request-A.json
