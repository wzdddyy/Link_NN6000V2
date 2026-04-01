#!/bin/sh
# shellcheck disable=3037,3060,2034,1091,2166
# Color codes setup
setup_colors() {
    if [ -t 1 ]; then
        red="\033[31m"
        green="\033[32m"
        yellow="\033[33m"
        blue="\033[34m"
        magenta="\033[35m"
        cyan="\033[36m"
        white="\033[37m"
        reset="\033[m"
        bold="\033[1m"
    else
        red="" green="" yellow="" blue="" magenta="" cyan="" white="" reset="" bold=""
    fi
}
setup_colors

# Helper function to print labeled values
print_info() {
    local label="$1"
    local value="$2"
    local color="$3"
    printf "${bold}${red}%10s${reset}: ${color}${bold}%s${reset}\n" "$label" "$value"
}

# Retrieve system information with defaults
get_value() {
    local default="${2:-N/A}"
    [ -n "$1" ] && [ -r "$1" ] && cat "$1" || echo "$default"
}

# OpenWRT version
openwrt_rev=$(get_value /etc/openwrt_version)

# Linux kernel
kernel=$(uname -r 2>/dev/null || echo "N/A")

# Device model
model=$(jsonfilter -e '@.model.name' </etc/board.json 2>/dev/null | sed -e 's/,/_/g' || echo "N/A")

# NSS firmware version
nss_fw="/lib/firmware/qca*.bin"
nss_version=$(grep -h -m 1 -a -o 'Version:.[^[:cntrl:]]*' $nss_fw 2>/dev/null | head -1 | cut -d ' ' -f 2)
nss_version=${nss_version:-"N/A"}

# CPU governor
cpu=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")

# ATH11K firmware version
ath11k_fw=$(grep -hm1 -a -o 'WLAN.[^[:cntrl:]]*SILICONZ-1' /lib/firmware/*/q6* 2>/dev/null | head -1)
ath11k_fw=${ath11k_fw:-"N/A"}

# MAC80211 version
mac80211_version=$(awk '/version/{print $NF;exit}' /lib/modules/*/compat.ko 2>/dev/null || echo "N/A")

# IPQ release details
[ -r /etc/ipq_release ] && . /etc/ipq_release
ipq_branch=${IPQ_BRANCH:-"N/A"}
ipq_commit=${IPQ_COMMIT:-"N/A"}
ipq_date=${IPQ_DATE:-"N/A"}

# Display system information
echo -e "${bold}${red}========================================${reset}"
echo -e "${bold}${red}        NSS System Diagnostic         ${reset}"
echo -e "${bold}${red}========================================${reset}"

print_info "MODEL" "$model" "$blue"
print_info "OPENWRT" "$openwrt_rev" "$white"
print_info "KERNEL" "$kernel" "$yellow"
print_info "IPQ BR" "$ipq_branch" "$cyan"
print_info "IPQ CM" "$ipq_commit" "$cyan"
print_info "IPQ DT" "$ipq_date" "$cyan"
print_info "NSS FW" "$nss_version" "$magenta"
print_info "CPU GOV" "$cpu" "$magenta"
print_info "MAC80211" "$mac80211_version" "$yellow"
print_info "ATH11K" "$ath11k_fw" "$green"

# Display GRO Fragmentation status
echo -e "${bold}${red}========================================${reset}"
echo -ne "${bold}${red} INTERFACE${reset}: ${white}"

for iface in /sys/class/net/*/device; do
    iface=${iface%/*}
    iface=${iface##*/}
    [ -d "/sys/class/net/$iface" ] || continue
    
    ethtool -k "$iface" 2>/dev/null | awk -v i="$iface" -v rst="${reset}" -v red="${red}" -v green="${green}" '
    BEGIN { settings="" }
    /tx-checksumming|rx-gro-list/ {
      color=green
      if($2=="off") color=red
      settings = settings $1 " " sprintf("%s%-3s%s", color,$2,rst) " "
    }
    END { if(settings != "") printf "            %-11s %s\n", i, settings }'
done

# Display NSS packages
echo -e "${reset}${bold}${red}========================================${reset}"
echo -ne "${bold}${red}  NSS PKGS${reset}: ${white}"

# Find package manager
if command -v apk >/dev/null 2>&1; then
    pkg_mgr="apk"
    pkg_flags="list -I"
elif command -v opkg >/dev/null 2>&1; then
    pkg_mgr="opkg"
    pkg_flags="list-installed"
else
    echo -e "${red}No package manager found${reset}"
    exit 1
fi

# List NSS-related packages
$pkg_mgr $pkg_flags 2>/dev/null | awk -v count=0 '
  /kmod-qca|^nss/ {
    if(count>0) tab="            "
    print tab $0
    count++
  }
  END {
    if (count == 0) print "            N/a"
  }'

echo -e "${reset}"
