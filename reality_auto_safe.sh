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
NETOPT_SERVICE="/etc/systemd/system/net-optimize.service"

log(){ echo -e "\033[1;32m[INFO]\033[0m $*" >&2; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
err(){ echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

require_root() {
  [ "$(id -u)" -eq 0 ] || { err "请用 root 运行"; exit 1; }
}

apt_prepare() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates unzip openssl iproute2 ethtool irqbalance procps util-linux python3 jq iputils-ping
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
  [ -f "$XRAY_CFG" ] || return 1

  python3 - "$XRAY_CFG" > /tmp/reality_existing.$$ <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1],'r',encoding='utf-8'))
for inbound in cfg.get("inbounds",[]):
    if inbound.get("protocol")=="vless":
        clients=inbound.get("settings",{}).get("clients",[])
        rs=inbound.get("streamSettings",{}).get("realitySettings",{})
        sid=rs.get("shortIds",[""])
        pk=rs.get("privateKey","")
        if clients:
            print(clients[0].get("id",""))
            print(pk)
            print(sid[0] if sid else "")
            sys.exit(0)
sys.exit(1)
PY

  UUID="$(sed -n '1p' /tmp/reality_existing.$$ || true)"
  PRIVATE_KEY="$(sed -n '2p' /tmp/reality_existing.$$ || true)"
  SHORT_ID="$(sed -n '3p' /tmp/reality_existing.$$ || true)"
  rm -f /tmp/reality_existing.$$

  if [ -f "$REALITY_ENV" ]; then
    # shellcheck disable=SC1090
    source "$REALITY_ENV" || true
  fi

  if [ -n "${PUBLIC_KEY:-}" ] && [ -n "${UUID:-}" ] && [ -n "${PRIVATE_KEY:-}" ] && [ -n "${SHORT_ID:-}" ]; then
    log "检测到已成功配置，复用现有 UUID / PrivateKey / PublicKey / ShortID"
    return 0
  fi

  if [ -n "${UUID:-}" ] && [ -n "${PRIVATE_KEY:-}" ] && [ -n "${SHORT_ID:-}" ]; then
    warn "检测到现有 config，复用 UUID / PrivateKey / ShortID"
    PUBLIC_KEY="${PUBLIC_KEY:-KEEP_YOUR_OLD_PUBLIC_KEY}"
    cat > "$REALITY_ENV" <<EOF
UUID="$UUID"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
EOF
    return 0
  fi

  return 1
}

generate_reality_creds() {
  log "生成 Reality 凭据"

  UUID="$($XRAY_BIN uuid)"

  local key_output
  key_output="$($XRAY_BIN x25519)"

  PRIVATE_KEY="$(printf '%s\n' "$key_output" | sed -n 's/.*Private key: *//p' | head -n1 | tr -d '\r')"
  PUBLIC_KEY="$(printf '%s\n' "$key_output" | sed -n 's/.*Public key: *//p' | head -n1 | tr -d '\r')"

  [ -n "$PRIVATE_KEY" ] || { err "PrivateKey 生成失败"; printf '%s\n' "$key_output" >&2; exit 1; }
  [ -n "$PUBLIC_KEY" ] || { err "PublicKey 生成失败"; printf '%s\n' "$key_output" >&2; exit 1; }

  SHORT_ID="$(openssl rand -hex 8)"

  cat > "$REALITY_ENV" <<EOF
UUID="$UUID"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
EOF
}

load_or_create_reality_creds() {
  if ! read_existing_config; then
    generate_reality_creds
  fi
}

detect_best_cc() {
  local available
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if echo "$available" | grep -qw bbr2; then
    echo "bbr2"
  elif echo "$available" | grep -qw bbr; then
    echo "bbr"
  else
    echo "cubic"
  fi
}

test_mtu_one_target() {
  local target="$1"
  local sizes=(1472 1464 1452 1440 1432 1420 1412 1400 1392 1380)
  local ok_size=""
  local s

  for s in "${sizes[@]}"; do
    if ping -4 -M do -s "$s" -c 2 -W 1 "$target" >/dev/null 2>&1; then
      ok_size="$s"
      break
    fi
  done

  if [ -z "$ok_size" ]; then
    echo "1500"
  else
    echo $((ok_size + 28))
  fi
}

detect_best_mtu() {
  local best=1500
  local mtu
  local t

  for t in 1.1.1.1 8.8.8.8; do
    mtu="$(test_mtu_one_target "$t" | tail -n1 | tr -d '\r\n' || true)"
    [ -n "$mtu" ] || mtu=1500
    case "$mtu" in
      ''|*[!0-9]*) mtu=1500 ;;
    esac
    log "目标 $t 可用 MTU: $mtu"
    if [ "$mtu" -lt "$best" ]; then
      best="$mtu"
    fi
  done

  [ "$best" -gt 1500 ] && best=1500
  [ "$best" -lt 1380 ] && best=1400
  echo "$best"
}

