admin_key=a30ff9b92796beac5c9c831769fd7606
PUBLIC_TOKEN_1=42f787fcaa935867b877cf472bd3b3db
PUBLIC_TOKEN_2=4114957a54aac402d12bfba07d7f102d

# 注：api网关启动前设置环境变量 ADMIN_API_KEY 可改变默认 admin_key
HEADERS="-H 'Content-Type: application/json' -H 'X-Admin-Key: ${admin_key}'"

# 创建一个新的路由
curdir=`pwd`
cd /home/dpay/gw/t

eval curl -s $HEADERS http://127.0.0.1:9000/admin/routes/1 -X PUT -d @routes/1.json 
eval curl -s $HEADERS http://127.0.0.1:9000/admin/routes/2 -X PUT -d @routes/2.json 

eval curl -s $HEADERS http://127.0.0.1:9000/admin/upstreams/vip_servers -X PUT -d @upstreams/vip_servers.json
eval curl -s $HEADERS http://127.0.0.1:9000/admin/upstreams/activity_servers -X PUT -d @upstreams/activity_servers.json

# 创建或更新route_key_maps: 自定义 merchant_upstreams 映射 map
eval curl -s $HEADERS http://127.0.0.1:9000/admin/route_key_maps/merchant_upstreams -X PUT -d @route_key_maps/merchant_upstreams.json

cd $curdir
