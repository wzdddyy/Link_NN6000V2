#!/bin/sh
PPPOE_USERNAME="-"
PPPOE_PASSWORD="-"

setup_pppoe() {
	if [ "$PPPOE_USERNAME" = "-" ] || [ "$PPPOE_PASSWORD" = "-" ]; then
		echo "PPPoE: 使用占位符，跳过配置"
		return 0
	fi

	if [ ! -f /etc/config/network ]; then
		echo "PPPoE: network 配置文件不存在"
		return 1
	fi

	local wan_proto=$(uci -q get network.wan.proto)
	if [ "$wan_proto" = "pppoe" ]; then
		echo "PPPoE: 已配置，跳过"
		return 0
	fi

	uci -q batch <<EOF
set network.wan.proto='pppoe'
set network.wan.username='${PPPOE_USERNAME}'
set network.wan.password='${PPPOE_PASSWORD}'
set network.wan.keepalive='5 3'
set network.wan.demand='0'
EOF

	uci commit network
	echo "PPPoE: 配置完成 - 用户名: ${PPPOE_USERNAME}"
	/etc/init.d/network restart
}

setup_pppoe
