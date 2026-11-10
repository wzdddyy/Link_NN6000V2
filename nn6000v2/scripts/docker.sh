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
# 修复 dockerd vendored 检查
#-------------------------------------------------------------------------------
_docker_stack_fix_dockerd_vendored_checks() {
    local mk_path="$1"
    local tmp_path
    
    tmp_path=$(_docker_stack_mktemp) || return 1
    
    # 检测是否有 EnsureVendoredVersion 调用
    if grep -q '\$(call EnsureVendoredVersion,' "$mk_path"; then
        _docker_stack_log_debug "检测到 vendored 版本检查，正在禁用严格验证..."
        
        # 使用 awk 注释掉 Build/Prepare 中的所有版本验证
        awk '
            BEGIN { in_prepare = 0; skip_lines = 0 }
            /^define Build\/Prepare/ { in_prepare = 1; print; next }
            in_prepare && /^endef$/ { in_prepare = 0; print; next }
            
            # 注释掉 EnsureVendoredVersion 调用（第 84-86 行）
            in_prepare && /[[:space:]]*\$\(call EnsureVendoredVersion,/ {
                print "#" $0 " # Disabled by docker_stack"
                next
            }
            
            # 处理 CLI 版本检查（第 89-95 行，共 7 行）
            in_prepare && /[[:space:]]*CLI_MAKEFILE=/ {
                print "#" $0 " # Disabled by docker_stack"
                skip_lines = 6
                next
            }
            
            # 处理 PKG_GIT_SHORT_COMMIT 检查（第 98-103 行，共 6 行）
            in_prepare && /[[:space:]]*EXPECTED_PKG_GIT_SHORT_COMMIT=/ {
                print "#" $0 " # Disabled by docker_stack"
                skip_lines = 5
                next
            }
            
            # 跳过需要注释的后续行
            skip_lines > 0 {
                print "#" $0 " # Disabled by docker_stack"
                skip_lines--
                next
            }
            
            { print }
        ' "$mk_path" > "$tmp_path" || {
            _docker_stack_log_error "未能禁用 vendored 严格验证"
            return 1
        }
        
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
  DOCKER_STACK_RUNC_VERSION        runc 版本 (默认：v1.3.5)
  DOCKER_STACK_CONTAINERD_VERSION  containerd 版本 (默认：v2.2.3)
  DOCKER_STACK_DOCKER_VERSION      docker 版本 (默认：v29.4.1)
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
    local containerd_version="${DOCKER_STACK_CONTAINERD_VERSION:-v2.2.3}"
    local docker_version="${DOCKER_STACK_DOCKER_VERSION:-v29.4.1}"
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
    
    # 配置 dockerd 默认值
    _docker_stack_update_dockerd_defaults "$build_dir" "$dry_run" "$storage_driver" || return 1
    
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
