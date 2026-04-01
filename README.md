
---

## 1. 项目信息

- **原脚本仓库**：[https://github.com/ZqinKing/wrt_release.git](https://github.com/ZqinKing/wrt_release.git)
- **源码来源**：[https://github.com/VIKINGYFY/immortalwrt.git](https://github.com/VIKINGYFY/immortalwrt.git) - main
- **设备支持**：Link_NN6000V2

---

## 2. 固件配置

### 2.1 系统配置

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| **LAN IP** | `10.0.0.1` | (nn6000v2/patches/991_custom_settings) |
| **WiFi 名称** | `500/5` | (nn6000v2/patches/992_set-wifi-uci.sh) |
| **WiFi 密码** | `147258369` | 无线密码 |
| **WiFi 状态** | **禁用** | 首次启动需手动开启 |
| **PPPoE 账号** | **未配置** | (nn6000v2/patches/993_set_pppoe.sh) |
| **PPPoE 状态** | **自动拨号** | 首次启动自动配置 |

---

### 2.2 预装插件（22 个）

| 插件名称 | 功能说明 |
|---------|---------|
| **luci-app-argon** | Argon 主题 |
| **luci-app-istorex** | 应用商店 |
| **luci-app-dockerman** | Docker |
| **luci-app-adguardhome** | 广告过滤 |
| **luci-app-diskman** | 磁盘管理 |
| **luci-app-smartdns** | DNS 加速 |
| **luci-app-autoreboot** | 定时重启 |
| **luci-app-sqm** | QoS 智能队列 |
| **luci-app-upnp** | UPnP 端口映射 |
| **luci-app-hd-idle** | 硬盘休眠 |
| **luci-app-p910nd** | USB 打印机共享 |
| **luci-app-easytier** | EasyTier 虚拟组网 |
| **luci-app-zerotier** | ZeroTier 虚拟组网 |
| **luci-app-lucky** | 大鸡 |
| **luci-app-oaf** | 应用行为过滤 |
| **luci-app-ttyd** | 终端 |
| **luci-app-quickfile** | 文件管理 |
| **luci-app-samba4** | SMB 文件共享 |
| **luci-app-pbr** | 策略路由 |
| **luci-app-wol** | 网络唤醒 |
| **luci-app-passwall** | 科学上网 |

---

## 3. 插件来源

三方插件源自：[https://github.com/kenzok8/jell](https://github.com/kenzok8/jell)

---

## 4. 项目结构

```
Link_NN6000V2/
└── nn6000v2/              # 设备专用目录
    ├── patches/           # 设备补丁目录
    │   ├── cpuusage       # CPU使用率补丁
    │   └── tempinfo       # 温度信息补丁
    └── scripts/           # 编译脚本目录
        ├── build.sh       # 编译脚本
        └── feeds.sh       # feeds配置脚本
```

---

## 5. OAF 应用过滤使用说明

使用 OAF（应用过滤）功能前，需先完成以下操作：

**步骤 1** → 打开 **系统设置** → **启动项** → 定位到「**appfilter**」

**步骤 2** → 将「**appfilter**」从 **已禁用** 更改为 **已启用**

**步骤 3** → 点击 **启动** 按钮激活服务

⚠️ **注意**：未启用启动项将导致 OAF 功能无法正常工作

---

## ImmortalWrt

<div align="center">

![ImmortalWrt](immortalwrt.png)

</div>

---

