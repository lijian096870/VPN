#!/usr/bin/env bash
set -euo pipefail

LOCK_FILE="/var/lock/reality_auto_safe.lock"

PORT=443
SNI="www.microsoft.com"
TAG="Reality"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CFG="/usr/local/etc/xray/config.json"
REALITY_ENV="/usr/local/etc/xray/reality.env"

XRAY_DROPIN_DIR="/etc/systemd/system/xray.service.d"
XRAY_DROPIN_FILE="${XRAY_DROPIN_DIR}/limit.conf"
FQ_SERVICE="/etc/systemd/system/fq.service"
NETOPT_SERVICE="/etc/systemd/system/net-optimize.service"

VERIFY_FAILED=0

log(){ echo -e "\033[1;32m[INFO]\033[0m $*" >&2; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
err(){ echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

ok_line(){ echo "[OK] $*"; }
bad_line(){ echo "[FAIL] $*"; VERIFY_FAILED=1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || { err "请用 root 运行"; exit 1; }
}

acquire_lock() {
  mkdir -p /var/lock
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    err "检测到另一个脚本实例正在运行：$LOCK_FILE"
    exit 1
  fi
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
    PUBLIC_KEY="${PUBLIC_KEY:-}"
    if [ -z "$PUBLIC_KEY" ]; then
      warn "未能从 reality.env 读取 PublicKey，将重新生成整套凭据"
      return 1
    fi
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

  local key_output line
  key_output="$($XRAY_BIN x25519)"

  PRIVATE_KEY=""
  PUBLIC_KEY=""

  while IFS= read -r line; do
    case "$line" in
      PrivateKey:*) PRIVATE_KEY="${line#PrivateKey: }" ;;
      "Private key:"*) PRIVATE_KEY="${line#Private key: }" ;;
      PublicKey:*) PUBLIC_KEY="${line#PublicKey: }" ;;
      "Public key:"*) PUBLIC_KEY="${line#Public key: }" ;;
      "Password (PublicKey):"*) PUBLIC_KEY="${line#Password (PublicKey): }" ;;
    esac
  done <<EOF
$key_output
EOF

  PRIVATE_KEY="$(printf '%s' "$PRIVATE_KEY" | tr -d '\r\n')"
  PUBLIC_KEY="$(printf '%s' "$PUBLIC_KEY" | tr -d '\r\n')"

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
    case "$mtu" in ''|*[!0-9]*) mtu=1500 ;; esac
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
    case "$avg" in ''|*[!0-9]*) continue ;; esac
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
      "sniffing": {
        "enabled": false
      },
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
          "tcpNoDelay": true,
          "tcpKeepAliveIdle": 300,
          "mark": 255
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
      "settings": {
        "domainStrategy": "UseIP"
      },
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

clean_sysctl_d_duplicates() {
  find /etc/sysctl.d -type f -name '*.conf' -exec sed -i \
    -e '/^net\.core\.default_qdisc=/d' \
    -e '/^net\.ipv4\.tcp_congestion_control=/d' \
    -e '/^net\.core\.rmem_max=/d' \
    -e '/^net\.core\.wmem_max=/d' \
    -e '/^net\.core\.rmem_default=/d' \
    -e '/^net\.core\.wmem_default=/d' \
    -e '/^net\.ipv4\.tcp_rmem=/d' \
    -e '/^net\.ipv4\.tcp_wmem=/d' \
    -e '/^net\.core\.netdev_max_backlog=/d' \
    -e '/^net\.core\.somaxconn=/d' \
    -e '/^net\.ipv4\.tcp_max_syn_backlog=/d' \
    -e '/^net\.ipv4\.tcp_fastopen=/d' \
    -e '/^net\.ipv4\.tcp_mtu_probing=/d' \
    -e '/^net\.ipv4\.tcp_slow_start_after_idle=/d' \
    -e '/^net\.ipv4\.tcp_no_metrics_save=/d' \
    -e '/^net\.ipv4\.tcp_notsent_lowat=/d' \
    -e '/^net\.ipv4\.tcp_window_scaling=/d' \
    -e '/^net\.ipv4\.tcp_timestamps=/d' \
    -e '/^net\.ipv4\.tcp_sack=/d' \
    -e '/^net\.ipv4\.ip_local_port_range=/d' \
    -e '/^net\.ipv4\.tcp_keepalive_time=/d' \
    -e '/^net\.ipv4\.tcp_keepalive_intvl=/d' \
    -e '/^net\.ipv4\.tcp_keepalive_probes=/d' \
    -e '/^vm\.swappiness=/d' \
    -e '/^net\.ipv6\.conf\.all\.disable_ipv6=/d' \
    -e '/^net\.ipv6\.conf\.default\.disable_ipv6=/d' \
    -e '/promote_secondaries/d' \
    {} \; 2>/dev/null || true
}

