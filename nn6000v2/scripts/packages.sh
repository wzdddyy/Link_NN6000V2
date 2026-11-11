#!/usr/bin/env bash

GITHUB_BASE="https://github.com/"
OPENWRT_PACKAGES_DIR="$BUILD_DIR/feeds/openwrt_packages"

update_golang() {
    if [[ -d ./feeds/packages/lang/golang ]]; then
        \rm -rf ./feeds/packages/lang/golang
        if ! git clone --depth 1 -b $GOLANG_BRANCH $GOLANG_REPO ./feeds/packages/lang/golang; then
            echo "错误：克隆 golang 仓库 $GOLANG_REPO 失败" >&2
            exit 1
        fi
        echo "✓ golang 软件包更新完成"
    fi
}

clone_packages() {
    local name="$1"
    local repo_url="$2"
    local target_dir="$3"
    local sparse_pattern="${4:-}"
    local pre_cmd="${5:-}"
    local post_cmd="${6:-}"
    local move_from="${7:-}"
    local move_to="${8:-}"
    local branch="${9:-}"
    local clone_args=()
    
    if [ -n "$branch" ]; then
        clone_args=(-b "$branch")
    fi
    
    if [ -n "$pre_cmd" ]; then
        (cd "$BUILD_DIR" && eval "$pre_cmd") || exit 1
    fi
    
    rm -rf "$target_dir" 2>/dev/null || true
    
    if [ -n "$sparse_pattern" ]; then
        if ! git clone --filter=blob:none --no-checkout "${clone_args[@]}" "$repo_url" "$target_dir"; then
            echo "错误：从 $repo_url 克隆 $name 仓库失败" >&2
            exit 1
        fi
        
        pushd "$target_dir" >/dev/null
        git sparse-checkout init --cone
        if ! git sparse-checkout set $sparse_pattern; then
            echo "错误：稀疏检出 $sparse_pattern 失败" >&2
            popd >/dev/null
            exit 1
        fi
        git checkout --quiet
        popd >/dev/null
        
        if [ -n "$move_from" ] && [ -n "$move_to" ]; then
            rm -rf "$move_to" 2>/dev/null || true
            mv "$move_from" "$move_to" || exit 1
        fi
    else
        if ! git clone --depth=1 "${clone_args[@]}" "$repo_url" "$target_dir"; then
            echo "错误：从 $repo_url 克隆 $name 仓库失败" >&2
            exit 1
        fi
    fi
    
    if [ -n "$post_cmd" ]; then
        (cd "$BUILD_DIR" && eval "$post_cmd") || exit 1
    fi
    
    echo "✓ $name 克隆完成"
}

fix_apk_pkg_version() {
    local makefile="$1"

    if [ ! -f "$makefile" ]; then
        echo "Warning: 未找到 $makefile，跳过 APK 版本号修正。" >&2
        return 0
    fi

    if grep -q '^PKG_VERSION:=v' "$makefile"; then
        sed -i 's/^PKG_VERSION:=v/PKG_VERSION:=/' "$makefile"
        echo "✓ APK 版本号已修正: $makefile"
    fi
}

install_openwrt_packages() {
    ./scripts/feeds install -p openwrt_packages -f \
        taskd luci-lib-xterm luci-lib-taskd \
        luci-app-store quickstart luci-app-quickstart luci-app-istorex \
        smartdns luci-app-smartdns luci-theme-argon luci-app-argon-config \
        luci-lib-docker luci-app-lucky luci-app-adguardhome \
        ghboost luci-app-ghboost \
        luci-app-oaf oaf open-app-filter \
        luci-app-dockerman luci-app-quickfile \
        luci-app-mini-diskmanager \
        luci-app-tailscale-community luci-app-zerotier
}

