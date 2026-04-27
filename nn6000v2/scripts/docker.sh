#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2164,SC2069,SC2155
#===============================================================================
# Docker Stack Update Script for OpenWrt
# 
# 功能：自动更新和管理 OpenWrt 固件中的 Docker 相关组件
# 支持：runc, containerd, docker, dockerd
# 特性：nftables 防火墙后端支持，dockerman 兼容性
#===============================================================================

#-------------------------------------------------------------------------------
# 全局配置
#-------------------------------------------------------------------------------
DOCKER_STACK_MODULE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOCKER_STACK_REPO_ROOT=$(cd "$DOCKER_STACK_MODULE_DIR/../.." && pwd)

# 组件列表
DOCKER_STACK_COMPONENTS=("runc" "containerd" "docker" "dockerd")

# 文件路径配置
DOCKER_STACK_DOCKERD_MAKEFILE_REL="package/feeds/packages/dockerd/Makefile"
DOCKER_STACK_DOCKERD_CONFIG_REL="package/feeds/packages/dockerd/files/etc/config/dockerd"
DOCKER_STACK_DOCKERD_INIT_REL="package/feeds/packages/dockerd/files/dockerd.init"
DOCKER_STACK_DOCKERD_SYSCTL_REL="package/feeds/packages/dockerd/files/etc/sysctl.d/sysctl-br-netfilter-ip.conf"

# 日志配置
DOCKER_STACK_LOG_LEVEL="${DOCKER_STACK_LOG_LEVEL:-info}"
DOCKER_STACK_QUIET="${DOCKER_STACK_QUIET:-0}"

# 缓存配置
DOCKER_STACK_CACHE_DIR="${TMPDIR:-/tmp}/docker_stack_cache"
DOCKER_STACK_CACHE_TTL="${DOCKER_STACK_CACHE_TTL:-3600}"

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
# 缓存系统
#-------------------------------------------------------------------------------
_docker_stack_cache_init() {
    mkdir -p "$DOCKER_STACK_CACHE_DIR" 2>/dev/null || true
}

_docker_stack_cache_get() {
    local key="$1"
    local max_age="${2:-$DOCKER_STACK_CACHE_TTL}"
    local cache_file="$DOCKER_STACK_CACHE_DIR/$key"
    
    if [ -f "$cache_file" ]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [ $age -lt $max_age ]; then
            _docker_stack_log_debug "缓存命中：$key"
            cat "$cache_file"
            return 0
        else
            _docker_stack_log_debug "缓存过期：$key (age: ${age}s)"
        fi
    fi
    
    return 1
}

_docker_stack_cache_set() {
    local key="$1"
    local value="$2"
    local cache_file="$DOCKER_STACK_CACHE_DIR/$key"
    
    echo "$value" > "$cache_file" 2>/dev/null && \
        _docker_stack_log_debug "缓存已设置：$key"
}

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
# 项目验证
#-------------------------------------------------------------------------------
_docker_stack_validate_project() {
    local project_dir="$1"
    local component
    
    if [ ! -d "$project_dir" ]; then
        _docker_stack_log_error "OpenWrt 项目目录不存在：$project_dir"
        return 1
    fi
    
    for component in "${DOCKER_STACK_COMPONENTS[@]}"; do
        if ! _docker_stack_resolve_component_makefile "$project_dir" "$component" >/dev/null 2>&1; then
            _docker_stack_log_error "缺少组件 $component 的 Makefile"
            return 1
        fi
    done
    
    _docker_stack_log_debug "项目验证通过"
    return 0
}

#-------------------------------------------------------------------------------
# GitHub 仓库信息获取
#-------------------------------------------------------------------------------
_docker_stack_resolve_repo_from_makefile() {
    local mk_path="$1"
    local pkg_repo=""
    
    # 尝试 PKG_GIT_URL
    pkg_repo=$(grep -oE "^PKG_GIT_URL.*github.com(/[-_a-zA-Z0-9]{1,}){2}" "$mk_path" | \
               awk -F"/" '{print $(NF - 1) "/" $NF}' 2>/dev/null || true)
    
    # 尝试 PKG_SOURCE_URL
    if [ -z "$pkg_repo" ]; then
        pkg_repo=$(grep -oE "^PKG_SOURCE_URL.*github.com(/[-_a-zA-Z0-9]{1,}){2}" "$mk_path" | \
                   awk -F"/" '{print $(NF - 1) "/" $NF}' 2>/dev/null || true)
    fi
    
    if [ -z "$pkg_repo" ]; then
        _docker_stack_log_error "无法从 $mk_path 提取 GitHub 仓库路径"
        _docker_stack_log_error "检查 PKG_GIT_URL 或 PKG_SOURCE_URL 配置"
        return 1
    fi
    
    echo "$pkg_repo"
}

_docker_stack_resolve_target_tag() {
    local repo="$1"
    local branch="$2"
    local explicit_tag="$3"
    
    # 使用指定版本
    if [ -n "$explicit_tag" ]; then
        _docker_stack_log_debug "使用指定版本：$explicit_tag"
        echo "$explicit_tag"
        return 0
    fi
    
    # 检查缓存
    local cache_key="${repo//\//_}_${branch}"
    local target_tag
    
    if target_tag=$(_docker_stack_cache_get "$cache_key"); then
        echo "$target_tag"
        return 0
    fi
    
    # 从 GitHub API 获取
    _docker_stack_log_info "正在获取 $repo 的最新版本..."
    local api_url="https://api.github.com/repos/$repo/releases"
    
    target_tag=$(curl -fsSL "$api_url" 2>/dev/null | \
                 jq -r '.[0].tag_name' 2>/dev/null) || {
        _docker_stack_log_error "从 GitHub 获取 $repo 版本失败"
        return 1
    }
    
    if [ -z "$target_tag" ] || [ "$target_tag" = "null" ]; then
        _docker_stack_log_error "无法解析 $repo 的版本标签"
        return 1
    fi
    
    # 保存到缓存
    _docker_stack_cache_set "$cache_key" "$target_tag"
    echo "$target_tag"
}

#-------------------------------------------------------------------------------
# dockerd Git 引用更新
#-------------------------------------------------------------------------------
_docker_stack_update_dockerd_git_ref() {
    local mk_path="$1"
    local version_clean="$2"
    local major
    
    major=$(echo "$version_clean" | awk -F. '{print $1}')
    
    if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 29 ]; then
        _docker_stack_log_debug "Docker >= 29, 使用 docker-v 前缀"
        sed -i 's|^PKG_GIT_REF:=.*|PKG_GIT_REF:=docker-v$(PKG_VERSION)|g' "$mk_path"
    else
        _docker_stack_log_debug "Docker < 29, 使用 v 前缀"
        sed -i 's|^PKG_GIT_REF:=.*|PKG_GIT_REF:=v$(PKG_VERSION)|g' "$mk_path"
    fi
}

