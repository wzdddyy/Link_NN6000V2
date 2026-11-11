#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2164,SC2069,SC2155
#===============================================================================
# Docker Stack Configuration Script for OpenWrt
# 
# 功能：应用 dockerd 的默认配置（组件版本跟随 feeds，不做版本升级）
# 特性：nftables 防火墙后端支持，dockerman 兼容性
#===============================================================================

#-------------------------------------------------------------------------------
# 全局配置
#-------------------------------------------------------------------------------
DOCKER_STACK_MODULE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOCKER_STACK_REPO_ROOT=$(cd "$DOCKER_STACK_MODULE_DIR/../.." && pwd)


# 文件路径配置
DOCKER_STACK_DOCKERD_MAKEFILE_REL="package/feeds/packages/dockerd/Makefile"
DOCKER_STACK_DOCKERD_CONFIG_REL="package/feeds/packages/dockerd/files/etc/config/dockerd"
DOCKER_STACK_DOCKERD_INIT_REL="package/feeds/packages/dockerd/files/dockerd.init"
DOCKER_STACK_DOCKERD_SYSCTL_REL="package/feeds/packages/dockerd/files/etc/sysctl.d/sysctl-br-netfilter-ip.conf"

# 日志配置
DOCKER_STACK_LOG_LEVEL="${DOCKER_STACK_LOG_LEVEL:-info}"
DOCKER_STACK_QUIET="${DOCKER_STACK_QUIET:-0}"


# 临时文件管理
_docker_stack_temp_files=()

#-------------------------------------------------------------------------------
# 清理函数（退出时自动清理临时文件）
#-------------------------------------------------------------------------------
_docker_stack_cleanup() {
    local tmp_file
    for tmp_file in "${_docker_stack_temp_files[@]}"; do
        [ -f "$tmp_file" ] && rm -f "$tmp_file"
    done
}

trap _docker_stack_cleanup EXIT INT TERM

#-------------------------------------------------------------------------------
# 日志系统
#-------------------------------------------------------------------------------
_docker_stack_log() {
    local level="$1"
    shift
    local message="$*"
    local prefix=""
    local color=""
    local reset="\033[0m"
    
    # 颜色配置（仅终端输出）
    if [ -t 1 ]; then
        case "$level" in
            debug) color="\033[36m" ;;  # 青色
            info)  color="\033[32m" ;;  # 绿色
            warn)  color="\033[33m" ;;  # 黄色
            error) color="\033[31m" ;;  # 红色
        esac
    fi
    
    case "$level" in
        debug)
            [ "$DOCKER_STACK_LOG_LEVEL" = "debug" ] || return 0
            prefix="[DEBUG]"
            ;;
        info)
            [ "$DOCKER_STACK_QUIET" = "1" ] && return 0
            prefix="[INFO]"
            ;;
        warn)  prefix="[WARN]" ;;
        error) prefix="[ERROR]" ;;
    esac
    
    if [ "$level" = "error" ]; then
        echo -e "${color}${prefix}${reset} ${message}" >&2
    else
        echo -e "${color}${prefix}${reset} ${message}"
    fi
}

_docker_stack_log_debug() { _docker_stack_log debug "$@"; }
_docker_stack_log_info() { _docker_stack_log info "$@"; }
_docker_stack_log_warn() { _docker_stack_log warn "$@"; }
_docker_stack_log_error() { _docker_stack_log error "$@"; }

#-------------------------------------------------------------------------------
# 临时文件管理
#-------------------------------------------------------------------------------
_docker_stack_mktemp() {
    local tmp_file
    tmp_file=$(mktemp) || {
        _docker_stack_log_error "创建临时文件失败"
        return 1
    }
    _docker_stack_temp_files+=("$tmp_file")
    echo "$tmp_file"
}