clone_singbox() {
    local SINGBOX_DIR="$BUILD_DIR/feeds/packages/net/sing-box"
    local TEMP_DIR="$OPENWRT_PACKAGES_DIR/sing-box-temp"

    if [ ! -d "$SINGBOX_DIR" ]; then
        echo "Warning: sing-box 目录不存在，跳过升级。" >&2
        return 0
    fi

    clone_packages "sing-box" \
        "${GITHUB_BASE}openwrt/packages.git" \
        "$TEMP_DIR" \
        "net/sing-box" \
        "" \
        "rm -rf \"$SINGBOX_DIR\" && mv \"$TEMP_DIR/net/sing-box\" \"$SINGBOX_DIR\" && rm -rf \"$TEMP_DIR\""

    local makefile="$SINGBOX_DIR/Makefile"
    if [ -f "$makefile" ]; then
        sed -i 's/^PKG_VERSION:=.*/PKG_VERSION:=1.14.2/' "$makefile"
        sed -i 's/^PKG_HASH:=.*/PKG_HASH:=67dd8f8c37ecaaadcfcafad1f0827eed4b034c963b86fd3aa5c0d7a36876845d/' "$makefile"
        echo "✓ sing-box 已升级到 1.14.2"
    else
        echo "Warning: sing-box Makefile 未找到，跳过版本更新。" >&2
    fi
}

clone_lucky() {
    local LUCKY_REPO="${GITHUB_BASE}gdy666/luci-app-lucky.git"
    local LUCKY_DIR="$OPENWRT_PACKAGES_DIR/lucky"
    local LUCI_APP_LUCKY_DIR="$OPENWRT_PACKAGES_DIR/luci-app-lucky"
    local TEMP_DIR="$OPENWRT_PACKAGES_DIR/lucky-temp"

    rm -rf "$LUCKY_DIR" "$LUCI_APP_LUCKY_DIR" "$TEMP_DIR" 2>/dev/null || true

    clone_packages "luci-app-lucky" \
        "$LUCKY_REPO" \
        "$TEMP_DIR" \
        "lucky luci-app-lucky"

    mv "$TEMP_DIR/lucky" "$LUCKY_DIR"
    mv "$TEMP_DIR/luci-app-lucky" "$LUCI_APP_LUCKY_DIR"
    rm -rf "$TEMP_DIR"
    
    local lucky_conf="$LUCKY_DIR/files/luckyuci"
    if [ -f "$lucky_conf" ]; then
        sed -i "s/option enabled '1'/option enabled '0'/g" "$lucky_conf"
        sed -i "s/option logger '1'/option logger '0'/g" "$lucky_conf"
    fi
    
    local version
    version=$(find "$BASE_PATH/patches" -name "lucky_*.tar.gz" -printf "%f\n" | head -n 1 | sed -n 's/^lucky_\(.*\)_Linux.*$/\1/p')
    if [ -z "$version" ]; then
        echo "Warning: 未找到 lucky 补丁文件，跳过更新。" >&2
        return 0
    fi
    
    local makefile_path="$LUCKY_DIR/Makefile"
    if [ ! -f "$makefile_path" ]; then
        echo "Warning: lucky Makefile not found. Skipping." >&2
        return 0
    fi
    
    local patch_line="\\t[ -f \$(TOPDIR)/../nn6000v2/patches/lucky_${version}_Linux_\$(LUCKY_ARCH)_wanji.tar.gz ] && install -Dm644 \$(TOPDIR)/../nn6000v2/patches/lucky_${version}_Linux_\$(LUCKY_ARCH)_wanji.tar.gz \$(PKG_BUILD_DIR)/\$(PKG_NAME)_\$(PKG_VERSION)_Linux_\$(LUCKY_ARCH).tar.gz"
    
    if grep -q "Build/Prepare" "$makefile_path"; then
        sed -i "/Build\\/Prepare/a\\$patch_line" "$makefile_path"
        sed -i '/wget/d' "$makefile_path"
    else
        echo "Warning: lucky Makefile 中未找到 'Build/Prepare'。跳过。" >&2
    fi
}

clone_adguardhome() {
    clone_packages "luci-app-adguardhome" \
        "${GITHUB_BASE}wzdddyy/luci-app-adguardhome.git" \
        "$OPENWRT_PACKAGES_DIR/luci-app-adguardhome"
}

clone_luci_app_smartdns() {
    clone_packages "luci-app-smartdns" \
        "${GITHUB_BASE}pymumu/luci-app-smartdns.git" \
        "$OPENWRT_PACKAGES_DIR/luci-app-smartdns"
}