write_sysctl() {
  local cc="$1"
  log "重建 /etc/sysctl.conf，拥塞控制: $cc"

  cp -f /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
  clean_sysctl_d_duplicates

  cat > /etc/sysctl.conf <<EOF
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

  sed -i '/promote_secondaries/d' /etc/sysctl.conf 2>/dev/null || true
  sysctl -p >/dev/null || true
}

apply_mtu_now() {
  local iface="$1"
  local mtu="$2"
  case "$mtu" in ''|*[!0-9]*) err "MTU 值无效: $mtu"; exit 1 ;; esac
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
  local cpu_count
  cpu_count="$(nproc 2>/dev/null || echo 1)"
  if [ "$cpu_count" -le 1 ]; then
    log "单核 VPS，irqbalance 无实际收益，跳过启动"
    return 0
  fi
  log "启用 irqbalance"
  systemctl enable irqbalance.service >/dev/null 2>&1 || true
  systemctl restart irqbalance.service >/dev/null 2>&1 || true
}

setup_cpu_performance() {
  log "尝试设置 CPU performance 模式"
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$f" ] || continue
    echo performance > "$f" 2>/dev/null || true
  done
}

tune_cpu_governor() {
  log "尝试锁定 CPU performance 模式"
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$f" ] || continue
    echo performance > "$f" 2>/dev/null || true
  done
}

disable_unused_services() {
  log "关闭常见无用服务"
  for svc in bluetooth.service cups.service avahi-daemon.service snapd.service; do
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
  done
}

setup_xray_dropin() {
  log "设置 Xray 性能参数"
  mkdir -p "$XRAY_DROPIN_DIR"
  cat > "$XRAY_DROPIN_FILE" <<'UNIT'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
TasksMax=infinity
Nice=-10
CPUWeight=90
IOWeight=90
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
  systemctl enable fq.service >/dev/null 2>&1 || true
  systemctl restart fq.service || true
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
  for svc in nginx.service apache2.service httpd.service caddy.service; do
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
  systemctl enable xray.service >/dev/null 2>&1 || true
  systemctl restart xray.service
}

service_exists() {
  local svc="$1"
  systemctl cat "$svc" >/dev/null 2>&1
}

service_enabled_state() {
  local svc="$1"
  systemctl is-enabled "$svc" 2>/dev/null || true
}

service_active_state() {
  local svc="$1"
  systemctl is-active "$svc" 2>/dev/null || true
}

service_sub_state() {
  local svc="$1"
  systemctl show -p SubState --value "$svc" 2>/dev/null || true
}

validate_service() {
  local svc="$1"

  if ! service_exists "$svc"; then
    bad_line "服务不存在: $svc"
    return 1
  fi

  local enabled active sub
  enabled="$(service_enabled_state "$svc")"
  active="$(service_active_state "$svc")"
  sub="$(service_sub_state "$svc")"

  if [ "$enabled" = "enabled" ]; then
    if [ "$active" = "active" ]; then
      if [ "$sub" = "exited" ]; then
        ok_line "开机自启正常: $svc (oneshot/exited)"
      else
        ok_line "开机自启正常: $svc (active)"
      fi
    elif [ "$sub" = "exited" ]; then
      ok_line "开机自启正常: $svc (oneshot/exited)"
    else
      bad_line "服务存在且已启用，但当前未运行: $svc ($active/$sub)"
    fi
  else
    bad_line "服务存在，但未启用: $svc (${enabled:-unknown})"
  fi
}

validate_irqbalance() {
  if ! service_exists irqbalance.service; then
    bad_line "服务不存在: irqbalance.service"
    return 1
  fi

  if [ "$(nproc 2>/dev/null || echo 1)" -le 1 ]; then
    ok_line "irqbalance.service 存在；当前单核 VPS，自动退出属正常"
    return 0
  fi

  local enabled active sub
  enabled="$(service_enabled_state irqbalance.service)"
  active="$(service_active_state irqbalance.service)"
  sub="$(service_sub_state irqbalance.service)"

  if [ "$enabled" = "enabled" ]; then
    if [ "$active" = "active" ]; then
      ok_line "开机自启正常: irqbalance.service (active)"
    elif [ "$sub" = "exited" ]; then
      ok_line "开机自启正常: irqbalance.service (oneshot/exited)"
    else
      bad_line "irqbalance.service 已启用，但当前未运行: ($active/$sub)"
    fi
  else
    bad_line "irqbalance.service 存在，但未启用: (${enabled:-unknown})"
  fi
}

verify_boot_items() {
  log "验证开机自启项"
  validate_service xray.service || true
  validate_service fq.service || true
  validate_service net-optimize.service || true
  validate_irqbalance || true
}

