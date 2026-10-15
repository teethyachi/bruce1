#!/usr/bin/env bash
# 一键部署自建代理：VLESS+Reality（主）+ Hysteria2（备）+ Cloudflare WARP 流媒体分流
# 适用系统：Debian 11/12、Ubuntu 22.04/24.04（x86_64）
#
# 用法：
#   bash install.sh            # 安装 / 重新安装（会保留已有的密钥，客户端无需重新导入）
#   bash install.sh show       # 重新显示 Shadowrocket 导入链接和二维码
#   bash install.sh status     # 查看各服务运行状态
#   bash install.sh uninstall  # 卸载
#
# 可选环境变量（安装前设置）：
#   REALITY_SNI=www.microsoft.com   Reality 伪装的网站
#   HY2_SNI=www.bing.com            Hysteria2 证书使用的域名
#   PORT=443                        监听端口（Reality 用 TCP，Hysteria2 用 UDP）
#   ENABLE_WARP=1                   设为 0 则不安装 WARP（流媒体不走 WARP）

set -euo pipefail
trap 'red "脚本在第 $LINENO 行出错退出，请把上面的输出发给我"' ERR

STATE_DIR=/etc/bruce-vpn
STATE_FILE=$STATE_DIR/state.env
CLIENT_FILE=/root/vpn-client.txt
XRAY_CONFIG=/usr/local/etc/xray/config.json
HY2_DIR=/etc/hysteria
GEO_DIR=/usr/local/share/xray
WARP_PORT=40000

REALITY_SNI=${REALITY_SNI:-www.microsoft.com}
HY2_SNI=${HY2_SNI:-www.bing.com}
PORT=${PORT:-443}
ENABLE_WARP=${ENABLE_WARP:-1}

# 走 WARP 出口的流媒体域名（geosite 分类）
STREAMING_SITES=(netflix disney hbo primevideo hulu openai)

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==> %s\033[0m\n' "$*"; }
die()   { red "错误：$*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "请用 root 运行（先执行 sudo -i）"
}

check_os() {
  [[ -f /etc/os-release ]] || die "无法识别系统"
  . /etc/os-release
  case "$ID" in
    debian|ubuntu) ;;
    *) die "只支持 Debian / Ubuntu，当前是 $ID" ;;
  esac
  [[ $(uname -m) == x86_64 ]] || die "只支持 x86_64 架构"
  OS_CODENAME=${VERSION_CODENAME:-}
}

# 很多 VPS 镜像里 grub-pc 记录的安装磁盘（如 /dev/sda）和实际磁盘（如 /dev/vda）对不上，
# 升级 grub-pc 时会报 "post-installation script subprocess returned error exit status 1"
fix_grub_device() {
  dpkg -s grub-pc >/dev/null 2>&1 || return 0
  local root_src disk
  root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
  disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1) || true
  # 根分区直接就是整块磁盘时没有 PKNAME
  [[ -n $disk ]] || { [[ $(lsblk -dno TYPE "$root_src" 2>/dev/null) == disk ]] && disk=${root_src#/dev/}; }
  [[ -n $disk ]] || disk=$(lsblk -dno NAME,TYPE | awk '$2=="disk" && $1 !~ /^(zram|loop)/ {print $1; exit}') || true
  [[ -b /dev/$disk ]] || return 0
  echo "grub-pc grub-pc/install_devices multiselect /dev/$disk" | debconf-set-selections
}

install_packages() {
  info "更新系统并安装基础软件"
  export DEBIAN_FRONTEND=noninteractive
  fix_grub_device
  dpkg --configure -a || true
  apt-get update -y
  apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y \
    || red "系统升级有部分软件包失败，继续安装（不影响代理）"
  apt-get install -y curl wget unzip jq openssl qrencode ufw fail2ban python3-systemd gnupg ca-certificates iproute2
}

enable_bbr() {
  info "开启 BBR 加速并调整网络缓冲区"
  cat > /etc/sysctl.d/99-bruce-vpn.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_fastopen = 3
EOF
  sysctl --system >/dev/null
  if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]]; then
    green "BBR 已开启"
  else
    red "BBR 未生效（内核可能太旧），不影响使用"
  fi
}

warp_on() {
  local trace
  trace=$(curl -fsS --max-time 8 -x socks5h://127.0.0.1:$WARP_PORT https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) || return 1
  [[ $trace == *warp=on* ]]
}

get_public_ip() {
  local ip=""
  for url in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]') || true
    [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] && { echo "$ip"; return; }
  done
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  [[ -n $ip ]] || die "无法获取服务器公网 IP"
  echo "$ip"
}