clone_ghboost() {
    local GHBOOST_REPO="${GITHUB_BASE}wzdddyy/luci-app-ghboost.git"
    local GHBOOST_DIR="$OPENWRT_PACKAGES_DIR/ghboost"
    local LUCI_APP_GHBOOST_DIR="$OPENWRT_PACKAGES_DIR/luci-app-ghboost"
    local TEMP_DIR="$OPENWRT_PACKAGES_DIR/ghboost-temp"

    rm -rf "$GHBOOST_DIR" "$LUCI_APP_GHBOOST_DIR" "$TEMP_DIR" 2>/dev/null || true

    clone_packages "luci-app-ghboost" \
        "$GHBOOST_REPO" \
        "$TEMP_DIR" \
        "ghboost luci-app-ghboost"

    mv "$TEMP_DIR/ghboost" "$GHBOOST_DIR"
    mv "$TEMP_DIR/luci-app-ghboost" "$LUCI_APP_GHBOOST_DIR"
    rm -rf "$TEMP_DIR"
}

clone_dockerd_istoreos() {
    local DOCKERD_DIR="$BUILD_DIR/feeds/packages/utils/dockerd"
    local TEMP_DIR="$BUILD_DIR/feeds/packages/utils/dockerd-temp"

    rm -rf "$DOCKERD_DIR" "$TEMP_DIR" 2>/dev/null || true

    clone_packages "dockerd-istoreos" \
        "${GITHUB_BASE}jjm2473/packages.git" \
        "$TEMP_DIR" \
        "utils/dockerd" \
        "" "" "" "" \
        "istoreos-25.12"

    mv "$TEMP_DIR/utils/dockerd" "$DOCKERD_DIR"
    rm -rf "$TEMP_DIR"

    echo "✓ dockerd 已替换为 iStoreOS fork"
}

clone_zerotier() {
    clone_packages "luci-app-zerotier" \
        "${GITHUB_BASE}aimeeacker/luci-app-zerotier.git" \
        "$OPENWRT_PACKAGES_DIR/luci-app-zerotier"
}

install_extra_feed_deps() {
    (cd "$BUILD_DIR" && ./scripts/feeds install -f luci-lib-jsonc kmod-ipt-conntrack kmod-ipt-nat)
}

clone_oaf() {
    local OAF_REPO="${GITHUB_BASE}destan19/OpenAppFilter.git"
    local OAF_DIR="$OPENWRT_PACKAGES_DIR/OpenAppFilter"
    local TEMP_DIR="$OPENWRT_PACKAGES_DIR/oaf-temp"

    clone_packages "OpenAppFilter" \
        "$OAF_REPO" \
        "$TEMP_DIR" \
        "oaf open-app-filter luci-app-oaf" \
        "" \
        "mkdir -p \"$OAF_DIR\" && rm -rf \"$OAF_DIR/oaf\" \"$OAF_DIR/open-app-filter\" \"$OAF_DIR/luci-app-oaf\" && mv \"$TEMP_DIR/oaf\" \"$TEMP_DIR/open-app-filter\" \"$TEMP_DIR/luci-app-oaf\" \"$OAF_DIR/\""

    rm -rf "$TEMP_DIR"

    local oaf_makefile="$OAF_DIR/oaf/Makefile"
    if [ -f "$oaf_makefile" ] ; then
        sed -i 's/DEPENDS:=.*oaf/DEPENDS:=+kmod-ipt-conntrack +kmod-ipt-nat/g' "$oaf_makefile"
    fi

    local appfilter_config="$OAF_DIR/open-app-filter/files/etc/config/appfilter"
    if [ -f "$appfilter_config" ] ; then
        sed -i "s/option enabled '1'/option enabled '0'/g" "$appfilter_config"
    fi

    local disable_script="$OAF_DIR/luci-app-oaf/root/etc/uci-defaults/99_disable_oaf"
    mkdir -p "$(dirname "$disable_script")"
    cat > "$disable_script" << 'EOF'
#!/bin/sh
[ "$(uci get appfilter.global.enable 2>/dev/null)" = "0" ] && {
    /etc/init.d/appfilter disable
    /etc/init.d/appfilter stop
}
EOF
    chmod +x "$disable_script"
}