#-------------------------------------------------------------------------------
# 通用文件查找函数
#-------------------------------------------------------------------------------
_docker_stack_find_file() {
    local description="$1"
    shift
    local search_paths=("$@")
    local candidate
    
    for candidate in "${search_paths[@]}"; do
        [ -f "$candidate" ] && {
            _docker_stack_log_debug "找到文件：$candidate"
            echo "$candidate"
            return 0
        }
    done
    
    _docker_stack_log_error "未找到 $description"
    _docker_stack_log_error "已检查路径:"
    printf '  - %s\n' "${search_paths[@]}" >&2
    return 1
}

#-------------------------------------------------------------------------------
# 文件解析函数
#-------------------------------------------------------------------------------
_docker_stack_resolve_component_makefile() {
    local build_dir="$1"
    local component="$2"
    
    _docker_stack_find_file "$component Makefile" \
        "$build_dir/package/feeds/packages/$component/Makefile" \
        "$build_dir/feeds/packages/utils/$component/Makefile"
}

_docker_stack_resolve_dockerd_file() {
    local build_dir="$1"
    local rel="$2"
    
    _docker_stack_find_file "dockerd $rel" \
        "$build_dir/package/feeds/packages/dockerd/$rel" \
        "$build_dir/feeds/packages/utils/dockerd/$rel"
}

_docker_stack_resolve_dockerman_init() {
    local build_dir="$1"
    local candidate
    
    for candidate in \
        "$build_dir/feeds/openwrt_packages/luci-app-dockerman/root/etc/init.d/dockerman" \
        "$build_dir/feeds/luci/applications/luci-app-dockerman/root/etc/init.d/dockerman" \
        "$build_dir/package/feeds/luci/luci-app-dockerman/root/etc/init.d/dockerman" \
        "$build_dir/package/feeds/luci/applications/luci-app-dockerman/root/etc/init.d/dockerman"
    do
        [ -f "$candidate" ] && {
            echo "$candidate"
            return 0
        }
    done
    
    return 1
}

_docker_stack_normalize_build_dir() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        echo "$path"
    else
        echo "$(pwd)/$path"
    fi
}

#-------------------------------------------------------------------------------
# 修复 dockerd vendored 检查
#-------------------------------------------------------------------------------
_docker_stack_fix_dockerd_vendored_checks() {
    local mk_path="$1"
    local tmp_path
    
    tmp_path=$(_docker_stack_mktemp) || return 1
    
    # 检测是否有 EnsureVendoredVersion 调用
    if grep -q '\$(call EnsureVendoredVersion,' "$mk_path"; then
        _docker_stack_log_debug "检测到 vendored 版本检查，正在禁用严格验证..."
        

        awk '
            BEGIN { in_prepare = 0 }
            /^define Build\/Prepare[[:space:]]*$/ {
                in_prepare = 1
                print
                print "\t$(Build/Prepare/Default)"
                next
            }
            in_prepare && /^endef[[:space:]]*$/ { in_prepare = 0; print; next }
            in_prepare { next }
            { print }
        ' "$mk_path" > "$tmp_path" || {
            _docker_stack_log_error "未能禁用 vendored 严格验证"
            return 1
        }
        
        if ! grep -q '^define Build/Prepare' "$tmp_path" || \
           ! grep -q '\$(Build/Prepare/Default)' "$tmp_path" || \
           grep -q '\$(call EnsureVendoredVersion,' "$tmp_path"; then
            _docker_stack_log_error "重写后的 dockerd Makefile 缺少有效的 Build/Prepare"
            return 1
        fi
        
        mv "$tmp_path" "$mk_path"
        _docker_stack_log_debug "已禁用 vendored 版本检查"
        return 0
    fi
    
    _docker_stack_log_debug "Makefile 未使用 EnsureVendoredVersion 宏，无需处理"
    return 0
}