load_or_create_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  if [[ -f $STATE_FILE ]]; then
    info "发现已有配置，沿用原来的密钥"
    . "$STATE_FILE"
  fi
}

save_state() {
  cat > "$STATE_FILE" <<EOF
SERVER_IP=$SERVER_IP
PORT=$PORT
UUID=$UUID
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
REALITY_SNI=$REALITY_SNI
HY2_PASSWORD=$HY2_PASSWORD
HY2_SNI=$HY2_SNI
WARP_OK=$WARP_OK
EOF
  chmod 600 "$STATE_FILE"
}

install_xray() {
  info "安装 Xray"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata

  if [[ -z ${UUID:-} ]]; then
    UUID=$(xray uuid)
  fi
  if [[ -z ${PRIVATE_KEY:-} || -z ${PUBLIC_KEY:-} ]]; then
    local keys
    keys=$(xray x25519)
    # 新旧版本输出格式不同：旧版 "Private key / Public key"，新版 "PrivateKey / Password"
    PRIVATE_KEY=$(awk -F': *' 'tolower($1) ~ /^private ?key$/ {print $2}' <<<"$keys")
    PUBLIC_KEY=$(awk -F': *' 'tolower($1) ~ /^(public ?key|password)/ {print $2}' <<<"$keys")
    [[ -n $PRIVATE_KEY && -n $PUBLIC_KEY ]] || die "生成 Reality 密钥失败：$keys"
  fi
  if [[ -z ${SHORT_ID:-} ]]; then
    SHORT_ID=$(openssl rand -hex 8)
  fi
}

write_xray_config() {
  info "写入 Xray 配置"
  local warp_outbound="" warp_rule=""
  if [[ $WARP_OK == 1 ]]; then
    local domains
    domains=$(printf '"geosite:%s",' "${STREAMING_SITES[@]}")
    warp_outbound=",{\"tag\":\"warp\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"127.0.0.1\",\"port\":$WARP_PORT}]}}"
    warp_rule=",{\"type\":\"field\",\"domain\":[${domains%,}],\"outboundTag\":\"warp\"}"
  fi

  jq . > "$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$REALITY_SNI:443",
        "xver": 0,
        "serverNames": ["$REALITY_SNI"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
  }],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
    $warp_outbound
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
      $warp_rule
    ]
  }
}
EOF
  xray run -test -config "$XRAY_CONFIG" >/dev/null || die "Xray 配置校验失败"
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
}