#-------------------------------------------------------------------------------
# UCI 配置修改
#-------------------------------------------------------------------------------
_docker_stack_set_or_append_dockerd_uci_option() {
    local config_path="$1"
    local option_name="$2"
    local option_value="$3"
    
    if grep -Eq "^[[:space:]]*option[[:space:]]+${option_name}[[:space:]]+" "$config_path"; then
        sed -i "s|^[[:space:]]*option[[:space:]]\+${option_name}[[:space:]]\+.*|\toption ${option_name} '${option_value}'|" "$config_path"
        _docker_stack_log_debug "已更新配置项：$option_name = $option_value"
    elif grep -q "^config globals 'globals'" "$config_path"; then
        sed -i "/^config globals 'globals'/a\	option ${option_name} '${option_value}'" "$config_path"
        _docker_stack_log_debug "已添加配置项：$option_name = $option_value"
    else
        _docker_stack_log_error "$config_path 中缺少 config globals 'globals' 段"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# sysctl 配置修改
#-------------------------------------------------------------------------------
_docker_stack_set_or_append_sysctl_value() {
    local sysctl_path="$1"
    local sysctl_key="$2"
    local sysctl_value="$3"
    local sysctl_key_regex="${sysctl_key//./\\.}"
    
    if grep -Eq "^[[:space:]]*${sysctl_key_regex}[[:space:]]*=" "$sysctl_path"; then
        sed -i "s|^[[:space:]]*${sysctl_key_regex}[[:space:]]*=.*|${sysctl_key}=${sysctl_value}|" "$sysctl_path"
        _docker_stack_log_debug "已更新 sysctl: $sysctl_key = $sysctl_value"
    else
        printf '%s=%s\n' "$sysctl_key" "$sysctl_value" >> "$sysctl_path"
        _docker_stack_log_debug "已添加 sysctl: $sysctl_key = $sysctl_value"
    fi
}

#-------------------------------------------------------------------------------
# 更新 dockerd Makefile 依赖
#-------------------------------------------------------------------------------
_docker_stack_update_dockerd_depends_block() {
    local mk_path="$1"
    local tmp_path
    
    tmp_path=$(_docker_stack_mktemp) || return 1
    
    awk '
        BEGIN { in_depends = 0; replaced = 0 }
        /^  DEPENDS:=\$\(GO_ARCH_DEPENDS\) \\$/ {
            in_depends = 1; replaced = 1
            print "  DEPENDS:=$(GO_ARCH_DEPENDS) \\" 
            print "    +ca-certificates \\" 
            print "    +containerd \\" 
            print "    +iptables-nft \\" 
            print "    +iptables-mod-extra \\" 
            print "    +IPV6:ip6tables-nft \\" 
            print "    +IPV6:kmod-ipt-nat6 \\" 
            print "    +KERNEL_SECCOMP:libseccomp \\" 
            print "    +kmod-ipt-nat \\" 
            print "    +kmod-ipt-physdev \\" 
            print "    +kmod-nf-ipvs \\" 
            print "    +kmod-veth \\" 
            print "    +nftables \\" 
            print "    +kmod-nft-nat \\" 
            print "    +tini \\" 
            print "    +uci-firewall \\" 
            print "    @!(mips||mips64||mipsel)"
            next
        }
        in_depends { if ($0 ~ /@!\(mips\|\|mips64\|\|mipsel\)/) in_depends = 0; next }
        { print }
        END { if (replaced == 0) exit 2 }
    ' "$mk_path" > "$tmp_path" || {
        _docker_stack_log_error "未能重写 $mk_path 的 DEPENDS 块"
        return 1
    }
    
    mv "$tmp_path" "$mk_path"
    _docker_stack_log_debug "已更新 dockerd Makefile 依赖"
}

#-------------------------------------------------------------------------------
# 修复 dockerd vendored 检查
#-------------------------------------------------------------------------------
_docker_stack_fix_dockerd_vendored_checks() {
    local mk_path="$1"
    local tmp_path
    
    tmp_path=$(_docker_stack_mktemp) || return 1
    
    awk '
        {
            if ($0 ~ /^[[:space:]]*\[ ! -f "\$\(PKG_BUILD_DIR\)\/hack\/dockerfile\/install\/containerd\.installer" \] \|\|[[:space:]]*\\$/) next
            if ($0 ~ /^[[:space:]]*\[ ! -f "\$\(PKG_BUILD_DIR\)\/hack\/dockerfile\/install\/runc\.installer" \] \|\|[[:space:]]*\\$/) next
            if ($0 ~ /^[[:space:]]*\$\(call EnsureVendoredVersion,\.\.\/containerd\/Makefile,containerd\.installer\)$/) {
                print "\t[ ! -f \"$(PKG_BUILD_DIR)/hack/dockerfile/install/containerd.installer\" ] || \\" 
                print "\t\t$(call EnsureVendoredVersion,../containerd/Makefile,containerd.installer)"
                next
            }
            if ($0 ~ /^[[:space:]]*\$\(call EnsureVendoredVersion,\.\.\/runc\/Makefile,runc\.installer\)$/) {
                print "\t[ ! -f \"$(PKG_BUILD_DIR)/hack/dockerfile/install/runc.installer\" ] || \\" 
                print "\t\t$(call EnsureVendoredVersion,../runc/Makefile,runc.installer)"
                next
            }
            print
        }
    ' "$mk_path" > "$tmp_path" || {
        _docker_stack_log_error "未能修补 vendored 依赖校验"
        return 1
    }
    
    mv "$tmp_path" "$mk_path"
    _docker_stack_log_debug "已修复 vendored 检查"
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
            "$config_path"
        _docker_stack_log_debug "已更新 nftables 注释"
    fi
}

#-------------------------------------------------------------------------------
# dockerman nftables 兼容性检测
#-------------------------------------------------------------------------------
_docker_stack_dockerman_init_supports_nftables_backend() {
    local dockerman_init="$1"
    
    grep -Fq 'dockerman_use_iptables() {' "$dockerman_init" 2>/dev/null \
        && grep -Fq 'dockerman_use_iptables || {' "$dockerman_init" 2>/dev/null
}

#-------------------------------------------------------------------------------
# 补丁 dockerman backend 辅助函数
#-------------------------------------------------------------------------------
_docker_stack_patch_dockerman_backend_helpers() {
    local dockerman_init="$1"
    local tmp_path
    
    grep -Fq 'dockerman_use_iptables() {' "$dockerman_init" 2>/dev/null && return 0
    
    tmp_path=$(_docker_stack_mktemp) || return 1
    
    awk '
        BEGIN { inserted = 0 }
        {
            print
            if ($0 ~ /^_DOCKERD=\/etc\/init\.d\/dockerd$/ && inserted == 0) {
                inserted = 1
                print ""
                print "dockerman_firewall_backend() {"
                print "\tlocal backend=\"\""
                print "\tbackend=\"$(uci -q get dockerd.globals.firewall_backend 2>/dev/null)\""
                print "\t[ -n \"${backend}\" ] || backend=\"nftables\""
                print "\techo \"${backend}\""
                print "}"
                print ""
                print "dockerman_use_iptables() {"
                print "\tlocal backend=\"\""
                print "\tlocal iptables_enabled=\"\""
                print ""
                print "\tbackend=\"$(dockerman_firewall_backend)\""
                print "\t[ \"${backend}\" = \"iptables\" ] || return 1"
                print ""
                print "\tiptables_enabled=\"$(uci -q get dockerd.globals.iptables 2>/dev/null)\""
                print "\t[ -n \"${iptables_enabled}\" ] || iptables_enabled=\"1\""
                print ""
                print "\t[ \"${iptables_enabled}\" = \"1\" ]"
                print "}"
            }
        }
        END { if (inserted == 0) exit 2 }
    ' "$dockerman_init" > "$tmp_path" || {
        _docker_stack_log_error "无法注入 firewall backend 辅助函数"
        return 1
    }
    
    mv "$tmp_path" "$dockerman_init"
    _docker_stack_log_debug "已注入 dockerman backend 辅助函数"
}

