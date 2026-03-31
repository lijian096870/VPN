#!/usr/bin/env bash
set -euo pipefail

PORT=443
SNI="www.microsoft.com"
TAG="Reality"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CFG="/usr/local/etc/xray/config.json"
REALITY_ENV="/usr/local/etc/xray/reality.env"
SYSCTL_FILE="/etc/sysctl.d/99-reality-opt.conf"
XRAY_DROPIN_DIR="/etc/systemd/system/xray.service.d"
XRAY_DROPIN_FILE="${XRAY_DROPIN_DIR}/limit.conf"
FQ_SERVICE="/etc/systemd/system/fq.service"

log(){ echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){ echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

require_root() {
  [ "$(id -u)" -eq 0 ] || { err "请用 root 运行"; exit 1; }
}

apt_prepare() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates unzip openssl iproute2 ethtool irqbalance procps util-linux python3
}

detect_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

get_server_ip() {
  local ip
  ip="$(curl -4s https://api.ipify.org || true)"
  [ -n "$ip" ] || ip="$(hostname -I | awk '{print $1}')"
  echo "$ip"
}

install_xray_if_needed() {
  if [ -x "$XRAY_BIN" ]; then
    log "Xray 已安装：$($XRAY_BIN version | head -n1)"
    return
  fi
  log "安装 Xray"
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install
  log "Xray 安装完成：$($XRAY_BIN version | head -n1)"
}

read_existing_config() {
  if [ ! -f "$XRAY_CFG" ]; then
    return 1
  fi

  python3 - <<PY
import json, sys
p = "$XRAY_CFG"
try:
    with open(p, "r", encoding="utf-8") as f:
        c = json.load(f)
    ib = c["inbounds"][0]
    uuid = ib["settings"]["clients"][0]["id"]
    flow = ib["settings"]["clients"][0].get("flow","")
    port = ib["port"]
    rs = ib["streamSettings"]["realitySettings"]
    private_key = rs["privateKey"]
    short_id = rs["shortIds"][0]
    sni = rs["serverNames"][0]
    sec = ib["streamSettings"]["security"]
    net = ib["streamSettings"]["network"]

    if sec != "reality" or net != "tcp" or port != 443 or flow != "xtls-rprx-vision":
        sys.exit(2)

    print(uuid)
    print(private_key)
    print(short_id)
    print(sni)
except Exception:
    sys.exit(1)
PY
}

gen_keys() {
  "$XRAY_BIN" x25519
}

extract_private_from_keys() {
  local keys="$1"
  echo "$keys" | sed -n \
  's/^PrivateKey:[[:space:]]*//p;
   s/^Private key:[[:space:]]*//p'
}

extract_public_from_keys() {
  local keys="$1"
  echo "$keys" | sed -n \
  's/^PublicKey:[[:space:]]*//p;
   s/^Public key:[[:space:]]*//p;
   s/^Password (PublicKey):[[:space:]]*//p;
   s/^Password:[[:space:]]*//p'
}

load_or_create_reality_creds() {
  mkdir -p /usr/local/etc/xray

  if read_existing_config >/tmp/reality_existing.$$ 2>/dev/null; then
    UUID="$(sed -n '1p' /tmp/reality_existing.$$)"
    PRIVATE_KEY="$(sed -n '2p' /tmp/reality_existing.$$)"
    SHORT_ID="$(sed -n '3p' /tmp/reality_existing.$$)"
    rm -f /tmp/reality_existing.$$

    if [ -f "$REALITY_ENV" ]; then
      # shellcheck disable=SC1090
      source "$REALITY_ENV" || true
    fi

    if [ -n "${PUBLIC_KEY:-}" ] && [ -n "${UUID:-}" ] && [ -n "${PRIVATE_KEY:-}" ] && [ -n "${SHORT_ID:-}" ]; then
      log "检测到已成功配置，复用现有 UUID / PrivateKey / PublicKey / ShortID"
      return
    fi

    warn "检测到现有 config 已成功配置，将复用 UUID / PrivateKey / ShortID。"
    warn "未找到旧 PublicKey 记录。不会重生成，避免旧链接失效。"
    PUBLIC_KEY="${PUBLIC_KEY:-KEEP_YOUR_OLD_PUBLIC_KEY}"

    cat > "$REALITY_ENV" <<ENV
UUID="${UUID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
ENV
    chmod 600 "$REALITY_ENV"
    return
  fi

  if [ -f "$REALITY_ENV" ]; then
    # shellcheck disable=SC1090
    source "$REALITY_ENV" || true
    if [ -n "${UUID:-}" ] && [ -n "${PRIVATE_KEY:-}" ] && [ -n "${PUBLIC_KEY:-}" ] && [ -n "${SHORT_ID:-}" ]; then
      log "复用 reality.env 里的凭据"
      return
    fi
  fi

  log "未检测到成功配置，生成新的 Reality 凭据"
  UUID="$($XRAY_BIN uuid)"
  KEYS="$(gen_keys)"
  PRIVATE_KEY="$(extract_private_from_keys "$KEYS")"
  PUBLIC_KEY="$(extract_public_from_keys "$KEYS")"
  SHORT_ID="$(openssl rand -hex 8)"

  [ -n "$UUID" ] || { err "UUID 生成失败"; exit 1; }
  [ -n "$PRIVATE_KEY" ] || { err "PrivateKey 生成失败"; echo "$KEYS"; exit 1; }
  [ -n "$PUBLIC_KEY" ] || { err "PublicKey 生成失败"; echo "$KEYS"; exit 1; }
  [ -n "$SHORT_ID" ] || { err "ShortID 生成失败"; exit 1; }

  cat > "$REALITY_ENV" <<ENV
UUID="${UUID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
ENV
  chmod 600 "$REALITY_ENV"
}

