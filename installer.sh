#!/bin/bash
# ================================================================
#  中国云厂商 ASN 封禁管理脚本 - 交互版
#  作者：hiapb
# ================================================================
set -euo pipefail

LOGFILE="/var/log/block_cloud_asn.log"
SCRIPT_PATH="/usr/local/bin/block_cloud_asn.sh"
CRON_FILE="/etc/cron.d/block_cloud_asn"
WHITELIST_FILE="/etc/block_cloud_asn_whitelist.txt"
DEPENDENCIES=(ipset iptables jq)

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

# 国内主要云厂商 ASN
ASNS=(
  "37963" "45102" "55967"   # 阿里云
  "132203" "132591"         # 腾讯云
  "55990"                   # 华为云
  "38365"                   # 百度云
  "139620" "58879"          # 京东云
  "139242" "140633"         # 火山引擎
  "133219"                  # UCloud
  "55805"                   # 金山云
)

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOGFILE"; }

create_ipsets() {
  ipset list cloudallow &>/dev/null || ipset create cloudallow hash:net family inet
  ipset list cloudblock &>/dev/null || ipset create cloudblock hash:net family inet
  ipset flush cloudblock || true
}

load_whitelist() {
  ipset flush cloudallow 2>/dev/null || true
  if [ -f "$WHITELIST_FILE" ]; then
    grep -Ev '^\s*(#|$)' "$WHITELIST_FILE" | while read -r ip; do
      ipset add cloudallow "$ip" 2>/dev/null || true
    done
  fi
}

ensure_iptables_rules() {
  # 白名单放行优先
  if ! iptables -C INPUT -m set --match-set cloudallow src -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set cloudallow src -j ACCEPT
  fi
  if ! iptables -C FORWARD -m set --match-set cloudallow src -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD 1 -m set --match-set cloudallow src -j ACCEPT
  fi
  # 封禁规则
  if ! iptables -C INPUT -m set --match-set cloudblock src -j DROP 2>/dev/null; then
    iptables -A INPUT -m set --match-set cloudblock src -j DROP
  fi
  if ! iptables -C FORWARD -m set --match-set cloudblock src -j DROP 2>/dev/null; then
    iptables -A FORWARD -m set --match-set cloudblock src -j DROP
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
      log "⚠️ 跳过白名单网段: $net"
      continue
    fi
    ipset add cloudblock "$net" 2>/dev/null && ((added++)) || true
  done <"$TMP_V4"
  total=$(ipset -L cloudblock -o save | grep -cE '^[^#]' || true)
  log "✅ 添加 IPv4 前缀: $added"
  log "📊 当前总计封禁 IPv4: $total"
}

main() {
  create_ipsets
  load_whitelist
  : >"$TMP_V4"
  for a in "${ASNS[@]}"; do fetch_asn_prefixes "$a"; done
  apply_rules
  ensure_iptables_rules
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
  [ -f "$WHITELIST_FILE" ] || echo "# 在此添加要放行的 IP 或网段" > "$WHITELIST_FILE"
  chmod 640 "$LOGFILE"
  create_main_script
  create_cron_job
  log "🚀 立即执行首次封禁..."
  bash "$SCRIPT_PATH"
  log "✅ 安装完成！日志位置：$LOGFILE"
}

refresh_rules() {
  [ -f "$SCRIPT_PATH" ] || { echo "❌ 未检测到主脚本"; return; }
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
  echo "📊 当前已封禁 IPv4 段数：$total"
  ipset -L cloudblock | grep -E '^[0-9]' | head -n 20
}

# 白名单操作
whitelist_add() {
  read -p "输入要放行的 IP 或网段: " ip
  [[ -z "$ip" ]] && return
  echo "$ip" >> "$WHITELIST_FILE"
  echo "✅ 已添加：$ip"
}

whitelist_list() {
  echo "==== 白名单 ===="
  if [ -s "$WHITELIST_FILE" ]; then
    nl -ba "$WHITELIST_FILE"
  else
    echo "(空)"
  fi
}

whitelist_remove() {
  whitelist_list
  read -p "输入要删除的行号: " n
  sed -i "${n}d" "$WHITELIST_FILE"
  echo "✅ 已删除。"
}

uninstall_firewall() {
  log "🧹 卸载并清理..."
  iptables -D INPUT -m set --match-set cloudallow src -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -m set --match-set cloudallow src -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -m set --match-set cloudblock src -j DROP 2>/dev/null || true
  iptables -D FORWARD -m set --match-set cloudblock src -j DROP 2>/dev/null || true
  ipset destroy cloudallow 2>/dev/null || true
  ipset destroy cloudblock 2>/dev/null || true
  rm -f "$SCRIPT_PATH" "$CRON_FILE" "$LOGFILE" "$WHITELIST_FILE"
  apt-get remove -y -qq ipset iptables jq >/dev/null 2>&1 || true
  log "✅ 已卸载并清理所有内容。"
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
    4)
      echo "a) 查看白名单"
      echo "b) 添加白名单"
      echo "c) 删除白名单"
      read -p "选择操作 [a/b/c]: " op
      case "$op" in
        a) whitelist_list ;;
        b) whitelist_add ;;
        c) whitelist_remove ;;
        *) echo "❌ 无效选项" ;;
      esac
      ;;
    5) uninstall_firewall ;;
    6) echo "👋 再见！"; exit 0 ;;
    *) echo "❌ 无效选项"; sleep 1 ;;
  esac
  read -p "按回车返回菜单..." && show_menu
}

require_root
show_menu