#-------------------------------------------------------------------------------
# 补丁 dockerman start_service
#-------------------------------------------------------------------------------
_docker_stack_patch_dockerman_start_service() {
    local dockerman_init="$1"
    local tmp_path
    
    grep -Fq 'dockerman_use_iptables || {' "$dockerman_init" 2>/dev/null && return 0
    
    tmp_path=$(_docker_stack_mktemp) || return 1
    
    awk '
        BEGIN { inserted = 0 }
        {
            print
            if ($0 ~ /^[[:space:]]*\$\(\$_DOCKERD running\) && docker_running \|\| return 0$/ && inserted == 0) {
                inserted = 1
                print "\tdockerman_use_iptables || {"
                print "\t\tlogger -t \"dockerman\" -p notice \"dockerd firewall backend is nftables; skip DOCKER-MAN iptables chain management\""
                print "\t\treturn 0"
                print "\t}"
            }
        }
        END { if (inserted == 0) exit 2 }
    ' "$dockerman_init" > "$tmp_path" || {
        _docker_stack_log_error "无法注入 nftables 分支"
        return 1
    }
    
    mv "$tmp_path" "$dockerman_init"
    _docker_stack_log_debug "已注入 dockerman start_service nftables 分支"
}

#-------------------------------------------------------------------------------
# 确保 dockerman nftables 兼容性
#-------------------------------------------------------------------------------
_docker_stack_ensure_dockerman_nftables_compat() {
    local dockerman_init="$1"
    
    _docker_stack_dockerman_init_supports_nftables_backend "$dockerman_init" && {
        _docker_stack_log_debug "dockerman 已支持 nftables"
        return 0
    }
    
    _docker_stack_log_warn "dockerman 缺少 nftables 兼容逻辑，正在补丁..."
    
    _docker_stack_patch_dockerman_backend_helpers "$dockerman_init" || return 1
    _docker_stack_patch_dockerman_start_service "$dockerman_init" || return 1
    
    _docker_stack_dockerman_init_supports_nftables_backend "$dockerman_init" || {
        _docker_stack_log_error "补丁后 dockerman 仍缺少 nftables 兼容逻辑"
        return 1
    }
    
    _docker_stack_log_info "dockerman nftables 兼容性已添加"
}

docker_stack_sync_dockerman_nftables_compat() {
    local build_dir="$1"
    local dry_run="${2:-0}"
    local dockerman_init=""
    
    [ -n "$build_dir" ] || {
        _docker_stack_log_error "缺少 build_dir 参数"
        return 1
    }
    
    build_dir=$(_docker_stack_normalize_build_dir "$build_dir")
    dockerman_init=$(_docker_stack_resolve_dockerman_init "$build_dir" || true)
    [ -n "$dockerman_init" ] || {
        _docker_stack_log_debug "未找到 dockerman init，跳过兼容性处理"
        return 0
    }
    
    if [ "$dry_run" = "1" ]; then
        if _docker_stack_dockerman_init_supports_nftables_backend "$dockerman_init"; then
            _docker_stack_log_info "[dry-run] dockerman 已支持 nftables"
        else
            _docker_stack_log_info "[dry-run] 将补丁 dockerman 以支持 nftables"
        fi
        return 0
    fi
    
    _docker_stack_ensure_dockerman_nftables_compat "$dockerman_init"
}

#-------------------------------------------------------------------------------
# dockerd init nftables 支持检测
#-------------------------------------------------------------------------------
_docker_stack_init_supports_nftables_backend() {
    local dockerd_init="$1"
    
    grep -Fq 'NFT_DOCKER_USER_TABLE="docker-user"' "$dockerd_init" 2>/dev/null \
        && grep -Fq 'verify_nftables_swarm_is_disabled "${data_root}" || return 1' "$dockerd_init" 2>/dev/null \
        && grep -Fq 'verify_nftables_forwarding || return 1' "$dockerd_init" 2>/dev/null \
        && grep -Fq 'verify_nftables_prerequisites "${data_root}" || return 1' "$dockerd_init" 2>/dev/null \
        && grep -Fq 'nft add rule inet "${NFT_DOCKER_USER_TABLE}" "${NFT_DOCKER_USER_CHAIN}" iifname "${inbound}" oifname "${outbound}" reject' "$dockerd_init" 2>/dev/null
}

#-------------------------------------------------------------------------------
# 补丁 dockerd init nftables 前置条件
#-------------------------------------------------------------------------------
_docker_stack_patch_nft_prereq_block() {
    local dockerd_init="$1"
    local tmp_path
    
    # 清理旧补丁
    if grep -Fq '# === DOCKER_STACK_NFT_PREREQ_START ===' "$dockerd_init"; then
        tmp_path=$(_docker_stack_mktemp) || return 1
        
        awk '
            BEGIN { in_block = 0 }
            {
                if ($0 ~ /^# === DOCKER_STACK_NFT_PREREQ_START ===$/) { in_block = 1; next }
                if ($0 ~ /^# === DOCKER_STACK_NFT_PREREQ_END ===$/) { in_block = 0; next }
                if (in_block == 0) print
            }
        ' "$dockerd_init" > "$tmp_path" || {
            _docker_stack_log_error "无法清理旧 nftables 前置校验块"
            return 1
        }
        
        mv "$tmp_path" "$dockerd_init"
        _docker_stack_log_debug "已清理旧 nftables 前置校验块"
    fi
    
    # 添加新补丁
    tmp_path=$(_docker_stack_mktemp) || return 1
    
    awk '
        BEGIN { inserted = 0 }
        {
            print
            if ($0 ~ /^DOCKERD_CONF="\$\{DOCKER_CONF_DIR\}\/daemon\.json"$/ && inserted == 0) {
                inserted = 1
                print ""
                print "# === DOCKER_STACK_NFT_PREREQ_START ==="
                print "NFT_DOCKER_USER_TABLE=\"docker-user\""
                print "NFT_DOCKER_USER_CHAIN=\"forward\""
                print ""
                print "BLOCKING_RULE_ERROR=0"
                print ""
                print "set_blocking_rule_error() {"
                print "\tBLOCKING_RULE_ERROR=1"
                print "}"
                print ""
                print "verify_nftables_swarm_is_disabled() {"
                print "\tlocal data_root=\"${1}\""
                print "\treturn 0"
                print "}"
                print ""
                print "verify_nftables_forwarding() {"
                print "\tlocal ipv4_forwarding=\"\""
                print "\tlocal ipv6_forwarding=\"\""
                print ""
                print "\tipv4_forwarding=\"$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)\""
                print "\tipv6_forwarding=\"$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)\""
                print ""
                print "\tif [ \"${ipv4_forwarding}\" != \"1\" ] || [ \"${ipv6_forwarding}\" != \"1\" ]; then"
                print "\t\tlogger -t \"dockerd-init\" -p err \"Docker nftables backend requires net.ipv4.ip_forward=1 and net.ipv6.conf.all.forwarding=1 before startup\""
                print "\t\treturn 1"
                print "\tfi"
                print ""
                print "\treturn 0"
                print "}"
                print ""
                print "verify_nftables_prerequisites() {"
                print "\tlocal data_root=\"${1}\""
                print ""
                print "\tverify_nftables_swarm_is_disabled \"${data_root}\" || return 1"
                print "\tverify_nftables_forwarding || return 1"
                print "}"
                print "# === DOCKER_STACK_NFT_PREREQ_END ==="
            }
        }
        END { if (inserted == 0) exit 2 }
    ' "$dockerd_init" > "$tmp_path" || {
        _docker_stack_log_error "无法注入 nftables 前置校验块"
        return 1
    }
    
    mv "$tmp_path" "$dockerd_init"
    _docker_stack_log_debug "已注入 nftables 前置校验块"
}

