#!/bin/bash
# ================================================================
#  中国云厂商 ASN 封禁管理脚本 - 交互版（含白名单功能）
#  作者：hiapb
# ================================================================
set -euo pipefail

LOGFILE="/var/log/block_cloud_asn.log"
SCRIPT_PATH="/usr/local/bin/block_cloud_asn.sh"
CRON_FILE="/etc/cron.d/block_cloud_asn"
WHITELIST_FILE="/etc/block_cloud_asn_whitelist.txt"
DEPENDENCIES=(ipset iptables jq curl)

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
  LC_ALL=C apt-get update -y -qq >/dev/null 2>&1
  LC_ALL=C apt-get install -y -qq "${DEPENDENCIES[@]}" >/dev/null 2>&1
}

create_main_script() {
  log "🧱 写入主脚本：$SCRIPT_PATH"
  cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
LOGFILE="/var/log/block_cloud_asn.log"
TMPDIR="$(mktemp -d /tmp/block_asn.XXXX)"
TMP_V4="$TMPDIR/prefixes_v4.txt"
WHITELIST_FILE="/etc/block_cloud_asn_whitelist.txt"

ASNS=(
  "37963" "45102" "55967"
  "132203" "132591"
  "55990"
  "38365"
  "139620" "58879"
  "139242" "140633"
  "133219"
  "55805"
)

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOGFILE"; }

create_ipset() {
  ipset list cloudblock &>/dev/null || ipset create cloudblock hash:net family inet
  ipset list cloudallow &>/dev/null || ipset create cloudallow hash:net family inet
  ipset flush cloudblock || true
}

load_whitelist() {
  if [ -f "$WHITELIST_FILE" ]; then
    log "📄 加载白名单..."
    ipset flush cloudallow 2>/dev/null || true
    grep -Ev '^\s*(#|$)' "$WHITELIST_FILE" | while read -r ip; do
      ipset add cloudallow "$ip" 2>/dev/null || true
    done
  fi
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
    if ipset test cloudallow "$net" &>/dev/null; then
      log "⚪ 跳过白名单网段: $net"
      continue
    fi
    ipset add cloudblock "$net" 2>/dev/null && ((added++)) || true
  done <"$TMP_V4"

  iptables -C INPUT -m set --match-set cloudallow src -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -m set --match-set cloudallow src -j ACCEPT
  iptables -C INPUT -m set --match-set cloudblock src -j DROP 2>/dev/null || iptables -A INPUT -m set --match-set cloudblock src -j DROP
  iptables -C FORWARD -m set --match-set cloudblock src -j DROP 2>/dev/null || iptables -A FORWARD -m set --match-set cloudblock src -j DROP

  total=$(ipset -L cloudblock -o save | grep -cE '^[^#]')
  log "✅ 本次添加 IPv4 前缀: $added"
  log "📊 当前总计封禁 IPv4: $total"
}

main() {
  create_ipset
  load_whitelist
  : >"$TMP_V4"
  for a in "${ASNS[@]}"; do fetch_asn_prefixes "$a"; done
  apply_rules
  rm -rf "$TMPDIR"
  log "✅ 国内云厂商 ASN 封禁完成（白名单已生效）"
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
  [ -f "$WHITELIST_FILE" ] || echo "# 在此文件中添加需要放行的 IP 或网段，每行一个" > "$WHITELIST_FILE"
  chmod 640 "$LOGFILE"
  create_main_script
  create_cron_job
  log "🚀 立即执行首次封禁..."
  bash "$SCRIPT_PATH"
  log "✅ 安装完成！日志位置：$LOGFILE"
}

refresh_rules() {
  if [ ! -f "$SCRIPT_PATH" ]; then
    echo "❌ 未检测到主脚本，请先执行安装。"
    return
  fi
  log "🔁 手动刷新 ASN 数据..."
  bash "$SCRIPT_PATH"
  log "✅ 刷新完成。"
}

show_blocked_info() {
  if ! ipset list cloudblock &>/dev/null; then
    echo "❌ 当前未创建封禁规则。"
    return
  fi
  total=$(ipset -L cloudblock | grep -cE '^[0-9]')
  echo "📊 当前已封禁的 IPv4 段数：$total"
  echo "🔍 示例（前 20 条）："
  ipset list cloudblock | grep -E '^[0-9]' | head -n 20
}

manage_whitelist() {
  echo "============================"
  echo "📄 白名单管理"
  echo "============================"
  echo "当前白名单内容："
  echo "--------------------------------"
  if [ -f "$WHITELIST_FILE" ]; then
    grep -Ev '^\s*$' "$WHITELIST_FILE" || echo "(空)"
  else
    echo "(未创建)"
  fi
  echo "--------------------------------"
  echo "1️⃣  添加 IP/CIDR"
  echo "2️⃣  删除 IP/CIDR"
  echo "3️⃣  返回菜单"
  read -p "请选择 [1-3]: " wchoice
  case "$wchoice" in
    1)
      read -p "输入要添加的 IP 或网段: " ip
      echo "$ip" >> "$WHITELIST_FILE"
      echo "✅ 已添加 $ip 到白名单。"
      ;;
    2)
      read -p "输入要删除的 IP 或网段: " ip
      sed -i "\|^$ip\$|d" "$WHITELIST_FILE"
      echo "✅ 已删除 $ip。"
      ;;
    3) return ;;
    *) echo "❌ 无效选项";;
  esac
}

uninstall_firewall() {
  log "🧹 卸载并清理所有内容..."
  iptables -D INPUT -m set --match-set cloudblock src -j DROP 2>/dev/null || true
  iptables -D FORWARD -m set --match-set cloudblock src -j DROP 2>/dev/null || true
  iptables -D INPUT -m set --match-set cloudallow src -j ACCEPT 2>/dev/null || true
  ipset destroy cloudblock 2>/dev/null || true
  ipset destroy cloudallow 2>/dev/null || true
  rm -f "$SCRIPT_PATH" "$CRON_FILE" "$LOGFILE"
  apt-get remove -y -qq ipset iptables jq curl >/dev/null 2>&1 || true
  log "✅ 已卸载并清理所有相关文件与依赖。"
}

show_menu() {
  clear
  echo "============================"
  echo "☁️ 中国云厂商 ASN 封禁管理（含白名单）"
  echo "============================"
  echo "1️⃣  安装并启用封禁规则"
  echo "2️⃣  手动刷新 ASN 数据"
  echo "3️⃣  查看当前封禁统计"
  echo "4️⃣  白名单管理"
  echo "5️⃣  卸载并清理所有内容"
  echo "6️⃣  退出"
  echo "============================"
  read -p "请输入选项 [1-6]: " choice
  case "$choice" in
    1) install_firewall ;;
    2) refresh_rules ;;
    3) show_blocked_info ;;
    4) manage_whitelist ;;
    5) uninstall_firewall ;;
    6) echo "👋 再见！"; exit 0 ;;
    *) echo "❌ 无效选项"; sleep 1; show_menu ;;
  esac
}

require_root
show_menu
