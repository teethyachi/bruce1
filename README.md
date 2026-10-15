# 自建代理：RackNerd + Shadowrocket

在一台 RackNerd 美国 VPS 上，一条命令部署：

| 组件 | 作用 |
|---|---|
| **VLESS + Reality**（Xray，443/TCP） | 主力线路，伪装成访问正常 HTTPS 网站，抗封锁能力最强 |
| **Hysteria2**（443/UDP） | 备用线路，晚高峰丢包严重时通常更快 |
| **Cloudflare WARP 分流** | Netflix / Disney+ / HBO / Prime Video / Hulu / OpenAI 走 WARP 出口，提高解锁率 |
| **BBR + 防火墙 + fail2ban** | 加速、只开放必要端口、防 SSH 暴力破解 |

---

## 第 1 步：购买 VPS

### 购买链接（RackNerd 官网）

- 促销活动页（最便宜的年付套餐都在这里）：<https://www.racknerd.com/11-11>
  - 每年 11 月还有黑五活动，通常是 <https://www.racknerd.com/BlackFriday>
- 常规 KVM VPS 列表：<https://www.racknerd.com/kvm-vps>

> 促销页的地址和价格每次活动都会变。如果链接打不开，从官网首页 <https://www.racknerd.com> 找 "Specials / Promotions"。

### 选什么

| 项目 | 选择 |
|---|---|
| 套餐 | **1GB KVM** 年付（促销价约 $11/年，平时约 $22/年） |
| 机房 | **Los Angeles**（离中国最近，对亚洲线路有优化） |
| 系统 | **Debian 12 64-bit** |
| 流量 | 每月 1–2TB 足够（4K 每小时约 7GB） |

**买之前**：在 RackNerd 官网的 Looking Glass（网络测试）页面找到洛杉矶机房的测试 IP，在家里 Wi-Fi 下 ping 一下。延迟 150–200ms、没有明显丢包就可以买。

付款后几分钟内会收到邮件，里面有 **服务器 IP** 和 **root 密码**。

---

## 第 2 步：登录服务器

- **电脑（Mac / Windows 10+）**：打开「终端」或 PowerShell：
  ```bash
  ssh root@你的服务器IP
  ```
  第一次登录输入 `yes`，然后输入邮件里的 root 密码（输入时不显示字符，正常）。
- **iPhone**：可以用 Termius 等 SSH App。

---

## 第 3 步：一键部署

登录后复制粘贴下面这一行：

```bash
curl -fsSL https://raw.githubusercontent.com/teethyachi/bruce1/claude/admiring-clarke-m5veti/install.sh -o install.sh && bash install.sh
```

> 如果仓库是私有的，上面的链接下载不了。那就在电脑上打开本仓库的 `install.sh`，复制全部内容，在服务器上执行 `nano install.sh`，粘贴后按 `Ctrl+O` 回车保存、`Ctrl+X` 退出，再运行 `bash install.sh`。

整个过程约 3–5 分钟。完成后终端会显示：

- 两条导入链接（`vless://...` 和 `hysteria2://...`）
- 两个二维码

这些信息同时保存在服务器的 `/root/vpn-client.txt`。

### 常用命令

```bash
bash install.sh show       # 重新显示导入链接和二维码
bash install.sh status     # 查看服务状态（Xray / Hysteria2 / WARP）
bash install.sh            # 重新安装（会保留原来的密钥，手机不用重新导入）
bash install.sh uninstall  # 卸载
```

### 可选参数

```bash
REALITY_SNI=www.apple.com bash install.sh   # 换 Reality 伪装网站
ENABLE_WARP=0 bash install.sh                # 不装 WARP
```

---

## 第 4 步：Shadowrocket 设置

1. 打开 Shadowrocket，点右上角 **扫码图标**，扫描终端里的二维码。两个都扫，会出现 `RackNerd-Reality` 和 `RackNerd-Hy2` 两个节点。
   - 也可以复制 `vless://` 链接，打开 Shadowrocket 时会自动提示导入。
2. 首页选中 **RackNerd-Reality**，打开顶部开关。
3. 首页 **全局路由** 选 **配置**（不要选「代理」）。默认配置里国内网站直连、国外网站走代理，国内 App 不会变慢。
4. 测试：打开 YouTube、Google；Netflix 可以打开 <https://fast.com> 测速。

### 什么时候切到 Hysteria2

- 晚高峰 Reality 很卡、视频一直缓冲 → 切到 **RackNerd-Hy2** 试试。
- 有些运营商会限制 UDP，如果 Hy2 反而连不上，就用回 Reality。

---

## 常见问题

**连不上？**
1. 在服务器上运行 `bash install.sh status`，确认 `xray` 和 `hysteria-server` 都是 `active`。
2. 在家里 ping 服务器 IP。如果 ping 不通，但服务器在 RackNerd 后台显示正常，可能 IP 被墙了，需要找 RackNerd 换 IP（可能收费）。换 IP 后重新运行 `bash install.sh`，再在 Shadowrocket 里把节点地址改成新 IP（或者重新扫码）。

**Netflix 显示代理错误 / 只能看自制剧？**
- 运行 `bash install.sh status`，看 WARP 是否「已连接」。
- 没连上的话重新运行 `bash install.sh`。WARP 是免费服务，不能保证 100% 解锁。

**怎么看每月用了多少流量？**
- 登录 RackNerd 客户后台（SolusVM 控制面板），里面有流量统计。

**安全建议**
- 部署后尽快修改 root 密码：`passwd`
- 不要把导入链接或二维码发给别人。链接等于密码，泄露后重新安装前先删除 `/etc/bruce-vpn` 目录，就会生成新密钥。

---

## 文件说明

| 文件 | 说明 |
|---|---|
| `install.sh` | 一键部署脚本 |
| 服务器 `/root/vpn-client.txt` | 导入链接（部署后生成） |
| 服务器 `/etc/bruce-vpn/state.env` | 密钥等状态，重新安装时沿用 |
| 服务器 `/usr/local/etc/xray/config.json` | Xray 配置 |
| 服务器 `/etc/hysteria/config.yaml` | Hysteria2 配置 |

请在当地法律和 VPS 服务条款允许的范围内使用。
