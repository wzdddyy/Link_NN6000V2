#!/usr/bin/env bash
set -e
set -o errexit
set -o errtrace

error_handler() {
    echo "Error occurred in script at line: ${BASH_LINENO[0]}, command: '${BASH_COMMAND}'"
}

trap 'error_handler' ERR

REPO_URL=$1
REPO_BRANCH=$2
BUILD_DIR=$3
COMMIT_HASH=$4

# Convert BUILD_DIR to absolute path
if [[ "$BUILD_DIR" != /* ]]; then
    BUILD_DIR="$(pwd)/$BUILD_DIR"
fi

FEEDS_CONF="feeds.conf.default"
GOLANG_REPO="https://github.com/sbwml/packages_lang_golang"
GOLANG_BRANCH="26.x"
THEME_SET="argon"
LAN_ADDR="192.168.2.1"

SCRIPT_DIR=$(cd $(dirname $0) && pwd)
BASE_PATH=${BASE_PATH:-$(dirname "$SCRIPT_DIR")}

source "$SCRIPT_DIR/general.sh"
source "$SCRIPT_DIR/feeds.sh"
source "$SCRIPT_DIR/packages.sh"
source "$SCRIPT_DIR/system.sh"
source "$SCRIPT_DIR/docker.sh"


main() {
    clone_repo
    clean_up
    reset_feeds_conf
    update_feeds
    update_golang
    clone_quickfile
    clone_lucky
    clone_diskman
    clone_dockerman
    clone_adguardhome
    clone_easytier
    clone_oaf
    clone_passwall
    install_feeds
    update_docker_stack
    remove_tweaked_packages
    change_dnsmasq2full
    fix_default_set
    fix_mk_def_depends
    update_default_lan_addr
    update_affinity_script
    update_dnsmasq_conf
    change_cpuusage
    set_custom_task
    apply_passwall_tweaks
    update_nss_pbuf_performance
    update_nss_diag
    fix_compile_coremark
    set_build_signature
    add_backup_info_to_sysupgrade
    remove_attendedsysupgrade
    fix_kconfig_recursive_dependency
    set_nginx_default_config
    update_nginx_ubus_module
    fix_nginx_configure
    update_uwsgi_limit_as
    update_script_priority
    fix_openssl_ktls
    fix_opkg_check
    fix_quectel_cm
    install_pbr_isp
    fix_pbr_ip_forward
    fix_quickstart
}

main "$@"