#-------------------------------------------------------------------------------
# 补丁 dockerd init process_config
#-------------------------------------------------------------------------------
_docker_stack_patch_process_config_nftables() {
    local dockerd_init="$1"
    local tmp_path
    
    # 添加 firewall_backend 变量
    sed -i 's/^[[:space:]]*local alt_config_file data_root log_level iptables ip6tables bip$/\tlocal alt_config_file data_root log_level firewall_backend iptables ip6tables bip/' "$dockerd_init"
    
    # 添加 firewall_backend 配置获取逻辑
    if ! grep -Fq 'config_get firewall_backend globals firewall_backend "nftables"' "$dockerd_init"; then
        tmp_path=$(_docker_stack_mktemp) || return 1
        
        awk '
            BEGIN { replaced = 0; skipping = 0 }
            {
                if ($0 ~ /^[[:space:]]*config_get data_root globals data_root "\/opt\/docker\/"$/) {
                    replaced = 1; skipping = 1
                    print "\tconfig_get data_root globals data_root \"/opt/docker/\""
                    print "\tconfig_get log_level globals log_level \"warn\""
                    print "\tif uci_quiet get dockerd.globals.firewall_backend; then"
                    print "\t\tconfig_get firewall_backend globals firewall_backend \"nftables\""
                    print "\telse"
                    print "\t\tfirewall_backend=\"nftables\""
                    print "\t\tlogger -t \"dockerd-init\" -p notice \"Migrating dockerd firewall backend to ${firewall_backend}\""
                    print "\t\tuci_quiet set dockerd.globals.firewall_backend=\"${firewall_backend}\" && uci_quiet commit dockerd || {"
                    print "\t\t\tlogger -t \"dockerd-init\" -p err \"Failed to persist dockerd firewall backend migration\""
                    print "\t\t\treturn 1"
                    print "\t\t}"
                    print "\tfi"
                    print "\tcase \"${firewall_backend}\" in"
                    print "\t\tiptables|nftables)"
                    print "\t\t\t;;"
                    print "\t\t*)"
                    print "\t\t\tlogger -t \"dockerd-init\" -p notice \"Unsupported dockerd firewall backend ${firewall_backend}, defaulting to nftables\""
                    print "\t\t\tfirewall_backend=\"nftables\""
                    print "\t\t\t;;"
                    print "\tesac"
                    print "\tif [ \"${firewall_backend}\" = \"nftables\" ]; then"
                    print "\t\t# 清理旧的 DOCKER-MAN iptables 规则"
                    print "\t\tif iptables -L DOCKER-MAN >/dev/null 2>&1; then"
                    print "\t\t\tiptables -F DOCKER-MAN"
                    print "\t\t\tiptables -X DOCKER-MAN"
                    print "\t\t\tlogger -t \"dockerd-init\" -p notice \"Cleaned up legacy DOCKER-MAN iptables chain\""
                    print "\t\tfi"
                    print "\t\tverify_nftables_prerequisites \"${data_root}\" || return 1"
                    print "\tfi"
                    print "\tconfig_get_bool iptables globals iptables \"1\""
                    print "\tconfig_get_bool ip6tables globals ip6tables \"0\""
                    next
                }
                if (skipping == 1) {
                    if ($0 ~ /^[[:space:]]*config_get_bool ip6tables globals ip6tables "0"$/) {
                        skipping = 0
                    }
                    next
                }
                print
            }
            END { if (replaced == 0) exit 2 }
        ' "$dockerd_init" > "$tmp_path" || {
            _docker_stack_log_error "无法重写 firewall_backend 配置段"
            return 1
        }
        
        mv "$tmp_path" "$dockerd_init"
        _docker_stack_log_debug "已添加 firewall_backend 配置"
    fi
    
    # 添加 firewall-backend JSON 字段
    if ! grep -Fq 'json_add_string "firewall-backend" "${firewall_backend}"' "$dockerd_init"; then
        sed -i '/^[[:space:]]*json_add_string "log-level" "${log_level}"$/a\	json_add_string "firewall-backend" "${firewall_backend}"' "$dockerd_init"
        _docker_stack_log_debug "已添加 firewall-backend JSON 字段"
    fi
    
    # 添加 BLOCKING_RULE_ERROR 初始化
    if ! grep -Fq 'BLOCKING_RULE_ERROR=0' "$dockerd_init"; then
        tmp_path=$(_docker_stack_mktemp) || return 1
        
        awk '
            BEGIN { replaced = 0 }
            {
                if ($0 ~ /^[[:space:]]*\[ "\$\{iptables\}" -eq "1" \] && config_foreach iptables_add_blocking_rule firewall$/) {
                    replaced = 1
                    print "\tBLOCKING_RULE_ERROR=0"
                    print "\tif [ \"${firewall_backend}\" = \"nftables\" ]; then"
                    print "\t\tnftables_create_blocking_table || {"
                    print "\t\t\tset_blocking_rule_error"
                    print "\t\t\treturn 1"
                    print "\t\t}"
                    print "\t\tif ! nft flush chain inet \"${NFT_DOCKER_USER_TABLE}\" \"${NFT_DOCKER_USER_CHAIN}\"; then"
                    print "\t\t\tlogger -t \"dockerd-init\" -p err \"Failed to reset nftables docker policy chain\""
                    print "\t\t\tset_blocking_rule_error"
                    print "\t\t\treturn 1"
                    print "\t\tfi"
                    print "\tfi"
                    print ""
                    print "\tconfig_foreach iptables_add_blocking_rule firewall \"${firewall_backend}\""
                    print "\t[ \"${BLOCKING_RULE_ERROR}\" -eq 0 ] || return 1"
                    next
                }
                print
            }
            END { if (replaced == 0) exit 2 }
        ' "$dockerd_init" > "$tmp_path" || {
            _docker_stack_log_error "无法重写 blocked_interfaces 处理段"
            return 1
        }
        
        mv "$tmp_path" "$dockerd_init"
        _docker_stack_log_debug "已添加 BLOCKING_RULE_ERROR 初始化"
    fi
}