#-------------------------------------------------------------------------------
# 修复 dockerd nftables 注释
#-------------------------------------------------------------------------------
_docker_stack_fix_dockerd_nftables_comment() {
    local config_path="$1"
    
    if grep -Fq "Docker doesn't work well out of the box with fw4." "$config_path"; then
        sed -i \
            -e "/^# Docker doesn't work well out of the box with fw4\./c\# firewall_backend defaults to nftables and is expected to work with fw4." \
            -e "/^# naively translates iptables rules\. For the best compatibility replace the following dependencies:/c\# If you must use legacy behavior for compatibility, switch \`firewall_backend\` to \`iptables\`." \
            -e "/^# \`firewall4\` -> \`firewall\`/d" \
            -e "/^# \`iptables-nft\` -> \`iptables-legacy\`/d" \
            -e "/^# \`ip6tables-nft\` -> \`ip6tables-legacy\`/d" \
            -e "/^# \`iptables-nft\` -> \`iptables-zz-legacy\`/d" \
            -e "/^# \`ip6tables-nft\` -> \`ip6tables-zz-legacy\`/d" \
            "$config_path"
        _docker_stack_log_debug "已更新 nftables 注释"
    fi
}

#-------------------------------------------------------------------------------
# 设置/追加 dockerd uci 配置
#-------------------------------------------------------------------------------
_docker_stack_set_or_append_dockerd_uci_option() {
    local config_path="$1"
    local option_name="$2"
    local option_value="$3"
    
    if grep -Fq "option ${option_name} '${option_value}'" "$config_path"; then
        return 0
    fi
    
    if grep -q "^config globals 'globals'" "$config_path"; then
        sed -i "/^config globals 'globals'/a\\	option ${option_name} '${option_value}'" "$config_path"
    else
        echo "" >> "$config_path"
        echo "config globals 'globals'" >> "$config_path"
        echo "	option ${option_name} '${option_value}'" >> "$config_path"
    fi
}

#-------------------------------------------------------------------------------
# 设置/追加 sysctl 值
#-------------------------------------------------------------------------------
_docker_stack_set_or_append_sysctl_value() {
    local sysctl_path="$1"
    local key="$2"
    local value="$3"
    
    if grep -q "^${key}=" "$sysctl_path"; then
        sed -i "s/^${key}=.*/${key}=${value}/" "$sysctl_path"
    else
        echo "${key}=${value}" >> "$sysctl_path"
    fi
}

#-------------------------------------------------------------------------------
# 更新 dockerd 默认配置
#-------------------------------------------------------------------------------
_docker_stack_update_dockerd_defaults() {
    local build_dir="$1"
    local dry_run="$2"
    local storage_driver="$3"
    local dockerd_makefile=""
    local dockerd_config=""
    local dockerd_sysctl=""
    
    dockerd_makefile=$(_docker_stack_resolve_component_makefile "$build_dir" "dockerd") || return 1
    dockerd_config=$(_docker_stack_resolve_dockerd_file "$build_dir" "files/etc/config/dockerd") || return 1
    
    local sysctl_rel="files/etc/sysctl.d/sysctl-br-netfilter-ip.conf"
    local candidate
    dockerd_sysctl=""
    for candidate in \
        "$build_dir/package/feeds/packages/dockerd/$sysctl_rel" \
        "$build_dir/feeds/packages/utils/dockerd/$sysctl_rel"
    do
        [ -f "$candidate" ] && {
            dockerd_sysctl="$candidate"
            break
        }
    done
    
    [ -f "$dockerd_makefile" ] || {
        _docker_stack_log_error "未找到 dockerd Makefile: $dockerd_makefile"
        return 1
    }
    [ -f "$dockerd_config" ] || {
        _docker_stack_log_error "未找到 dockerd 配置文件：$dockerd_config"
        return 1
    }
    
    if [ "$dry_run" = "1" ]; then
        _docker_stack_log_info "[dry-run] dockerd Makefile 将更新 vendored 检查容忍缺失 installer 文件"
        [ -n "$storage_driver" ] && \
            _docker_stack_log_info "[dry-run] dockerd storage_driver 将设置为 $storage_driver"
        _docker_stack_log_info "[dry-run] dockerd 转发 sysctls 将设置为 1"
        return 0
    fi
    
    _docker_stack_fix_dockerd_vendored_checks "$dockerd_makefile" || return 1
    
    [ -n "$storage_driver" ] && \
        _docker_stack_set_or_append_dockerd_uci_option "$dockerd_config" "storage_driver" "$storage_driver" || return 1
    _docker_stack_fix_dockerd_nftables_comment "$dockerd_config"
    _docker_stack_log_info "dockerd 默认策略已应用"
    
    if [ -n "$dockerd_sysctl" ]; then
        _docker_stack_set_or_append_sysctl_value "$dockerd_sysctl" "net.ipv4.ip_forward" "1" || return 1
        _docker_stack_set_or_append_sysctl_value "$dockerd_sysctl" "net.ipv6.conf.all.forwarding" "1" || return 1
        _docker_stack_log_info "sysctl 网络转发已启用"
    else
        _docker_stack_log_warn "未找到 dockerd sysctl 文件（iStoreOS fork 使用 hotplug 处理），跳过 sysctl 设置"
    fi
}

