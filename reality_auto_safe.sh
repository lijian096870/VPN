#!/usr/bin/env bash
set -euo pipefail

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

tune_cpu_governor() {
  log "尝试锁定 CPU performance 模式"
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

verify_boot_items() {
  log "验证开机自启项"
  local failed=0
  local svc
  for svc in xray fq net-optimize.service irqbalance; do
    if systemctl list-unit-files | grep -q "^${svc}"; then
      if [ "$(systemctl is-enabled "$svc" 2>/dev/null || true)" = "enabled" ]; then
        log "自启动已启用: $svc"
      else
        warn "自启动未启用: $svc"
        failed=1
      fi
    else
      warn "服务不存在: $svc"
      failed=1
    fi
  done
  return $failed
}

verify_runtime() {
  log "验证运行状态与配置"
  local failed=0
  local iface mtu_now qdisc_now cc_now fq_now dns_cfg

  iface="$(detect_iface)"
  [ -n "$iface" ] || { err "无法识别网卡"; return 1; }

  if systemctl is-active xray >/dev/null 2>&1; then
    log "Xray 运行正常"
  else
    err "Xray 未运行"
    failed=1
  fi

  if systemctl is-active fq >/dev/null 2>&1; then
    log "fq 服务运行正常"
  else
    warn "fq 服务未处于 active"
    failed=1
  fi

  if systemctl is-active net-optimize.service >/dev/null 2>&1; then
    log "net-optimize 服务运行正常"
  else
    warn "net-optimize 服务未处于 active"
    failed=1
  fi

  if systemctl is-active irqbalance >/dev/null 2>&1; then
    log "irqbalance 运行正常"
  else
    warn "irqbalance 未运行"
    failed=1
  fi

  if ss -lntp | grep -q ":${PORT}"; then
    log "端口监听正常: ${PORT}"
  else
    err "端口未监听: ${PORT}"
    failed=1
  fi

  mtu_now="$(ip link show dev "$iface" | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}')"
  if [ "${mtu_now:-}" = "${BEST_MTU:-}" ]; then
    log "MTU 正常: $mtu_now"
  else
    warn "MTU 与预期不一致: 当前=${mtu_now:-unknown} 预期=${BEST_MTU:-unknown}"
    failed=1
  fi

  qdisc_now="$(tc qdisc show dev "$iface" 2>/dev/null | head -n1 || true)"
  if echo "$qdisc_now" | grep -q " fq "; then
    log "qdisc 正常: fq"
  else
    warn "qdisc 不是 fq: ${qdisc_now:-none}"
    failed=1
  fi

  cc_now="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [ "${cc_now:-}" = "${CC:-}" ]; then
    log "拥塞控制正常: $cc_now"
  else
    warn "拥塞控制与预期不一致: 当前=${cc_now:-unknown} 预期=${CC:-unknown}"
    failed=1
  fi

  fq_now="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  if [ "${fq_now:-}" = "fq" ]; then
    log "default_qdisc 正常: fq"
  else
    warn "default_qdisc 异常: ${fq_now:-unknown}"
    failed=1
  fi

  dns_cfg="$(tr '\n' ' ' < /etc/resolv.conf 2>/dev/null || true)"
  if echo "$dns_cfg" | grep -q "$DNS1" && echo "$dns_cfg" | grep -q "$DNS2"; then
    log "DNS 配置正常: $DNS1 $DNS2"
  else
    warn "DNS 配置与预期不一致"
    failed=1
  fi

  if [ -f "$XRAY_CFG" ]; then
    if "$XRAY_BIN" run -test -config "$XRAY_CFG" >/dev/null 2>&1; then
      log "Xray 配置测试通过"
    else
      err "Xray 配置测试失败"
      failed=1
    fi
  else
    err "未找到 Xray 配置文件"
    failed=1
  fi

  if [ -f "$REALITY_ENV" ]; then
    # shellcheck disable=SC1090
    source "$REALITY_ENV" || true
    if [ -n "${UUID:-}" ] && [ -n "${PRIVATE_KEY:-}" ] && [ -n "${PUBLIC_KEY:-}" ] && [ -n "${SHORT_ID:-}" ]; then
      log "Reality 凭据完整"
    else
      err "Reality 凭据不完整"
      failed=1
    fi
  else
    err "未找到 reality.env"
    failed=1
  fi

  python3 - <<PY || failed=1
import json,sys
p="${XRAY_CFG}"
expected_uuid="${UUID}"
expected_pk="${PRIVATE_KEY}"
expected_sid="${SHORT_ID}"
expected_port=${PORT}
expected_sni="${SNI}"
try:
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

    print("OK")
except Exception as e:
    print(f"VERIFY_FAIL: {e}")
    sys.exit(1)
PY

  local k
  for k in \
    net.core.default_qdisc \
    net.ipv4.tcp_congestion_control \
    net.core.rmem_max \
    net.core.wmem_max \
    net.core.rmem_default \
    net.core.wmem_default \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.core.netdev_max_backlog \
    net.core.somaxconn \
    net.ipv4.tcp_max_syn_backlog \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_slow_start_after_idle \
    net.ipv4.tcp_no_metrics_save \
    net.ipv4.tcp_notsent_lowat \
    net.ipv4.tcp_window_scaling \
    net.ipv4.tcp_timestamps \
    net.ipv4.tcp_sack \
    net.ipv4.ip_local_port_range \
    net.ipv4.tcp_keepalive_time \
    net.ipv4.tcp_keepalive_intvl \
    net.ipv4.tcp_keepalive_probes \
    vm.swappiness \
    net.ipv6.conf.all.disable_ipv6 \
    net.ipv6.conf.default.disable_ipv6
  do
    if sysctl "$k" >/dev/null 2>&1; then
      :
    else
      warn "sysctl 项读取失败: $k"
      failed=1
    fi
  done

  return $failed
}

print_verify_summary() {
  local iface
  iface="$(detect_iface)"
  echo
  echo "================ 验证结果 ================"
  echo "xray enabled: $(systemctl is-enabled xray 2>/dev/null || echo no)"
  echo "xray active : $(systemctl is-active xray 2>/dev/null || echo no)"
  echo "fq enabled  : $(systemctl is-enabled fq 2>/dev/null || echo no)"
  echo "fq active   : $(systemctl is-active fq 2>/dev/null || echo no)"
  echo "net-opt en  : $(systemctl is-enabled net-optimize.service 2>/dev/null || echo no)"
  echo "net-opt act : $(systemctl is-active net-optimize.service 2>/dev/null || echo no)"
  echo "irqbalance e: $(systemctl is-enabled irqbalance 2>/dev/null || echo no)"
  echo "irqbalance a: $(systemctl is-active irqbalance 2>/dev/null || echo no)"
  echo "cc          : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  echo "qdisc       : $(tc qdisc show dev "$iface" 2>/dev/null | head -n1 || echo none)"
  echo "mtu         : $(ip link show dev "$iface" | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}')"
  echo "listen      : $(ss -lntp | grep ":${PORT}" || echo none)"
  echo "dns         : $(tr '\n' ' ' < /etc/resolv.conf 2>/dev/null || echo none)"
  echo "========================================="
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
  tune_cpu_governor
  disable_unused_services
  setup_xray_dropin
  setup_fq_service "$IFACE"
  setup_netopt_service "$IFACE" "$BEST_MTU"
  stop_conflicting_services
  open_firewall
  restart_xray

  verify_boot_items || warn "部分自启动项验证失败"
  verify_runtime || warn "部分运行状态验证失败"

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
  echo "---- 重启后建议复查 ----"
  echo "systemctl is-enabled xray fq net-optimize.service irqbalance"
  echo "systemctl is-active xray fq net-optimize.service irqbalance"
  echo "tc qdisc show dev $IFACE"
  echo "ip link show dev $IFACE | head -n1"
  echo "sysctl net.ipv4.tcp_congestion_control"
  echo
  echo "---- 小火箭链接(IP版) ----"
  echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${TAG}"
  print_verify_summary
  echo "======================================"
}

main "$@"