#-------------------------------------------------------------------------------
# 补丁 service 错误处理
#-------------------------------------------------------------------------------
_docker_stack_patch_service_error_handling() {
    local dockerd_init="$1"
    
    sed -i '/^start_service() {/,/^}/{s/^[[:space:]]*process_config$/\tprocess_config || return 1/}' "$dockerd_init"
    sed -i '/^reload_service() {/,/^}/{s/^[[:space:]]*process_config$/\tprocess_config || return 1/}' "$dockerd_init"
    _docker_stack_log_debug "已添加 service 错误处理"
}

#-------------------------------------------------------------------------------
# 补丁 iptables 分发逻辑
#-------------------------------------------------------------------------------
_docker_stack_patch_iptables_dispatch() {
    local dockerd_init="$1"
    local tmp_path
    
    # 清理旧的注入
    tmp_path=$(_docker_stack_mktemp) || return 1
    
    awk '
        {
            if ($0 ~ /^[[:space:]]*local firewall_backend="\$\{2\}"$/) next
            if ($0 ~ /^[[:space:]]*local iptables="1"$/) next
            print
        }
    ' "$dockerd_init" > "$tmp_path" || {
        _docker_stack_log_error "无法清理旧的 firewall_backend 注入"
        return 1
    }
    
    mv "$tmp_path" "$dockerd_init"
    
    # 添加新注入
    if ! grep -Fq 'local firewall_backend="${2}"' "$dockerd_init"; then
        tmp_path=$(_docker_stack_mktemp) || return 1
        
        awk '
            BEGIN { in_target = 0; inserted = 0 }
            {
                if ($0 ~ /^iptables_add_blocking_rule\(\) \{$/) {
                    in_target = 1
                    print
                    next
                }
                if (in_target == 1 && $0 ~ /^[[:space:]]*local cfg="\$\{1\}"$/ && inserted == 0) {
                    inserted = 1
                    print $0
                    print "\tlocal firewall_backend=\"${2}\""
                    print "\tlocal iptables=\"1\""
                    print ""
                    next
                }
                if (in_target == 1 && $0 ~ /^}$/) in_target = 0
                print
            }
            END { if (inserted == 0) exit 2 }
        ' "$dockerd_init" > "$tmp_path" || {
            _docker_stack_log_error "无法注入 firewall_backend 参数"
            return 1
        }
        
        mv "$tmp_path" "$dockerd_init"
        _docker_stack_log_debug "已注入 firewall_backend 参数"
    fi
    
    # 添加 nftables 规则分支
    if ! grep -Fq 'nftables_add_blocking_rules "${cfg}"' "$dockerd_init"; then
        tmp_path=$(_docker_stack_mktemp) || return 1
        
        awk '
            BEGIN { in_target = 0; inserted = 0 }
            {
                if ($0 ~ /^iptables_add_blocking_rule\(\) \{$/) {
                    in_target = 1
                    print
                    next
                }
                if (in_target == 1 && $0 ~ /^[[:space:]]*config_get device "\$\{cfg\}" device$/ && inserted == 0) {
                    inserted = 1
                    print "\tif [ \"${firewall_backend}\" = \"nftables\" ]; then"
                    print "\t\tnftables_add_blocking_rules \"${cfg}\""
                    print "\t\treturn"
                    print "\tfi"
                    print ""
                    print "\tconfig_get_bool iptables globals iptables \"1\""
                    print "\t[ \"${iptables}\" -eq \"1\" ] || return"
                    print ""
                }
                if (in_target == 1 && $0 ~ /^}$/) in_target = 0
                print
            }
            END { if (inserted == 0) exit 2 }
        ' "$dockerd_init" > "$tmp_path" || {
            _docker_stack_log_error "无法注入 nftables 规则分支"
            return 1
        }
        
        mv "$tmp_path" "$dockerd_init"
        _docker_stack_log_debug "已注入 nftables 规则分支"
    fi
}

#-------------------------------------------------------------------------------
# 追加 nftables 规则辅助函数
#-------------------------------------------------------------------------------
_docker_stack_patch_append_nft_rule_helpers() {
    local dockerd_init="$1"
    local tmp_path
    
    grep -Fq 'nftables_create_blocking_table() {' "$dockerd_init" 2>/dev/null && \
    grep -Fq 'nftables_add_blocking_rules() {' "$dockerd_init" 2>/dev/null && {
        _docker_stack_log_debug "nftables 辅助函数已存在"
        return 0
    }
    
    tmp_path=$(_docker_stack_mktemp) || return 1
    
    awk '
        BEGIN { inserted = 0 }
        {
            if ($0 ~ /^stop_service\(\) \{$/ && inserted == 0) {
                inserted = 1
                print "nftables_create_blocking_table() {"
                print "\tif ! nft list table inet \"${NFT_DOCKER_USER_TABLE}\" >/dev/null 2>&1; then"
                print "\t\tif ! nft add table inet \"${NFT_DOCKER_USER_TABLE}\"; then"
                print "\t\t\tlogger -t \"dockerd-init\" -p err \"Failed to create nftables table inet ${NFT_DOCKER_USER_TABLE}\""
                print "\t\t\treturn 1"
                print "\t\tfi"
                print "\tfi"
                print ""
                print "\tif ! nft list chain inet \"${NFT_DOCKER_USER_TABLE}\" \"${NFT_DOCKER_USER_CHAIN}\" >/dev/null 2>&1; then"
                print "\t\tif ! nft add chain inet \"${NFT_DOCKER_USER_TABLE}\" \"${NFT_DOCKER_USER_CHAIN}\" '\''{ type filter hook forward priority 0; policy accept; }'\''; then"
                print "\t\t\tlogger -t \"dockerd-init\" -p err \"Failed to create nftables chain inet ${NFT_DOCKER_USER_TABLE} ${NFT_DOCKER_USER_CHAIN}\""
                print "\t\t\treturn 1"
                print "\t\tfi"
                print "\tfi"
                print "}"
                print ""
                print "nftables_add_blocking_rules() {"
                print "\tlocal cfg=\"${1}\""
                print ""
                print "\tlocal device=\"\""
                print "\tlocal extra_iptables_args=\"\""
                print ""
                print "\thandle_nftables_rule() {"
                print "\t\tlocal interface=\"${1}\""
                print "\t\tlocal outbound=\"${2}\""
                print ""
                print "\t\tlocal inbound=\"\""
                print ""
                print "\t\t. /lib/functions/network.sh"
                print "\t\tnetwork_get_physdev inbound \"${interface}\""
                print ""
                print "\t\t[ -z \"${inbound}\" ] && {"
                print "\t\t\tlogger -t \"dockerd-init\" -p notice \"Unable to get physical device for interface ${interface}\""
                print "\t\t\treturn"
                print "\t\t}"
                print ""
                print "\t\tlogger -t \"dockerd-init\" -p notice \"Drop traffic from ${inbound} to ${outbound}\""
                print "\t\tif ! nft add rule inet \"${NFT_DOCKER_USER_TABLE}\" \"${NFT_DOCKER_USER_CHAIN}\" iifname \"${inbound}\" oifname \"${outbound}\" reject; then"
                print "\t\t\tlogger -t \"dockerd-init\" -p err \"Failed to add nftables docker policy from ${inbound} to ${outbound}\""
                print "\t\t\tset_blocking_rule_error"
                print "\t\t\treturn 1"
                print "\t\tfi"
                print "\t}"
                print ""
                print "\tconfig_get device \"${cfg}\" device"
                print ""
                print "\t[ -z \"${device}\" ] && {"
                print "\t\tlogger -t \"dockerd-init\" -p notice \"No device configured for ${cfg}\""
                print "\t\treturn"
                print "\t}"
                print ""
                print "\tconfig_get extra_iptables_args \"${cfg}\" extra_iptables_args"
                print "\t[ -n \"${extra_iptables_args}\" ] && {"
                print "\t\tlogger -t \"dockerd-init\" -p err \"extra_iptables_args is not supported when firewall_backend is nftables\""
                print "\t\tset_blocking_rule_error"
                print "\t\treturn 1"
                print "\t}"
                print ""
                print "\tconfig_list_foreach \"${cfg}\" blocked_interfaces handle_nftables_rule \"${device}\""
                print "}"
                print ""
            }
            print
        }
        END { if (inserted == 0) exit 2 }
    ' "$dockerd_init" > "$tmp_path" || {
        _docker_stack_log_error "无法追加 nftables 规则函数"
        return 1
    }
    
    mv "$tmp_path" "$dockerd_init"
    _docker_stack_log_debug "已追加 nftables 规则函数"
}