clone_mini_diskmanager() {
    local TEMP_DIR="$OPENWRT_PACKAGES_DIR/mini-diskmanager-temp"

    clone_packages "luci-app-mini-diskmanager" \
        "${GITHUB_BASE}4IceG/luci-app-mini-diskmanager.git" \
        "$TEMP_DIR" \
        "luci-app-mini-diskmanager" \
        "" \
        "" \
        "$TEMP_DIR/luci-app-mini-diskmanager" \
        "$OPENWRT_PACKAGES_DIR/luci-app-mini-diskmanager"

    rm -rf "$TEMP_DIR"
}

_sync_luci_lib_docker() {
    local temp_dir="$OPENWRT_PACKAGES_DIR/luci-lib-docker-temp"
    clone_packages "luci-lib-docker" \
        "${GITHUB_BASE}lisaac/luci-lib-docker.git" \
        "$temp_dir" \
        "collections/luci-lib-docker" \
        "" \
        "" \
        "$temp_dir/collections/luci-lib-docker" \
        "$OPENWRT_PACKAGES_DIR/luci-lib-docker"
    rm -rf "$temp_dir"

    fix_apk_pkg_version "$OPENWRT_PACKAGES_DIR/luci-lib-docker/Makefile"
}

clone_dockerman() {
    local path="$OPENWRT_PACKAGES_DIR/luci-app-dockerman"
    local repo_url="${GITHUB_BASE}lisaac/luci-app-dockerman.git"
    local temp_dir="$OPENWRT_PACKAGES_DIR/dockerman"

    _sync_luci_lib_docker
    
    clone_packages "luci-app-dockerman" \
        "$repo_url" \
        "$temp_dir" \
        "applications/luci-app-dockerman" \
        "" \
        "" \
        "$temp_dir/applications/luci-app-dockerman" \
        "$path"
    rm -rf "$temp_dir"

    fix_apk_pkg_version "$path/Makefile"
}

clone_quickfile() {
    local QUICKFILE_DIR="$OPENWRT_PACKAGES_DIR/luci-app-quickfile"
    local TEMP_DIR="$OPENWRT_PACKAGES_DIR/quickfile-temp"

    clone_packages "luci-app-quickfile" \
        "${GITHUB_BASE}sbwml/luci-app-quickfile.git" \
        "$TEMP_DIR" \
        "luci-app-quickfile quickfile" \
        "" \
        "mkdir -p \"$QUICKFILE_DIR\" && rm -rf \"$QUICKFILE_DIR/luci-app-quickfile\" \"$QUICKFILE_DIR/quickfile\" && mv \"$TEMP_DIR/luci-app-quickfile\" \"$TEMP_DIR/quickfile\" \"$QUICKFILE_DIR/\""

    rm -rf "$TEMP_DIR"
}

remove_attendedsysupgrade() {
    find "$BUILD_DIR/feeds/luci/collections" -name "Makefile" | while read -r makefile; do
        if grep -q "luci-app-attendedsysupgrade" "$makefile"; then
            sed -i "/luci-app-attendedsysupgrade/d" "$makefile"
            echo "Removed luci-app-attendedsysupgrade from $makefile"
        fi
    done
}

clone_luci_tailscale() {
    local TEMP_DIR="$OPENWRT_PACKAGES_DIR/luci-app-tailscale-community-temp"
    local TARGET_DIR="$OPENWRT_PACKAGES_DIR/luci-app-tailscale-community"
    
    clone_packages "luci-app-tailscale-community" \
        "${GITHUB_BASE}Tokisaki-Galaxy/luci-app-tailscale-community.git" \
        "$TEMP_DIR" \
        "" \
        "" \
        "rm -rf \"$TARGET_DIR\" 2>/dev/null || true; mv \"$TEMP_DIR/luci-app-tailscale-community\" \"$TARGET_DIR\"; rm -rf \"$TEMP_DIR\""
}