write_xray_config() {
  [ -f "$XRAY_CFG" ] && cp "$XRAY_CFG" "${XRAY_CFG}.bak.$(date +%s)" || true

  cat > "$XRAY_CFG" <<JSON
{
  "inbounds": [{
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "${UUID}",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${SNI}:443",
        "xver": 0,
        "serverNames": ["${SNI}"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}"]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
JSON

  "$XRAY_BIN" run -test -config "$XRAY_CFG" >/dev/null
}

write_sysctl() {
  log "写入 sysctl 优化"
  cat > "$SYSCTL_FILE" <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.core.netdev_max_backlog=250000
net.core.somaxconn=65535
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
vm.swappiness=10
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
SYSCTL

  sysctl --system >/dev/null
}

setup_dns() {
  log "设置 DNS"
  if command -v chattr >/dev/null 2>&1; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
  fi

  cat > /etc/resolv.conf <<RESOLV
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLV

  if command -v chattr >/dev/null 2>&1; then
    chattr +i /etc/resolv.conf || true
  fi
}

setup_irqbalance() {
  log "启用 irqbalance"
  systemctl enable irqbalance >/dev/null 2>&1 || true
  systemctl restart irqbalance >/dev/null 2>&1 || true
}

setup_cpu_performance() {
  log "尝试设置 CPU performance 模式"
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$f" ] || continue
    echo performance > "$f" 2>/dev/null || true
  done
}

disable_unused_services() {
  log "关闭常见无用服务"
  for svc in bluetooth cups avahi-daemon snapd; do
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
  done
}

setup_xray_dropin() {
  log "设置 Xray 句柄/优先级"
  mkdir -p "$XRAY_DROPIN_DIR"
  cat > "$XRAY_DROPIN_FILE" <<'UNIT'
[Service]
LimitNOFILE=1048576
Nice=-10
UNIT
}

setup_fq_service() {
  local iface="$1"
  log "设置 fq 开机自启：$iface"

  cat > "$FQ_SERVICE" <<UNIT
[Unit]
Description=Enable fq qdisc on ${iface}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ${iface} root fq
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable fq >/dev/null 2>&1 || true
  systemctl restart fq || true
}

stop_conflicting_services() {
  for svc in nginx apache2 httpd caddy; do
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
  done
}

open_firewall() {
  log "放行 ${PORT}/tcp"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

restart_xray() {
  log "启动 Xray"
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
}

main() {
  require_root
  apt_prepare
  install_xray_if_needed

  IFACE="$(detect_iface)"
  [ -n "$IFACE" ] || { err "无法自动识别网卡"; exit 1; }

  load_or_create_reality_creds
  write_xray_config
  write_sysctl
  setup_dns
  setup_irqbalance
  setup_cpu_performance
  disable_unused_services
  setup_xray_dropin
  setup_fq_service "$IFACE"
  stop_conflicting_services
  open_firewall
  restart_xray

  SERVER_IP="$(get_server_ip)"

  echo
  echo "================ 结果 ================"
  echo "网卡: $IFACE"
  echo "IP: $SERVER_IP"
  echo "端口: $PORT"
  echo "UUID: $UUID"
  echo "PublicKey: $PUBLIC_KEY"
  echo "ShortID: $SHORT_ID"
  echo "SNI: $SNI"
  echo "Flow: xtls-rprx-vision"
  echo
  echo "---- 服务状态 ----"
  systemctl status xray --no-pager | sed -n '1,8p'
  echo
  echo "---- 监听状态 ----"
  ss -lntp | grep ":${PORT}" || true
  echo
  echo "---- qdisc ----"
  tc qdisc show || true
  echo
  echo "---- 核心 sysctl ----"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_no_metrics_save vm.swappiness
  echo
  echo "---- 小火箭链接(IP版) ----"
  echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${TAG}"
  echo "======================================"
}

main "$@"