verify_runtime() {
  log "验证运行状态与配置"

  local iface mtu_now qdisc_now cc_now fq_now dns_cfg
  iface="$(detect_iface)"
  [ -n "$iface" ] || { bad_line "网卡识别失败"; return; }

  systemctl is-active xray.service >/dev/null 2>&1 && ok_line "Xray 运行正常" || bad_line "Xray 未运行"

  if service_exists fq.service; then
    if [ "$(service_active_state fq.service)" = "active" ] || [ "$(service_sub_state fq.service)" = "exited" ]; then
      ok_line "fq 服务正常"
    else
      bad_line "fq 服务异常"
    fi
  else
    bad_line "fq 服务不存在"
  fi

  if service_exists net-optimize.service; then
    if [ "$(service_active_state net-optimize.service)" = "active" ] || [ "$(service_sub_state net-optimize.service)" = "exited" ]; then
      ok_line "net-optimize 服务正常"
    else
      bad_line "net-optimize 服务异常"
    fi
  else
    bad_line "net-optimize 服务不存在"
  fi

  if service_exists irqbalance.service; then
    if [ "$(nproc 2>/dev/null || echo 1)" -le 1 ]; then
      ok_line "irqbalance 单核自动退出属正常"
    else
      systemctl is-active irqbalance.service >/dev/null 2>&1 && ok_line "irqbalance 正常" || bad_line "irqbalance 异常"
    fi
  else
    bad_line "irqbalance 服务不存在"
  fi

  ss -lntp | grep -q ":${PORT}" && ok_line "端口监听正常: ${PORT}" || bad_line "端口未监听: ${PORT}"

  mtu_now="$(ip link show dev "$iface" | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}')"
  [ "${mtu_now:-}" = "${BEST_MTU:-}" ] && ok_line "MTU 正常: $mtu_now" || bad_line "MTU 异常: 当前=${mtu_now:-unknown} 预期=${BEST_MTU:-unknown}"

  qdisc_now="$(tc qdisc show dev "$iface" 2>/dev/null | head -n1 || true)"
  echo "$qdisc_now" | grep -q " fq " && ok_line "qdisc 正常: fq" || bad_line "qdisc 异常: ${qdisc_now:-none}"

  cc_now="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  [ "${cc_now:-}" = "${CC:-}" ] && ok_line "拥塞控制正常: $cc_now" || bad_line "拥塞控制异常: 当前=${cc_now:-unknown} 预期=${CC:-unknown}"

  fq_now="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  [ "${fq_now:-}" = "fq" ] && ok_line "default_qdisc 正常: fq" || bad_line "default_qdisc 异常: ${fq_now:-unknown}"

  dns_cfg="$(tr '\n' ' ' < /etc/resolv.conf 2>/dev/null || true)"
  if echo "$dns_cfg" | grep -q "$DNS1" && echo "$dns_cfg" | grep -q "$DNS2"; then
    ok_line "DNS 配置正常: $DNS1 $DNS2"
  else
    bad_line "DNS 配置异常"
  fi

  if [ -f "$XRAY_CFG" ] && "$XRAY_BIN" run -test -config "$XRAY_CFG" >/dev/null 2>&1; then
    ok_line "Xray 配置测试通过"
  else
    bad_line "Xray 配置测试失败"
  fi

  if [ -f "$REALITY_ENV" ]; then
    # shellcheck disable=SC1090
    source "$REALITY_ENV" || true
    if [ -n "${UUID:-}" ] && [ -n "${PRIVATE_KEY:-}" ] && [ -n "${PUBLIC_KEY:-}" ] && [ -n "${SHORT_ID:-}" ]; then
      ok_line "Reality 凭据完整"
    else
      bad_line "Reality 凭据不完整"
    fi
  else
    bad_line "reality.env 不存在"
  fi

  if python3 - <<PY >/dev/null 2>&1
import json,sys
p="${XRAY_CFG}"
expected_uuid="${UUID}"
expected_pk="${PRIVATE_KEY}"
expected_sid="${SHORT_ID}"
expected_port=${PORT}
expected_sni="${SNI}"
cfg=json.load(open(p,'r',encoding='utf-8'))
assert cfg.get("log",{}).get("loglevel")=="warning"
ib=cfg["inbounds"][0]
assert ib["tag"]=="${TAG}"
assert ib["port"]==expected_port
assert ib["protocol"]=="vless"
assert ib.get("sniffing",{}).get("enabled") is False
clients=ib["settings"]["clients"]
assert clients and clients[0]["id"]==expected_uuid
assert clients[0]["flow"]=="xtls-rprx-vision"
assert ib["settings"]["decryption"]=="none"
ss=ib["streamSettings"]
assert ss["network"]=="tcp"
assert ss["security"]=="reality"
sock=ss.get("sockopt",{})
assert sock.get("tcpFastOpen") is True
assert sock.get("tcpNoDelay") is True
assert sock.get("tcpKeepAliveIdle")==300
assert sock.get("mark")==255
rs=ss["realitySettings"]
assert rs.get("show") is False
assert rs.get("dest")==f"{expected_sni}:443"
assert rs.get("xver")==0
assert expected_sni in rs.get("serverNames",[])
assert rs.get("privateKey")==expected_pk
assert expected_sid in rs.get("shortIds",[])
ob0=cfg["outbounds"][0]
assert ob0["tag"]=="direct"
assert ob0["protocol"]=="freedom"
assert ob0["settings"]["domainStrategy"]=="UseIP"
osock=ob0.get("streamSettings",{}).get("sockopt",{})
assert osock.get("tcpFastOpen") is True
assert osock.get("tcpNoDelay") is True
ob1=cfg["outbounds"][1]
assert ob1["tag"]=="block"
assert ob1["protocol"]=="blackhole"
PY
  then
    ok_line "Xray JSON 关键配置正确"
  else
    bad_line "Xray JSON 关键配置异常"
  fi

  check_sysctl_eq() {
    local key="$1"
    local expected="$2"
    local current
    current="$(sysctl -n "$key" 2>/dev/null || true)"
    [ "$current" = "$expected" ] && ok_line "sysctl 正常: $key=$expected" || bad_line "sysctl 异常: $key 当前=${current:-unknown} 预期=$expected"
  }

  check_sysctl_eq "net.core.default_qdisc" "fq"
  check_sysctl_eq "net.ipv4.tcp_congestion_control" "$CC"
  check_sysctl_eq "net.core.rmem_max" "67108864"
  check_sysctl_eq "net.core.wmem_max" "67108864"
  check_sysctl_eq "net.core.rmem_default" "262144"
  check_sysctl_eq "net.core.wmem_default" "262144"
  check_sysctl_eq "net.ipv4.tcp_rmem" "4096	87380	67108864"
  check_sysctl_eq "net.ipv4.tcp_wmem" "4096	65536	67108864"
  check_sysctl_eq "net.core.netdev_max_backlog" "16384"
  check_sysctl_eq "net.core.somaxconn" "32768"
  check_sysctl_eq "net.ipv4.tcp_max_syn_backlog" "8192"
  check_sysctl_eq "net.ipv4.tcp_fastopen" "3"
  check_sysctl_eq "net.ipv4.tcp_mtu_probing" "1"
  check_sysctl_eq "net.ipv4.tcp_slow_start_after_idle" "0"
  check_sysctl_eq "net.ipv4.tcp_no_metrics_save" "1"
  check_sysctl_eq "net.ipv4.tcp_notsent_lowat" "16384"
  check_sysctl_eq "net.ipv4.tcp_window_scaling" "1"
  check_sysctl_eq "net.ipv4.tcp_timestamps" "1"
  check_sysctl_eq "net.ipv4.tcp_sack" "1"
  check_sysctl_eq "net.ipv4.ip_local_port_range" "10240	65535"
  check_sysctl_eq "net.ipv4.tcp_keepalive_time" "600"
  check_sysctl_eq "net.ipv4.tcp_keepalive_intvl" "30"
  check_sysctl_eq "net.ipv4.tcp_keepalive_probes" "5"
  check_sysctl_eq "vm.swappiness" "10"
  check_sysctl_eq "net.ipv6.conf.all.disable_ipv6" "1"
  check_sysctl_eq "net.ipv6.conf.default.disable_ipv6" "1"
}

print_summary() {
  echo
  echo "================ 验证总结 ================"
  [ "$VERIFY_FAILED" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
  echo "服务自启动/运行、监听、MTU、qdisc、DNS、Reality、Xray、sysctl 已完成检查"
  echo "========================================="
}

main() {
  require_root
  acquire_lock
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
  tune_cpu_governor
  disable_unused_services
  setup_xray_dropin
  setup_fq_service "$IFACE"
  setup_netopt_service "$IFACE" "$BEST_MTU"
  stop_conflicting_services
  open_firewall
  restart_xray

  verify_boot_items
  verify_runtime

  SERVER_IP="$(get_server_ip)"

  echo
  echo "================ 部署结果 ================"
  echo "IP: $SERVER_IP"
  echo "PORT: $PORT"
  echo "UUID: $UUID"
  echo "PublicKey: $PUBLIC_KEY"
  echo "ShortID: $SHORT_ID"
  echo "SNI: $SNI"
  echo "MTU: $BEST_MTU"
  echo "CC: $CC"
  echo "DNS: $DNS1 $DNS2"
  echo "LINK: vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${TAG}"
  print_summary
}

main "$@"