install_hysteria() {
  info "安装 Hysteria2"
  bash <(curl -fsSL https://get.hy2.sh/)
  mkdir -p "$HY2_DIR"

  if [[ -z ${HY2_PASSWORD:-} ]]; then
    HY2_PASSWORD=$(openssl rand -hex 16)
  fi
  if [[ ! -f $HY2_DIR/server.crt ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$HY2_DIR/server.key" -out "$HY2_DIR/server.crt" \
      -subj "/CN=$HY2_SNI" -days 36500 2>/dev/null
  fi
  chown hysteria:hysteria "$HY2_DIR/server.key" "$HY2_DIR/server.crt" 2>/dev/null || true
  chmod 600 "$HY2_DIR/server.key"

  {
    cat <<EOF
listen: :$PORT

tls:
  cert: $HY2_DIR/server.crt
  key: $HY2_DIR/server.key

auth:
  type: password
  password: $HY2_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://$HY2_SNI
    rewriteHost: true
EOF
    if [[ $WARP_OK == 1 ]]; then
      cat <<EOF

outbounds:
  - name: direct
    type: direct
  - name: warp
    type: socks5
    socks5:
      addr: 127.0.0.1:$WARP_PORT

acl:
  geoip: $GEO_DIR/geoip.dat
  geosite: $GEO_DIR/geosite.dat
  inline:
    - reject(geoip:private)
EOF
      for site in "${STREAMING_SITES[@]}"; do
        echo "    - warp(geosite:$site)"
      done
      echo "    - direct(all)"
    fi
  } > "$HY2_DIR/config.yaml"

  systemctl enable hysteria-server >/dev/null 2>&1
  systemctl restart hysteria-server
}

install_warp() {
  WARP_OK=0
  [[ $ENABLE_WARP == 1 ]] || { info "跳过 WARP"; return; }
  info "安装 Cloudflare WARP（用于 Netflix 等流媒体解锁）"
  if ! command -v warp-cli >/dev/null; then
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $OS_CODENAME main" \
      > /etc/apt/sources.list.d/cloudflare-client.list
    if ! { apt-get update -y && apt-get install -y cloudflare-warp; }; then
      red "WARP 安装失败，流媒体将直接走服务器 IP（其他功能不受影响）"
      return
    fi
  fi
  systemctl enable --now warp-svc >/dev/null 2>&1 || true
  sleep 3

  local w="warp-cli --accept-tos"
  # 新版命令在前，旧版命令兜底
  $w registration show >/dev/null 2>&1 || $w registration new >/dev/null 2>&1 || $w register >/dev/null 2>&1 || true
  $w mode proxy >/dev/null 2>&1 || $w set-mode proxy >/dev/null 2>&1 || true
  $w proxy port $WARP_PORT >/dev/null 2>&1 || $w set-proxy-port $WARP_PORT >/dev/null 2>&1 || true
  $w connect >/dev/null 2>&1 || true

  for _ in $(seq 1 10); do
    if warp_on; then
      WARP_OK=1
      green "WARP 已连接"
      return
    fi
    sleep 3
  done
  red "WARP 未能连接，流媒体将直接走服务器 IP（其他功能不受影响）"
}

setup_firewall() {
  info "配置防火墙"
  local ssh_port
  # 不能在 awk 里 exit：sshd 会收到 SIGPIPE，配合 pipefail 让整个脚本静默退出
  ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{print p}') || true
  ssh_port=${ssh_port:-22}
  ufw allow "$ssh_port"/tcp >/dev/null
  ufw allow "$PORT"/tcp >/dev/null
  ufw allow "$PORT"/udp >/dev/null
  ufw --force enable >/dev/null
  green "已放行 SSH($ssh_port/tcp)、$PORT/tcp、$PORT/udp"

  # 防 SSH 暴力破解（Debian 12 没有 auth.log，所以用 systemd 日志）
  cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = $ssh_port
backend = systemd
maxretry = 5
bantime = 1h
EOF
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban || red "fail2ban 启动失败，不影响代理使用"
}

build_links() {
  VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#RackNerd-Reality"
  HY2_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${PORT}?sni=${HY2_SNI}&insecure=1#RackNerd-Hy2"
}

show_client() {
  [[ -f $STATE_FILE ]] || die "还没有安装，请先运行：bash install.sh"
  . "$STATE_FILE"
  build_links

  cat > "$CLIENT_FILE" <<EOF
====== Shadowrocket 导入信息 ======
服务器 IP : $SERVER_IP
端口      : $PORT

[主] VLESS + Reality：
$VLESS_LINK

[备] Hysteria2：
$HY2_LINK

流媒体 WARP 分流：$([[ $WARP_OK == 1 ]] && echo 已开启 || echo 未开启)
EOF
  chmod 600 "$CLIENT_FILE"

  echo
  cat "$CLIENT_FILE"
  echo
  green "—— [主] VLESS + Reality 二维码（Shadowrocket 右上角扫码）——"
  qrencode -t ANSIUTF8 "$VLESS_LINK"
  green "—— [备] Hysteria2 二维码 ——"
  qrencode -t ANSIUTF8 "$HY2_LINK"
  echo
  green "以上信息已保存到 $CLIENT_FILE，以后可运行 'bash install.sh show' 再次查看"
}

show_status() {
  for svc in xray hysteria-server warp-svc fail2ban; do
    printf '%-18s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"
  done
  echo "BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"
  if warp_on; then
    echo "WARP: 已连接"
  else
    echo "WARP: 未连接"
  fi
}

do_uninstall() {
  info "卸载中"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  bash <(curl -fsSL https://get.hy2.sh/) --remove || true
  rm -rf "$HY2_DIR"
  if command -v warp-cli >/dev/null; then
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    apt-get purge -y cloudflare-warp || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
  fi
  ufw delete allow "$PORT"/tcp >/dev/null 2>&1 || true
  ufw delete allow "$PORT"/udp >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR" "$CLIENT_FILE"
  green "已卸载（BBR、防火墙 SSH 规则和 fail2ban 保留）"
}

do_install() {
  check_os
  load_or_create_state
  install_packages
  enable_bbr
  SERVER_IP=$(get_public_ip)
  info "服务器公网 IP：$SERVER_IP"
  install_warp
  install_xray
  write_xray_config
  install_hysteria
  setup_firewall
  save_state

  sleep 2
  systemctl is-active --quiet xray || die "Xray 没有启动，请运行 journalctl -u xray -n 50 查看原因"
  systemctl is-active --quiet hysteria-server || die "Hysteria2 没有启动，请运行 journalctl -u hysteria-server -n 50 查看原因"
  green "全部安装完成！"
  show_client
}

main() {
  require_root
  case "${1:-install}" in
    install)   do_install ;;
    show)      show_client ;;
    status)    show_status ;;
    uninstall) do_uninstall ;;
    *) echo "用法：bash install.sh [install|show|status|uninstall]"; exit 1 ;;
  esac
}

main "$@"
