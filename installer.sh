#!/bin/bash
# ================================================================
#  中国云厂商 ASN 封禁脚本 - 安静版交互菜单
#  作者：hiapb（增强版 by ChatGPT）
# ================================================================
set -euo pipefail

LOGFILE="/var/log/block_cloud_asn.log"
SCRIPT_PATH="/usr/local/bin/block_cloud_asn.sh"
CRON_FILE="/etc/cron.d/block_cloud_asn"

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOGFILE"; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ 请以 root 用户运行：sudo bash installer.sh"
    exit 1
  fi
}

install_deps() {
  log "📦 安装依赖包..."
  # 屏蔽 apt 的警告信息
  LC_ALL=C apt-get update -y -qq >/dev/null 2>&1
  LC_ALL=C apt-get install -y -qq ipset iptables curl jq >/dev/null 2>&1
}

create_main_script() {
  log "🧱 写入主脚本：$SCRIPT_PATH"
  cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
LOGFILE="/var/log/block_cloud_asn.log"
TMPDIR="$(mktemp -d /tmp/block_asn.XXXX)"
TMP_V4="$TMPDIR/prefixes_v4.txt"

# 仅封禁中国国内主要云厂商 ASN
ASNS=(
  "37963"   # 阿里云
  "45102"   # 阿里云
  "132203"  # 腾讯云
  "132591"  # 腾讯云
  "55990"   # 华为云
  "38365"   # 百度云
)

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOGFILE"; }

create_ipset() {
  ipset list cloudblock &>/dev/null || ipset create cloudblock hash:net family inet
  ipset flush cloudblock || true
}

fetch_asn_prefixes() {
  local asn="$1"
  log "🚫 获取 ASN${asn} 的 IP 段..."
  curl -s "https://api.bgpview.io/asn/${asn}/prefixes" |
    jq -r '.data.ipv4_prefixes[].prefix' >>"$TMP_V4" 2>/dev/null || true
  if [ ! -s "$TMP_V4" ]; then
    curl -s "https://ipinfo.io/AS${asn}" |
      grep -Eo '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+)' >>"$TMP_V4" 2>/dev/null || true
  fi
}

apply_rules() {
  local added=0
  sort -u -o "$TMP_V4" "$TMP_V4" || true
  while read -r net; do
    [[ -z "$net" ]] && continue
    ipset add cloudblock "$net" 2>/dev/null && ((added++)) || true
  done <"$TMP_V4"
  iptables -C INPUT -m set --match-set cloudblock src -j DROP 2>/dev/null || iptables -I INPUT -m set --match-set cloudblock src -j DROP
  iptables -C FORWARD -m set --match-set cloudblock src -j DROP 2>/dev/null || iptables -I FORWARD -m set --match-set cloudblock src -j DROP
  total=$(ipset -L cloudblock -o save | grep -cE '^[^#]')
  log "✅ 本次添加 IPv4 前缀: $added"
  log "📊 当前总计封禁 IPv4: $total"
}

main() {
  create_ipset
  : >"$TMP_V4"
  for a in "${ASNS[@]}"; do fetch_asn_prefixes "$a"; done
  apply_rules
  rm -rf "$TMPDIR"
  log "✅ 国内云厂商 ASN 封禁完成"
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

install_firewall() {
  install_deps
  touch "$LOGFILE"
  chmod 640 "$LOGFILE"
  create_main_script
  create_cron_job
  log "🚀 立即执行首次封禁..."
  bash "$SCRIPT_PATH"
  log "✅ 安装完成！日志位置：$LOGFILE"
}

uninstall_firewall() {
  log "🧹 清空所有封禁规则并卸载..."
  iptables -D INPUT -m set --match-set cloudblock src -j DROP 2>/dev/null || true
  iptables -D FORWARD -m set --match-set cloudblock src -j DROP 2>/dev/null || true
  ipset destroy cloudblock 2>/dev/null || true
  rm -f "$SCRIPT_PATH" "$CRON_FILE"
  log "✅ 已清理完毕，防火墙规则与脚本已删除。"
}

show_menu() {
  clear
  echo "============================"
  echo "☁️ 中国云厂商 ASN 封禁管理"
  echo "============================"
  echo "1️⃣  安装并启用封禁规则"
  echo "2️⃣  卸载并清空所有规则"
  echo "3️⃣  查看日志"
  echo "4️⃣  退出"
  echo "============================"
  read -p "请输入选项 [1-4]: " choice
  case "$choice" in
    1) install_firewall ;;
    2) uninstall_firewall ;;
    3) less "$LOGFILE" ;;
    4) echo "再见 👋"; exit 0 ;;
    *) echo "❌ 无效选项"; sleep 1; show_menu ;;
  esac
}

require_root
show_menu