#-------------------------------------------------------------------------------
# 确保 dockerd init 支持 nftables
#-------------------------------------------------------------------------------
_docker_stack_ensure_nftables_init_support() {
    local dockerd_init="$1"
    
    if _docker_stack_init_supports_nftables_backend "$dockerd_init"; then
        _docker_stack_log_debug "dockerd init 已支持 nftables"
        _docker_stack_patch_iptables_dispatch "$dockerd_init" || return 1
        return 0
    fi
    
    _docker_stack_log_warn "dockerd init 缺少 nftables 支持，正在补丁..."
    
    _docker_stack_patch_nft_prereq_block "$dockerd_init" || return 1
    _docker_stack_patch_process_config_nftables "$dockerd_init" || return 1
    _docker_stack_patch_service_error_handling "$dockerd_init" || return 1
    _docker_stack_patch_iptables_dispatch "$dockerd_init" || return 1
    _docker_stack_patch_append_nft_rule_helpers "$dockerd_init" || return 1
    
    _docker_stack_init_supports_nftables_backend "$dockerd_init" || {
        _docker_stack_log_error "补丁后 dockerd init 仍缺少 nftables 支持"
        return 1
    }
    
    _docker_stack_log_info "dockerd init nftables 支持已添加"
}

#-------------------------------------------------------------------------------
# 更新 dockerd nftables 默认配置
#-------------------------------------------------------------------------------
_docker_stack_update_dockerd_nftables_defaults() {
    local build_dir="$1"
    local dry_run="$2"
    local storage_driver="$3"
    local dockerd_makefile=""
    local dockerd_config=""
    local dockerd_init=""
    local dockerd_sysctl=""
    
    dockerd_makefile=$(_docker_stack_resolve_component_makefile "$build_dir" "dockerd") || return 1
    dockerd_config=$(_docker_stack_resolve_dockerd_file "$build_dir" "files/etc/config/dockerd") || return 1
    dockerd_init=$(_docker_stack_resolve_dockerd_file "$build_dir" "files/dockerd.init") || return 1
    dockerd_sysctl=$(_docker_stack_resolve_dockerd_file "$build_dir" "files/etc/sysctl.d/sysctl-br-netfilter-ip.conf") || return 1
    
    [ -f "$dockerd_makefile" ] || {
        _docker_stack_log_error "未找到 dockerd Makefile: $dockerd_makefile"
        return 1
    }
    [ -f "$dockerd_config" ] || {
        _docker_stack_log_error "未找到 dockerd 配置文件：$dockerd_config"
        return 1
    }
    [ -f "$dockerd_init" ] || {
        _docker_stack_log_error "未找到 dockerd init: $dockerd_init"
        return 1
    }
    [ -f "$dockerd_sysctl" ] || {
        _docker_stack_log_error "未找到 dockerd sysctl: $dockerd_sysctl"
        return 1
    }
    
    if [ "$dry_run" = "1" ]; then
        _docker_stack_log_info "[dry-run] dockerd Makefile 将更新 DEPENDS 为 nftables 兼容"
        _docker_stack_log_info "[dry-run] dockerd Makefile vendored 检查将容忍缺失 installer 文件"
        if _docker_stack_init_supports_nftables_backend "$dockerd_init"; then
            _docker_stack_log_info "[dry-run] dockerd firewall_backend 将设置为 nftables"
        else
            _docker_stack_log_info "[dry-run] dockerd init 缺少 nftables 支持，将进行补丁"
            _docker_stack_log_info "[dry-run] dockerd firewall_backend 将在补丁后设置为 nftables"
        fi
        [ -n "$storage_driver" ] && \
            _docker_stack_log_info "[dry-run] dockerd storage_driver 将设置为 $storage_driver"
        _docker_stack_log_info "[dry-run] dockerd 转发 sysctls 将设置为 1"
        docker_stack_sync_dockerman_nftables_compat "$build_dir" "1" || return 1
        return 0
    fi
    
    _docker_stack_update_dockerd_depends_block "$dockerd_makefile" || return 1
    _docker_stack_fix_dockerd_vendored_checks "$dockerd_makefile" || return 1
    
    _docker_stack_ensure_nftables_init_support "$dockerd_init" || return 1
    docker_stack_sync_dockerman_nftables_compat "$build_dir" "0" || return 1
    
    _docker_stack_set_or_append_dockerd_uci_option "$dockerd_config" "firewall_backend" "nftables" || return 1
    [ -n "$storage_driver" ] && \
        _docker_stack_set_or_append_dockerd_uci_option "$dockerd_config" "storage_driver" "$storage_driver" || return 1
    _docker_stack_fix_dockerd_nftables_comment "$dockerd_config"
    _docker_stack_log_info "dockerd nftables 默认策略已应用"
    
    _docker_stack_set_or_append_sysctl_value "$dockerd_sysctl" "net.ipv4.ip_forward" "1" || return 1
    _docker_stack_set_or_append_sysctl_value "$dockerd_sysctl" "net.ipv6.conf.all.forwarding" "1" || return 1
    _docker_stack_log_info "sysctl 网络转发已启用"
}

