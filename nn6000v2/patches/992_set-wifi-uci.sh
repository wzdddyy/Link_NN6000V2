#!/bin/sh
board_name=$(cat /tmp/sysinfo/board_name)

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
	# WiFi 6配置
	configure_wifi 0 '5g' 36 'HE80' 24 '500/5' '147258369'
	configure_wifi 1 '2g' 1 'HT20' 22 '500/5' '147258369'
}

case "${board_name}" in
link,nn6000-v2)
	link_nn6000v2_wifi_cfg
	;;
*)
	exit 0
	;;
esac

uci commit wireless
/etc/init.d/network restart