pick_fast_dns() {
  local best1="223.5.5.5"
  local best2="119.29.29.29"
  local cands=("223.5.5.5" "119.29.29.29" "1.1.1.1" "8.8.8.8")
  local best_rtt=999999
  local second_rtt=999999
  local ip avg

  for ip in "${cands[@]}"; do
    avg="$(ping -c 3 -W 1 "$ip" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/ {print int($5)}' || true)"
    [ -n "$avg" ] || continue
    case "$avg" in
      ''|*[!0-9]*) continue ;;
    esac

    if [ "$avg" -lt "$best_rtt" ]; then
      second_rtt="$best_rtt"
      best2="$best1"
      best_rtt="$avg"
      best1="$ip"
    elif [ "$avg" -lt "$second_rtt" ] && [ "$ip" != "$best1" ]; then
      second_rtt="$avg"
      best2="$ip"
    fi
  done

  DNS1="$best1"
  DNS2="$best2"
  log "已选择 DNS: $DNS1 $DNS2"
}

write_xray_config() {
  log "写入 Xray 配置"
  mkdir -p "$(dirname "$XRAY_CFG")"

  [ -n "${UUID:-}" ] || { err "UUID 为空"; exit 1; }
  [ -n "${PRIVATE_KEY:-}" ] || { err "PRIVATE_KEY 为空"; exit 1; }
  [ -n "${PUBLIC_KEY:-}" ] || { err "PUBLIC_KEY 为空"; exit 1; }
  [ -n "${SHORT_ID:-}" ] || { err "SHORT_ID 为空"; exit 1; }

  cat > "$XRAY_CFG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "${TAG}",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true
        },
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {},
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {}
    }
  ]
}
EOF

  cat > "$REALITY_ENV" <<EOF
UUID="$UUID"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
EOF

  "$XRAY_BIN" run -test -config "$XRAY_CFG"
}

write_sysctl() {
  local cc="$1"
  log "写入 sysctl 优化，拥塞控制: $cc"

  cat > "$SYSCTL_FILE" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=${cc}

net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

net.core.netdev_max_backlog=16384
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=8192

net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.ip_local_port_range=10240 65535

net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

vm.swappiness=10

net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

  find /etc/sysctl.d -type f -name '*.conf' -exec sed -i '/promote_secondaries/d' {} \; 2>/dev/null || true
  sed -i '/promote_secondaries/d' /etc/sysctl.conf 2>/dev/null || true

  sysctl --system >/dev/null || true
}

apply_mtu_now() {
  local iface="$1"
  local mtu="$2"
  case "$mtu" in
    ''|*[!0-9]*) err "MTU 值无效: $mtu"; exit 1 ;;
  esac
  log "应用 MTU: $iface -> $mtu"
  ip link set dev "$iface" mtu "$mtu"
}

setup_dns() {
  log "设置 DNS"
  if command -v chattr >/dev/null 2>&1; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
  fi

  cat > /etc/resolv.conf <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
EOF

  if command -v chattr >/dev/null 2>&1; then
    chattr +i /etc/resolv.conf 2>/dev/null || true
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
TasksMax=infinity
Nice=-10
UNIT
}

setup_fq_service() {
  local iface="$1"
  log "设置 fq 开机自启：$iface"
  cat > "$FQ_SERVICE" <<EOF
[Unit]
Description=Apply fq qdisc on boot
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ${iface} root fq
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable fq >/dev/null 2>&1 || true
  systemctl restart fq || true
}

setup_netopt_service() {
  local iface="$1"
  local mtu="$2"
  log "设置 MTU 开机自启：$iface -> $mtu"
  cat > "$NETOPT_SERVICE" <<EOF
[Unit]
Description=Apply MTU and fq on boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set dev ${iface} mtu ${mtu}
ExecStart=/sbin/tc qdisc replace dev ${iface} root fq
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable net-optimize.service >/dev/null 2>&1 || true
  systemctl restart net-optimize.service || true
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

  CC="$(detect_best_cc)"
  BEST_MTU="$(detect_best_mtu)"
  pick_fast_dns

  load_or_create_reality_creds
  write_xray_config
  write_sysctl "$CC"
  apply_mtu_now "$IFACE" "$BEST_MTU"
  setup_dns
  setup_irqbalance
  setup_cpu_performance
  disable_unused_services
  setup_xray_dropin
  setup_fq_service "$IFACE"
  setup_netopt_service "$IFACE" "$BEST_MTU"
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
  echo "MTU: $BEST_MTU"
  echo "CC: $CC"
  echo "DNS: $DNS1 $DNS2"
  echo
  echo "---- 服务状态 ----"
  systemctl status xray --no-pager | sed -n '1,8p'
  echo
  echo "---- 监听状态 ----"
  ss -lntp | grep ":${PORT}" || true
  echo
  echo "---- qdisc ----"
  tc qdisc show dev "$IFACE" || true
  echo
  echo "---- MTU ----"
  ip link show dev "$IFACE" | head -n1
  echo
  echo "---- 核心 sysctl ----"
  sysctl \
    net.ipv4.tcp_congestion_control \
    net.core.default_qdisc \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_slow_start_after_idle \
    net.ipv4.tcp_no_metrics_save \
    net.core.rmem_max \
    net.core.wmem_max \
    vm.swappiness
  echo
  echo "---- 小火箭链接(IP版) ----"
  echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${TAG}"
  echo "======================================"
}

main "$@"
