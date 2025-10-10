#!/bin/bash
# ================================================================
#  云厂商 ASN 自动封禁脚本 - 一键安装器（可重复执行）
#  作者：hiapb（增强版）
#  适用系统：Debian / Ubuntu
# ================================================================

set -euo pipefail

LOGFILE="/var/log/block_cloud_asn.log"
SCRIPT_PATH="/usr/local/bin/block_cloud_asn.sh"
CRON_FILE="/etc/cron.d/block_cloud_asn"

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOGFILE"; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ 请以 root 用户运行（sudo bash installer.sh）"
    exit 1
  fi
}

install_deps() {
  log "📦 安装依赖..."
  apt update -y >/dev/null
  apt install -y ipset iptables curl jq >/dev/null
}

create_main_script() {
  log "🧱 写入主脚本：$SCRIPT_PATH"
  cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
# ================================================================
#  云厂商 ASN 自动封禁脚本
# ================================================================
set -euo pipefail
LOGFILE="/var/log/block_cloud_asn.log"
TMPDIR="$(mktemp -d /tmp/block_asn.XXXX)"
TMP_V4="$TMPDIR/prefixes_v4.txt"
TMP_V6="$TMPDIR/prefixes_v6.txt"

ASNS=(
  "37963" "45102" "132203" "132591"
  "55990" "38365" "16509" "14618"
  "15169" "8075" "13335" "20473"
  "14061" "24940" "63949"
)

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOGFILE"; }

create_ipsets() {
  ipset list cloudblock &>/dev/null || ipset create cloudblock hash:net family inet
  ipset list cloudblock6 &>/dev/null || ipset create cloudblock6 hash:net family inet6
  ipset flush cloudblock || true
  ipset flush cloudblock6 || true
}

fetch_asn_prefixes() {
  local asn="$1"
  log "🚫 获取 ASN${asn} 的 IP 段..."
  curl -s "https://api.bgpview.io/asn/${asn}/prefixes" |
    jq -r '.data.ipv4_prefixes[].prefix' >>"$TMP_V4" || true
  curl -s "https://api.bgpview.io/asn/${asn}/prefixes" |
    jq -r '.data.ipv6_prefixes[].prefix' >>"$TMP_V6" || true
  # 备用来源：ipinfo
  if [ ! -s "$TMP_V4" ]; then
    curl -s "https://ipinfo.io/AS${asn}" |
      grep -Eo '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+)' >>"$TMP_V4" || true
  fi
  if [ ! -s "$TMP_V6" ]; then
    curl -s "https://ipinfo.io/AS${asn}" |
      grep -Eo '([0-9a-fA-F:]+:[0-9a-fA-F:]*\/[0-9]+)' >>"$TMP_V6" || true
  fi
}

apply_rules() {
  local added4=0 added6=0
  sort -u -o "$TMP_V4" "$TMP_V4" || true
  sort -u -o "$TMP_V6" "$TMP_V6" || true

  while read -r net; do
    [[ -z "$net" ]] && continue
    ipset add cloudblock "$net" 2>/dev/null && ((added4++)) || true
  done <"$TMP_V4"

  while read -r net; do
    [[ -z "$net" ]] && continue
    ipset add cloudblock6 "$net" 2>/dev/null && ((added6++)) || true
  done <"$TMP_V6"

  iptables -C INPUT -m set --match-set cloudblock src -j DROP 2>/dev/null || iptables -I INPUT -m set --match-set cloudblock src -j DROP
  iptables -C FORWARD -m set --match-set cloudblock src -j DROP 2>/dev/null || iptables -I FORWARD -m set --match-set cloudblock src -j DROP
  ip6tables -C INPUT -m set --match-set cloudblock6 src -j DROP 2>/dev/null || ip6tables -I INPUT -m set --match-set cloudblock6 src -j DROP
  ip6tables -C FORWARD -m set --match-set cloudblock6 src -j DROP 2>/dev/null || ip6tables -I FORWARD -m set --match-set cloudblock6 src -j DROP

  total4=$(ipset -L cloudblock -o save | grep -cE '^[^#]')
  total6=$(ipset -L cloudblock6 -o save | grep -cE '^[^#]')
  log "✅ 本次添加 IPv4 前缀: $added4，IPv6 前缀: $added6"
  log "📊 当前总计封禁 IPv4: $total4，IPv6: $total6"
}

main() {
  create_ipsets
  : >"$TMP_V4"
  : >"$TMP_V6"
  for a in "${ASNS[@]}"; do fetch_asn_prefixes "$a"; done
  apply_rules
  rm -rf "$TMPDIR"
  log "✅ 云厂商 ASN 封禁完成"
}

main "$@"
EOF

  chmod +x "$SCRIPT_PATH"
}

create_cron_job() {
  log "⏰ 设置定时任务：每周一凌晨 3 点自动更新"
  cat > "$CRON_FILE" <<EOF
0 3 * * 1 root /usr/local/bin/block_cloud_asn.sh >> /var/log/block_cloud_asn.log 2>&1
EOF
  chmod 644 "$CRON_FILE"
}

main() {
  require_root
  install_deps
  touch "$LOGFILE"
  chmod 640 "$LOGFILE"
  create_main_script
  create_cron_job
  log "🚀 立即执行首次封禁..."
  bash "$SCRIPT_PATH"
  log "✅ 安装完成！日志位置：$LOGFILE"
}

main "$@"
