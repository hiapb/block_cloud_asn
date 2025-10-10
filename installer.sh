#!/bin/bash
# ================================================================
#  云厂商 ASN 封禁脚本（单文件一键版）
#  适用：Debian / Ubuntu 系列
# ================================================================

set -euo pipefail

LOGFILE="/var/log/block_cloud_asn.log"
SCRIPT_PATH="/usr/local/bin/block_cloud_asn.sh"
CRON_FILE="/etc/cron.d/block_cloud_asn"
TMPDIR="$(mktemp -d /tmp/block_asn.XXXX)"
TMP_V4="$TMPDIR/prefixes_v4.txt"
TMP_V6="$TMPDIR/prefixes_v6.txt"

ASNS=(
  "37963"   # 阿里云
  "45102"   # 阿里云
  "132203"  # 腾讯云
  "132591"  # 腾讯云
  "55990"   # 华为云
  "38365"   # 百度云
  "16509"   # AWS
  "14618"   # AWS
  "15169"   # Google Cloud
  "8075"    # Microsoft Azure
  "13335"   # Cloudflare
  "20473"   # Vultr
  "14061"   # DigitalOcean
  "24940"   # Hetzner
  "63949"   # Linode
)

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOGFILE"; }

# ========== 环境检测 ==========
require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ 请以 root 用户运行（sudo bash xxx.sh）"
    exit 1
  fi
}

install_deps() {
  log "📦 安装依赖..."
  apt update -y >/dev/null
  apt install -y ipset iptables ip6tables curl jq >/dev/null
}

# ========== 创建封禁脚本 ==========
create_block_script() {
  cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
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

require_root() {
  [ "$EUID" -eq 0 ] || { echo "请以 root 用户运行"; exit 1; }
}

create_ipsets() {
  ipset list cloudblock &>/dev/null || ipset create cloudblock hash:net family inet
  ipset list cloudblock6 &>/dev/null || ipset create cloudblock6 hash:net family inet6
}

fetch_asn_prefixes() {
  local asn="$1"
  log "🚫 获取 ASN${asn} 的 IP 段..."
  curl -s "https://api.bgpview.io/asn/${asn}/prefixes" |
    jq -r '.data.ipv4_prefixes[].prefix' >>"$TMP_V4" || true
  curl -s "https://api.bgpview.io/asn/${asn}/prefixes" |
    jq -r '.data.ipv6_prefixes[].prefix' >>"$TMP_V6" || true

  # 回退方案：使用 ipinfo
  if [ ! -s "$TMP_V4" ]; then
    curl -s "https://ipinfo.io/AS${asn}" | grep -Eo '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+)' >>"$TMP_V4" || true
  fi
  if [ ! -s "$TMP_V6" ]; then
    curl -s "https://ipinfo.io/AS${asn}" | grep -Eo '([0-9a-fA-F:]+:[0-9a-fA-F:]*\/[0-9]+)' >>"$TMP_V6" || true
  fi
}

apply_rules() {
  local added4=0 added6=0
  if [ -s "$TMP_V4" ]; then
    sort -u "$TMP_V4" -o "$TMP_V4"
    while read -r net; do
      ipset add cloudblock "$net" 2>/dev/null && ((added4++)) || true
    done <"$TMP_V4"
  fi
  if [ -s "$TMP_V6" ]; then
    sort -u "$TMP_V6" -o "$TMP_V6"
    while read -r net; do
      ipset add cloudblock6 "$net" 2>/dev/null && ((added6++)) || true
    done <"$TMP_V6"
  fi
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
  require_root
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
  log "🧱 已创建主脚本：$SCRIPT_PATH"
}

# ========== 定时任务 ==========
create_cron_job() {
  cat > "$CRON_FILE" <<EOF
0 3 * * 1 root /usr/local/bin/block_cloud_asn.sh >> /var/log/block_cloud_asn.log 2>&1
EOF
  chmod 644 "$CRON_FILE"
  log "⏰ 已创建定时任务：每周一 03:00 自动更新"
}

# ========== 主流程 ==========
main() {
  require_root
  install_deps
  touch "$LOGFILE"
  chmod 640 "$LOGFILE"
  create_block_script
  create_cron_job

  log "🚀 立即执行首次封禁..."
  bash "$SCRIPT_PATH"

  log "✅ 安装完成！日志：$LOGFILE"
  log "如需查看封禁结果：ipset list cloudblock | head"
  log "或再次执行：bash $SCRIPT_PATH"
}

main "$@"