#-------------------------------------------------------------------------------
# 获取短提交哈希
#-------------------------------------------------------------------------------
_docker_stack_resolve_short_commit() {
    local mk_path="$1"
    local version_clean="$2"
    local pkg_git_url=""
    local pkg_git_ref=""
    
    pkg_git_url=$(awk -F"=" '/^PKG_GIT_URL:=/ {print $NF}' "$mk_path")
    pkg_git_ref=$(awk -F"=" '/^PKG_GIT_REF:=/ {print $NF}' "$mk_path")
    
    if [ -z "$pkg_git_url" ] || [ -z "$pkg_git_ref" ]; then
        _docker_stack_log_error "$mk_path 缺少 PKG_GIT_URL 或 PKG_GIT_REF"
        return 1
    fi
    
    local pkg_git_ref_resolved=""
    local pkg_git_ref_tag=""
    pkg_git_ref_resolved=$(echo "$pkg_git_ref" | sed "s/\$(PKG_VERSION)/$version_clean/g; s/\${PKG_VERSION}/$version_clean/g")
    pkg_git_ref_tag="${pkg_git_ref_resolved#refs/tags/}"
    
    local remote_url=""
    if [[ "$pkg_git_url" = http* ]]; then
        remote_url="$pkg_git_url"
    else
        remote_url="https://$pkg_git_url"
    fi
    
    local ls_remote_output=""
    ls_remote_output=$(git ls-remote "$remote_url" "refs/tags/${pkg_git_ref_tag}" "refs/tags/${pkg_git_ref_tag}^{}" 2>/dev/null || true)
    
    local commit_sha=""
    commit_sha=$(echo "$ls_remote_output" | awk '/\^\{\}$/ {print $1; exit}')
    [ -z "$commit_sha" ] && commit_sha=$(echo "$ls_remote_output" | awk 'NR==1{print $1}')
    [ -z "$commit_sha" ] && commit_sha=$(git ls-remote "$remote_url" "${pkg_git_ref_resolved}^{}" 2>/dev/null | awk 'NR==1{print $1}')
    [ -z "$commit_sha" ] && commit_sha=$(git ls-remote "$remote_url" "$pkg_git_ref_resolved" 2>/dev/null | awk 'NR==1{print $1}')
    
    if [ -z "$commit_sha" ]; then
        _docker_stack_log_error "无法获取 $pkg_git_ref_resolved 的提交哈希"
        return 1
    fi
    
    echo "$commit_sha" | cut -c1-7
}

