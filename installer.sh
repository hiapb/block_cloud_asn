#!/bin/bash
# ================================================================
#  中国云厂商 ASN 封禁管理脚本
#  作者：hiapb
# ================================================================
set -euo pipefail

LOGFILE="/var/log/block_cloud_asn.log"
SCRIPT_PATH="/usr/local/bin/block_cloud_asn.sh"
CRON_FILE="/etc/cron.d/block_cloud_asn"
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
  apt-get update -y -qq >/dev/null 2>&1
  apt-get install -y -qq "${DEPENDENCIES[@]}" >/dev/null 2>&1
}

create_main_script() {
  log "🧱 写入主脚本：$SCRIPT_PATH"
  cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
LOGFILE="/var/log/block_cloud_asn.log"
TMPDIR="$(mktemp -d /tmp/block_asn.XXXX)"
TMP_V4="$TMPDIR/prefixes_v4.txt"

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

create_ipset() {
  ipset list cloudblock &>/dev/null || ipset create cloudblock hash:net family inet
  ipset list cloudwhitelist &>/dev/null || ipset create cloudwhitelist hash:net family inet
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

  # 白名单优先放行
  iptables -C INPUT -m set --match-set cloudwhitelist src -j ACCEPT 2>/dev/null || iptables -I INPUT -m set --match-set cloudwhitelist src -j ACCEPT
  iptables -C FORWARD -m set --match-set cloudwhitelist src -j ACCEPT 2>/dev/null || iptables -I FORWARD -m set --match-set cloudwhitelist src -j ACCEPT

  # 云厂商封禁
  iptables -C INPUT -m set --match-set cloudblock src -j DROP 2>/dev/null || iptables -A INPUT -m set --match-set cloudblock src -j DROP
  iptables -C FORWARD -m set --match-set cloudblock src -j DROP 2>/dev/null || iptables -A FORWARD -m set --match-set cloudblock src -j DROP

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
  sleep 2
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
    read -p "按回车键返回菜单..." 
    return
  fi

  total=$(ipset -L cloudblock | grep -cE '^[0-9]')
  echo "📊 当前已封禁 IPv4 段数：$total"
  echo "==============================="

  # 如果条目很多，就分页显示
  if [ "$total" -gt 2000 ]; then
    echo "⚠️  封禁条目过多（$total 条），自动分页显示（可按空格翻页，q 退出）..."
    ipset list cloudblock | grep -E '^[0-9]' | less
  else
    ipset list cloudblock | grep -E '^[0-9]' || echo "(无封禁条目)"
  fi

  echo "==============================="
  read -p "按回车键返回菜单..."
}

# ==============================
# 🧩 白名单管理功能
# ==============================
whitelist_menu() {
  while true; do
    clear
    echo "============================"
    echo "🟢 白名单管理"
    echo "============================"
    echo "1️⃣ 查看白名单"
    echo "2️⃣ 添加 IP/IP 段"
    echo "3️⃣ 删除 IP/IP 段"
    echo "4️⃣ 返回上级菜单"
    echo "============================"
    read -p "请选择 [1-4]: " wopt
    case "$wopt" in
      1)
        if ! ipset list cloudwhitelist &>/dev/null; then
          echo "❌ 白名单尚未创建。"
        else
          echo "📋 当前白名单列表："
          ipset list cloudwhitelist | grep -E '^[0-9]' || echo "(空)"
        fi
        read -p "按回车键继续..."
        ;;
      2)
        read -p "请输入要添加的 IP 或网段: " ip
        ipset -! add cloudwhitelist "$ip" && echo "✅ 已添加到白名单。" || echo "⚠️ 添加失败。"
        ;;
      3)
        read -p "请输入要删除的 IP 或网段: " ip
        ipset -! del cloudwhitelist "$ip" && echo "🗑️ 已删除。" || echo "⚠️ 删除失败。"
        ;;
      4)
        break
        ;;
      *)
        echo "❌ 无效选项"; sleep 1;;
    esac
  done
}

uninstall_firewall() {
  log "🧹 卸载并清理所有内容..."
  iptables -D INPUT -m set --match-set cloudwhitelist src -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -m set --match-set cloudwhitelist src -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -m set --match-set cloudblock src -j DROP 2>/dev/null || true
  iptables -D FORWARD -m set --match-set cloudblock src -j DROP 2>/dev/null || true
  ipset destroy cloudwhitelist 2>/dev/null || true
  ipset destroy cloudblock 2>/dev/null || true
  rm -f "$SCRIPT_PATH" "$CRON_FILE" "$LOGFILE"
  apt-get remove -y -qq ipset iptables jq >/dev/null 2>&1 || true
  log "✅ 已卸载并清理所有相关文件与依赖。"
  echo "👋 已完成卸载并退出。"
  sleep 2
  exit 0
}

show_menu() {
  while true; do
    clear
    echo "============================"
    echo "☁️ 中国云厂商 ASN 封禁管理"
    echo "============================"
    echo "1️⃣ 安装并启用封禁规则"
    echo "2️⃣ 手动刷新 ASN 数据"
    echo "3️⃣ 查看当前封禁统计"
    echo "4️⃣ 白名单管理"
    echo "5️⃣ 卸载并清理"
    echo "6️⃣ 退出"
    echo "============================"
    read -p "请输入选项 [1-6]: " choice
    case "$choice" in
      1) install_firewall ;;
      2) refresh_rules ;;
      3) show_blocked_info ;;
      4) whitelist_menu ;;
      5) uninstall_firewall ;;
      6) echo "👋 再见！"; exit 0 ;;
      *) echo "❌ 无效选项"; sleep 1 ;;
    esac
  done
}

require_root
show_menu
