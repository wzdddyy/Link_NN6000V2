#!/bin/sh
# ============================================================
# 网络初始化配置脚本
# 首次启动时自动配置 WiFi 和 PPPoE 宽带
# ============================================================

# ==================== WiFi 配置 ====================
# 5G WiFi 设置
WIFI_5G_SSID="ImmortalWRT-5G"
WIFI_5G_KEY="12345678"
WIFI_5G_CHANNEL=36
WIFI_5G_TXPOWER=24

# 2.4G WiFi 设置
WIFI_2G_SSID="ImmortalWRT"
WIFI_2G_KEY="12345678"
WIFI_2G_CHANNEL=1
WIFI_2G_TXPOWER=22

# ==================== PPPoE 宽带配置 ====================
# 填写你的宽带账号密码，使用 "-" 表示跳过配置
PPPOE_USERNAME="-"
PPPOE_PASSWORD="-"

# ============================================================

board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null)

configure_wifi() {
	local radio=$1
	local band=$2
	local channel=$3
	local htmode=$4
	local txpower=$5
	local ssid=$6
	local key=$7
	local encryption=${8:-"psk2+ccmp"}
	local now_encryption=$(uci get wireless.default_radio${radio}.encryption 2>/dev/null)
	if [ -n "$now_encryption" ] && [ "$now_encryption" != "none" ]; then
		return 0
	fi
	uci -q batch <<EOF
set wireless.radio${radio}.band="${band}"
set wireless.radio${radio}.channel="${channel}"
set wireless.radio${radio}.htmode="${htmode}"
set wireless.radio${radio}.mu_beamformer='1'
set wireless.radio${radio}.country='US'
set wireless.radio${radio}.txpower="${txpower}"
set wireless.radio${radio}.cell_density='0'
set wireless.radio${radio}.disabled='1'
set wireless.default_radio${radio}.ssid="${ssid}"
set wireless.default_radio${radio}.encryption="${encryption}"
set wireless.default_radio${radio}.key="${key}"
set wireless.default_radio${radio}.ieee80211k='1'
set wireless.default_radio${radio}.time_advertisement='2'
set wireless.default_radio${radio}.time_zone='CST-8'
set wireless.default_radio${radio}.bss_transition='1'
set wireless.default_radio${radio}.wnm_sleep_mode='1'
set wireless.default_radio${radio}.wnm_sleep_mode_no_keys='1'
EOF
}

link_nn6000v2_wifi_cfg() {
	configure_wifi 0 '5g' $WIFI_5G_CHANNEL 'HE80' $WIFI_5G_TXPOWER "$WIFI_5G_SSID" "$WIFI_5G_KEY"
	configure_wifi 1 '2g' $WIFI_2G_CHANNEL 'HT20' $WIFI_2G_TXPOWER "$WIFI_2G_SSID" "$WIFI_2G_KEY"
}

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
}

need_restart=0

case "${board_name}" in
link,nn6000-v2)
	link_nn6000v2_wifi_cfg
	uci commit wireless
	need_restart=1
	;;
esac

setup_pppoe

if [ "$need_restart" -eq 1 ]; then
	/etc/init.d/network restart
fi