#-------------------------------------------------------------------------------
# 显示帮助信息
#-------------------------------------------------------------------------------
_docker_stack_show_help() {
    cat <<'HELP'
用法：docker.sh [选项]

dockerd 默认配置工具 - 应用本项目对 dockerd 的默认配置
组件版本跟随 iStoreOS 25.12 feeds，脚本不再固定版本

环境变量:
  BUILD_DIR                        构建目录路径 (必需)
  DOCKER_STACK_STORAGE_DRIVER      存储驱动 (默认：vfs)
  DOCKER_STACK_DRY_RUN             预览模式，不修改文件 (0/1, 默认：0)
  DOCKER_STACK_LOG_LEVEL           日志级别 (debug/info/warn/error, 默认：info)
  DOCKER_STACK_QUIET               安静模式 (0/1, 默认：0)

示例:
  export BUILD_DIR="./openwrt"
  ./scripts/docker.sh

  DOCKER_STACK_DRY_RUN=1 ./scripts/docker.sh
  DOCKER_STACK_STORAGE_DRIVER=overlay2 ./scripts/docker.sh

注意:
  - dockerd 版本由 feeds 决定，本脚本不做版本升级
  - 自动跳过 dockerd 的 vendored 版本校验
  - 自动配置 nftables 注释与默认存储驱动
HELP
}

#-------------------------------------------------------------------------------
# 主函数：应用 dockerd 默认配置
#-------------------------------------------------------------------------------
update_docker_stack() {
    local build_dir="${BUILD_DIR:-}"
    local storage_driver="${DOCKER_STACK_STORAGE_DRIVER:-vfs}"
    local dry_run="${DOCKER_STACK_DRY_RUN:-0}"
    
    if [ -z "$build_dir" ]; then
        _docker_stack_log_error "BUILD_DIR 环境变量未设置"
        _docker_stack_log_error "用法：export BUILD_DIR=\"/path/to/openwrt\""
        return 1
    fi
    
    if [ "$dry_run" != "0" ] && [ "$dry_run" != "1" ]; then
        _docker_stack_log_error "DOCKER_STACK_DRY_RUN 仅支持 0 或 1，当前值：$dry_run"
        return 1
    fi
    
    build_dir=$(_docker_stack_normalize_build_dir "$build_dir")
    
    _docker_stack_log_info "开始配置 dockerd（组件版本跟随 feeds）..."
    _docker_stack_log_debug "BUILD_DIR: $build_dir"
    _docker_stack_log_info "  storage_driver: $storage_driver"
    _docker_stack_log_info "  dry_run: $dry_run"
    
    _docker_stack_update_dockerd_defaults "$build_dir" "$dry_run" "$storage_driver" || return 1
    
    if [ "$dry_run" = "1" ]; then
        _docker_stack_log_info "✓ dry-run 完成，未修改文件"
    else
        _docker_stack_log_info "✓ dockerd 默认配置已应用"
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# 帮助检测
#-------------------------------------------------------------------------------
if [[ "${1:-}" = "-h" ]] || [[ "${1:-}" = "--help" ]]; then
    _docker_stack_show_help
    exit 0
fi

# 如果直接执行（非 source），调用主函数
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    update_docker_stack
fi