#-------------------------------------------------------------------------------
# 计算软件包哈希
#-------------------------------------------------------------------------------
_docker_stack_compute_package_hash() {
    local mk_path="$1"
    local version_clean="$2"
    local pkg_name=""
    local pkg_source=""
    local pkg_source_url=""
    local pkg_git_url=""
    local pkg_git_ref=""
    
    pkg_name=$(awk -F"=" '/^PKG_NAME:=/ {print $NF}' "$mk_path" | grep -oE "[-_:/\$\(\)\?\.a-zA-Z0-9]{1,}")
    pkg_source=$(awk -F"=" '/^PKG_SOURCE:=/ {print $NF}' "$mk_path" | grep -oE "[-_:/\$\(\)\?\.a-zA-Z0-9]{1,}")
    pkg_source_url=$(awk -F"=" '/^PKG_SOURCE_URL:=/ {print $NF}' "$mk_path" | grep -oE "[-_:/\$\(\)\{\}\?\.a-zA-Z0-9]{1,}")
    pkg_git_url=$(awk -F"=" '/^PKG_GIT_URL:=/ {print $NF}' "$mk_path")
    pkg_git_ref=$(awk -F"=" '/^PKG_GIT_REF:=/ {print $NF}' "$mk_path")
    
    pkg_source_url=${pkg_source_url//\$\(PKG_GIT_URL\)/$pkg_git_url}
    pkg_source_url=${pkg_source_url//\$\(PKG_GIT_REF\)/$pkg_git_ref}
    pkg_source_url=${pkg_source_url//\$\(PKG_NAME\)/$pkg_name}
    pkg_source_url=$(echo "$pkg_source_url" | sed "s/\${PKG_VERSION}/$version_clean/g; s/\$(PKG_VERSION)/$version_clean/g")
    
    pkg_source=${pkg_source//\$\(PKG_NAME\)/$pkg_name}
    pkg_source=${pkg_source//\$\(PKG_VERSION\)/$version_clean}
    
    local pkg_hash=""
    if ! pkg_hash=$(curl -fsSL "$pkg_source_url$pkg_source" 2>/dev/null | sha256sum | cut -b -64); then
        _docker_stack_log_error "无法获取软件包哈希：$pkg_source_url$pkg_source"
        return 1
    fi
    
    echo "$pkg_hash"
}

#-------------------------------------------------------------------------------
# 更新单个组件
#-------------------------------------------------------------------------------
_docker_stack_update_component() {
    local component="$1"
    local mk_path="$2"
    local branch="$3"
    local explicit_tag="$4"
    local dry_run="$5"
    
    [ -f "$mk_path" ] || {
        _docker_stack_log_error "未找到 $component Makefile: $mk_path"
        return 1
    }
    
    local repo=""
    repo=$(_docker_stack_resolve_repo_from_makefile "$mk_path") || return 1
    
    local target_tag=""
    target_tag=$(_docker_stack_resolve_target_tag "$repo" "$branch" "$explicit_tag") || return 1
    
    local version_clean="${target_tag#v}"
    
    if [ "$dry_run" = "1" ]; then
        if [ "$component" = "dockerd" ]; then
            local major=""
            major=$(echo "$version_clean" | awk -F. '{print $1}')
            if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 29 ]; then
                _docker_stack_log_info "[dry-run] dockerd 将使用 PKG_GIT_REF:=docker-v\$(PKG_VERSION)"
            else
                _docker_stack_log_info "[dry-run] dockerd 将使用 PKG_GIT_REF:=v\$(PKG_VERSION)"
            fi
        fi
        _docker_stack_log_info "[dry-run] $component -> $target_tag ($mk_path)"
        return 0
    fi
    
    if [ "$component" = "dockerd" ]; then
        _docker_stack_update_dockerd_git_ref "$mk_path" "$version_clean"
        _docker_stack_log_debug "已更新 dockerd Git 引用"
    fi
    
    if grep -q '^PKG_GIT_SHORT_COMMIT:=' "$mk_path"; then
        local short_commit=""
        short_commit=$(_docker_stack_resolve_short_commit "$mk_path" "$version_clean") || return 1
        sed -i "s/^PKG_GIT_SHORT_COMMIT:=.*/PKG_GIT_SHORT_COMMIT:=$short_commit/g" "$mk_path"
        _docker_stack_log_debug "已更新短提交哈希：$short_commit"
    fi
    
    local pkg_hash=""
    pkg_hash=$(_docker_stack_compute_package_hash "$mk_path" "$version_clean") || return 1
    
    sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$version_clean/g" "$mk_path"
    sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$pkg_hash/g" "$mk_path"
    
    _docker_stack_log_info "✓ $component 已更新到 $version_clean"
}

#-------------------------------------------------------------------------------
# 验证更新
#-------------------------------------------------------------------------------
_docker_stack_verify_update() {
    local mk_path="$1"
    local expected_version="$2"
    local component="$3"
    
    local actual_version
    actual_version=$(awk -F"=" '/^PKG_VERSION:=/ {print $NF}' "$mk_path")
    
    if [ "$actual_version" != "$expected_version" ]; then
        _docker_stack_log_error "[$component] 版本验证失败"
        _docker_stack_log_error "  期望：$expected_version"
        _docker_stack_log_error "  实际：$actual_version"
        return 1
    fi
    
    local actual_hash
    actual_hash=$(awk -F"=" '/^PKG_HASH:=/ {print $NF}' "$mk_path")
    
    if [ -z "$actual_hash" ] || [ ${#actual_hash} -ne 64 ]; then
        _docker_stack_log_error "[$component] HASH 验证失败"
        _docker_stack_log_error "  HASH: $actual_hash"
        return 1
    fi
    
    _docker_stack_log_debug "[$component] 验证通过：$actual_version"
    return 0
}

#-------------------------------------------------------------------------------
# 显示帮助信息
#-------------------------------------------------------------------------------
_docker_stack_show_help() {
    cat <<'HELP'
用法：docker.sh [选项]

Docker 堆栈更新工具 - 自动更新 OpenWrt 固件中的 Docker 组件

环境变量:
  BUILD_DIR                        OpenWrt 构建目录路径 (必需)
  DOCKER_STACK_RUNC_VERSION        runc 版本 (默认：v1.3.3)
  DOCKER_STACK_CONTAINERD_VERSION  containerd 版本 (默认：v1.7.28)
  DOCKER_STACK_DOCKER_VERSION      docker 版本 (默认：v29.3.1)
  DOCKER_STACK_DOCKERD_VERSION     dockerd 版本 (默认：同 DOCKER_STACK_DOCKER_VERSION)
  DOCKER_STACK_STORAGE_DRIVER      存储驱动 (默认：overlay2)
  DOCKER_STACK_DRY_RUN             预览模式，不修改文件 (0/1, 默认：0)
  DOCKER_STACK_LOG_LEVEL           日志级别 (debug/info/warn/error, 默认：info)
  DOCKER_STACK_QUIET               安静模式 (0/1, 默认：0)
  DOCKER_STACK_CACHE_TTL           缓存时间 (秒，默认：3600)

示例:
  # 基本使用
  export BUILD_DIR="./openwrt"
  ./scripts/docker.sh

  # 使用特定版本
  DOCKER_STACK_DOCKERD_VERSION=v28.0.0 ./scripts/docker.sh

  # 预览模式
  DOCKER_STACK_DRY_RUN=1 ./scripts/docker.sh

  # 详细日志
  DOCKER_STACK_LOG_LEVEL=debug ./scripts/docker.sh

  # 使用 overlay2 存储驱动
  DOCKER_STACK_STORAGE_DRIVER=overlay2 ./scripts/docker.sh

  # 组合使用
  DOCKER_STACK_DRY_RUN=1 \
  DOCKER_STACK_LOG_LEVEL=debug \
  DOCKER_STACK_STORAGE_DRIVER=overlay2 \
  ./scripts/docker.sh

注意:
  - 本脚本会自动配置 nftables 防火墙后端
  - 确保 dockerman 插件与 nftables 兼容
  - 使用缓存减少 GitHub API 调用频率
HELP
}

#-------------------------------------------------------------------------------
# 主函数：更新 Docker 堆栈
#-------------------------------------------------------------------------------
update_docker_stack() {
    local build_dir="${BUILD_DIR:-}"
    local runc_version="${DOCKER_STACK_RUNC_VERSION:-v1.3.5}"
    local containerd_version="${DOCKER_STACK_CONTAINERD_VERSION:-v1.7.30}"
    local docker_version="${DOCKER_STACK_DOCKER_VERSION:-v29.3.1}"
    local dockerd_version="${DOCKER_STACK_DOCKERD_VERSION:-$docker_version}"
    local storage_driver="${DOCKER_STACK_STORAGE_DRIVER:-vfs}"
    local dry_run="${DOCKER_STACK_DRY_RUN:-0}"
    
    # 默认资源限制配置
    local default_cpu_quota="${DOCKER_STACK_DEFAULT_CPU_QUOTA:-100000}"
    local default_cpu_period="${DOCKER_STACK_DEFAULT_CPU_PERIOD:-100000}"
    local default_memory="${DOCKER_STACK_DEFAULT_MEMORY:-512m}"
    local default_memory_swap="${DOCKER_STACK_DEFAULT_MEMORY_SWAP:-1g}"
    local default_blkio_weight="${DOCKER_STACK_DEFAULT_BLKIO_WEIGHT:-500}"
    
    # 高效网络模式配置
    local default_network_driver="${DOCKER_STACK_DEFAULT_NETWORK_DRIVER:-bridge}"
    local enable_ipvlan="${DOCKER_STACK_ENABLE_IPVLAN:-0}"
    local enable_macvlan="${DOCKER_STACK_ENABLE_MACVLAN:-0}"
    local network_opts="${DOCKER_STACK_NETWORK_OPTS:-}"
    
    local runc_makefile=""
    local containerd_makefile=""
    local docker_makefile=""
    local dockerd_makefile=""
    
    # 检查必需参数
    if [ -z "$build_dir" ]; then
        _docker_stack_log_error "BUILD_DIR 环境变量未设置"
        _docker_stack_log_error "用法：export BUILD_DIR=\"/path/to/openwrt\""
        return 1
    fi
    
    # 验证 dry_run 参数
    if [ "$dry_run" != "0" ] && [ "$dry_run" != "1" ]; then
        _docker_stack_log_error "DOCKER_STACK_DRY_RUN 仅支持 0 或 1，当前值：$dry_run"
        return 1
    fi
    
    # 初始化
    _docker_stack_cache_init
    build_dir=$(_docker_stack_normalize_build_dir "$build_dir")
    
    _docker_stack_log_info "开始更新 Docker 组件..."
    _docker_stack_log_debug "BUILD_DIR: $build_dir"
    
    # 验证项目
    _docker_stack_validate_project "$build_dir" || return 1
    
    # 解析 Makefile 路径
    runc_makefile=$(_docker_stack_resolve_component_makefile "$build_dir" "runc") || return 1
    containerd_makefile=$(_docker_stack_resolve_component_makefile "$build_dir" "containerd") || return 1
    docker_makefile=$(_docker_stack_resolve_component_makefile "$build_dir" "docker") || return 1
    dockerd_makefile=$(_docker_stack_resolve_component_makefile "$build_dir" "dockerd") || return 1
    
    # 显示配置
    _docker_stack_log_info "配置信息:"
    _docker_stack_log_info "  runc: $runc_version"
    _docker_stack_log_info "  containerd: $containerd_version"
    _docker_stack_log_info "  docker: $docker_version"
    _docker_stack_log_info "  dockerd: $dockerd_version"
    _docker_stack_log_info "  storage_driver: $storage_driver"
    _docker_stack_log_info "  dry_run: $dry_run"
    
    # 更新组件
    _docker_stack_update_component "runc" "$runc_makefile" "releases" "$runc_version" "$dry_run" || return 1
    _docker_stack_update_component "containerd" "$containerd_makefile" "releases" "$containerd_version" "$dry_run" || return 1
    _docker_stack_update_component "docker" "$docker_makefile" "tags" "$docker_version" "$dry_run" || return 1
    _docker_stack_update_component "dockerd" "$dockerd_makefile" "releases" "$dockerd_version" "$dry_run" || return 1
    
    # 配置 nftables 默认值
    _docker_stack_update_dockerd_nftables_defaults "$build_dir" "$dry_run" "$storage_driver" || return 1
    
    # 完成
    if [ "$dry_run" = "1" ]; then
        _docker_stack_log_info "✓ dry-run 完成，未修改文件"
    else
        _docker_stack_log_info "✓ Docker 组件更新完成"
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
