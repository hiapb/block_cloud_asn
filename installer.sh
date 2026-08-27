#!/bin/bash
# ================================================================
#  云厂商 ASN 封禁管理脚本
#  作者：hiapb
# ================================================================
set -euo pipefail

LOGFILE="/var/log/block_cloud_asn.log"
SCRIPT_PATH="/usr/local/bin/block_cloud_asn.sh"
CRON_FILE="/etc/cron.d/block_cloud_asn"
DEPENDENCIES=(ipset iptables jq curl)

# ==============================
# 云厂商 ASN 数据定义
# ==============================
CLOUD_NAMES=(
  "阿里云" "腾讯云" "华为云" "百度云" "字节跳动/火山引擎" "UCloud(优刻得)" "金山云"
  "Amazon_AWS" "Microsoft_Azure" "Google_Cloud" "Oracle_Cloud" "IBM_Cloud" 
  "DigitalOcean" "Vultr" "Linode" "OVHcloud" "Hetzner" "IONOS" "Scaleway" 
  "Cloudflare" "Rackspace" "UpCloud"
)

declare -A CLOUD_ASNS

# ---------- 国内云厂商 ----------
CLOUD_ASNS["阿里云"]="\"37963\" \"45102\" \"45103\" \"45104\" \"59028\" \"59051\" \"59052\" \"59053\" \"59054\" \"59055\" \"203513\" \"134963\" \"24429\" \"402205\" \"402206\" \"402207\" \"34947\""
CLOUD_ASNS["腾讯云"]="\"9390\" \"45090\" \"132203\" \"132591\" \"133478\" \"137876\" \"58835\""
CLOUD_ASNS["华为云"]="\"55990\" \"136907\" \"149640\" \"63727\" \"139144\" \"131444\" \"141180\" \"149167\""
CLOUD_ASNS["百度云"]="\"38365\" \"55967\" \"45076\" \"45085\" \"63728\" \"63729\" \"131138\" \"131139\" \"131140\" \"131141\" \"38627\" \"63288\" \"133746\" \"199506\""
CLOUD_ASNS["字节跳动/火山引擎"]="\"137718\" \"137775\" \"396986\" \"138699\""
CLOUD_ASNS["UCloud(优刻得)"]="\"59077\" \"135377\" \"139327\""
CLOUD_ASNS["金山云"]="\"59019\" \"137280\""

# ---------- 国外主流云厂商 ----------
CLOUD_ASNS["Amazon_AWS"]="\"16509\" \"14618\" \"8987\" \"7224\" \"38895\" \"19047\" \"62785\""
CLOUD_ASNS["Microsoft_Azure"]="\"8075\" \"8068\" \"8069\" \"8070\" \"3598\""
CLOUD_ASNS["Google_Cloud"]="\"15169\" \"396982\" \"19527\" \"36040\" \"43515\" \"139070\" \"394089\""
CLOUD_ASNS["Oracle_Cloud"]="\"31898\""
CLOUD_ASNS["IBM_Cloud"]="\"36351\" \"64999\""
CLOUD_ASNS["DigitalOcean"]="\"14061\""
CLOUD_ASNS["Vultr"]="\"20473\""
CLOUD_ASNS["Linode"]="\"63949\""
CLOUD_ASNS["OVHcloud"]="\"16276\""
CLOUD_ASNS["Hetzner"]="\"24940\" \"213230\" \"212317\""
CLOUD_ASNS["IONOS"]="\"8560\""
CLOUD_ASNS["Scaleway"]="\"12876\""
CLOUD_ASNS["Cloudflare"]="\"13335\" \"209242\" \"14789\""
CLOUD_ASNS["Rackspace"]="\"27357\""
CLOUD_ASNS["UpCloud"]="\"25697\""

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOGFILE"; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ 请以 root 用户运行：sudo bash $0"
    exit 1
  fi
}

install_deps() {
  log "📦 安装依赖包..."
  apt-get update -y -qq >/dev/null 2>&1
  apt-get install -y -qq "${DEPENDENCIES[@]}" >/dev/null 2>&1
}

create_main_script() {
  local selected_asns="$1"
  log "🧱 写入主脚本：$SCRIPT_PATH"
  
  # 写入第一部分：动态变量解析
  cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
set -euo pipefail
LOGFILE="/var/log/block_cloud_asn.log"
TMPDIR="\$(mktemp -d /tmp/block_asn.XXXX)"
TMP_V4="\$TMPDIR/prefixes_v4.txt"

ASNS=(
$selected_asns
)
EOF

  # 写入第二部分：核心逻辑代码（不解析变量）
  cat >> "$SCRIPT_PATH" <<'EOF'

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

  local ok=0

  # ---------- Source A: RIPEstat (recommended) ----------
  local ripe_url="https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${asn}"
  local code
  code=$(curl -sS -m 15 -o "$TMPDIR/ripe_${asn}.json" -w "%{http_code}" "$ripe_url" || echo "curl_fail")
  if [[ "$code" == "200" ]] && [[ -s "$TMPDIR/ripe_${asn}.json" ]]; then
    jq -r '.data.prefixes[].prefix' "$TMPDIR/ripe_${asn}.json" \
      | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' >>"$TMP_V4" || true
    ok=1
  else
    log "⚠️ RIPEstat 失败: ASN${asn} HTTP=${code}"
  fi

  # ---------- Source B: bgp.he.net (HTML scrape fallback) ----------
  if [[ "$ok" -eq 0 ]]; then
    local he_url="https://bgp.he.net/AS${asn}#_prefixes"
    code=$(curl -sS -m 15 -o "$TMPDIR/he_${asn}.html" -w "%{http_code}" "$he_url" || echo "curl_fail")
    if [[ "$code" == "200" ]] && [[ -s "$TMPDIR/he_${asn}.html" ]]; then
      grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' "$TMPDIR/he_${asn}.html" >>"$TMP_V4" || true
      ok=1
    else
      log "⚠️ bgp.he.net 失败: ASN${asn} HTTP=${code}"
    fi
  fi

  if [[ "$ok" -eq 0 ]]; then
    log "❌ ASN${asn} 未获取到任何前缀（网络不可达或源不可用）"
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

  total=$(ipset list cloudblock | awk -F': ' '/Number of entries/ {print $2}')
  log "✅ 本次添加 IPv4 前缀: $added"
  log "📊 当前总计封禁 IPv4: $total"
}

main() {
  create_ipset
  : >"$TMP_V4"
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

install_firewall() {
  clear
  echo "============================"
  echo "🛡️ 请选择要封禁的云厂商范围："
  echo "============================"
  echo "1️⃣ 封禁所有主要云厂商 (默认)"
  echo "2️⃣ 自定义选择"
  echo "============================"
  read -p "请选择 [1-2] (默认 1): " asn_choice

  local selected_asns=""

 if [[ "$asn_choice" == "2" ]]; then
    echo ""
    echo "👉 请依次选择是否封禁 (直接回车默认为 Y)："
    for name in "${CLOUD_NAMES[@]}"; do
      read -p "是否封禁 [ $name ] ? [y/N]: " yn
      case $yn in
        [Nn]* ) 
          echo "   ⚪ 已跳过 $name"
          continue 
          ;;
        * ) 
          selected_asns="$selected_asns
  # $name
  ${CLOUD_ASNS[$name]}"
          ;;
      esac
    done
    
    if [[ -z "$selected_asns" ]]; then
      echo "❌ 未选择任何云厂商，取消安装。"
      sleep 2
      return
    fi
  else
    # 默认全部添加
    for name in "${CLOUD_NAMES[@]}"; do
      selected_asns="$selected_asns
  # $name
  ${CLOUD_ASNS[$name]}"
    done
  fi

  install_deps
  touch "$LOGFILE"
  chmod 640 "$LOGFILE"
  
  create_main_script "$selected_asns"
  create_cron_job
  
  log "🚀 立即执行首次封禁..."
  bash "$SCRIPT_PATH"
  log "✅ 安装完成！日志位置：$LOGFILE"
  read -p "按回车键返回菜单..."
}

refresh_rules() {
  if [ ! -f "$SCRIPT_PATH" ]; then
    echo "❌ 未检测到主脚本，请先执行安装。"
    sleep 2
    return
  fi
  log "🔁 手动刷新 ASN 数据..."
  bash "$SCRIPT_PATH"
  log "✅ 刷新完成。"
  read -p "按回车键返回菜单..."
}

show_blocked_info() {
  if ! ipset list cloudblock &>/dev/null; then
    echo "❌ 当前未创建封禁规则。"
    read -p "按回车键返回菜单..."
    return
  fi

  mapfile -t lines < <(ipset -L cloudblock | grep -E '^[0-9]')
  total=${#lines[@]}

  if [ "$total" -eq 0 ]; then
    echo "📭 当前没有封禁条目。"
    read -p "按回车键返回菜单..."
    return
  fi

  page_size=20
  pages=$(( (total + page_size - 1) / page_size ))
  page=1

  while true; do
    clear
    echo "📊 当前已封禁 IPv4 段数：$total   第 ${page}/${pages} 页"
    echo "-------------------------------------------------"
    start=$(( (page - 1) * page_size ))
    end=$(( start + page_size ))
    [ "$end" -gt "$total" ] && end=$total

    for ((i = start; i < end; i++)); do
      echo "${lines[i]}"
    done

    echo "-------------------------------------------------"
    echo "[n] 下一页(回车同n)  [p] 上一页  [f] 第一页  [l] 最后一页"
    echo "[a] 显示全部  [e] 导出到 /root/cloudblock_list.txt  [q] 返回菜单"
    read -p "选择: " opt

    case "$opt" in
      n|N|"")
        if [ "$page" -lt "$pages" ]; then page=$((page + 1)); else
          echo "已到最后一页。"
          sleep 1
        fi
        ;;
      p|P)
        if [ "$page" -gt 1 ]; then page=$((page - 1)); else
          echo "已到第一页。"
          sleep 1
        fi
        ;;
      f|F) page=1 ;;
      l|L) page=$pages ;;
      a|A)
        clear
        printf "%s\n" "${lines[@]}"
        echo "------------------ 显示完毕 ------------------"
        read -p "按回车返回分页显示..."
        ;;
      e|E)
        printf "%s\n" "${lines[@]}" > /root/cloudblock_list.txt
        echo "✅ 已导出到 /root/cloudblock_list.txt"
        read -p "按回车返回分页显示..."
        ;;
      q|Q) break ;;
      *) echo "⚠️ 无效选项"; sleep 1 ;;
    esac
  done
}

whitelist_menu() {
  while true; do
    clear
    echo "============================"
    echo "🟢 白名单管理"
    echo "============================"
    echo "1️⃣ 查看白名单"
    echo "2️⃣ 添加 IP/IP 段"
    echo "3️⃣ 删除 IP/IP 段"
    echo "0️⃣ 返回上级菜单"
    echo "============================"
    read -p "请选择 [0-3]: " wopt
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
        sleep 1
        ;;
      3)
        read -p "请输入要删除的 IP 或网段: " ip
        ipset -! del cloudwhitelist "$ip" && echo "🗑️ 已删除。" || echo "⚠️ 删除失败。"
        sleep 1
        ;;
      0) break ;;
      *) echo "❌ 无效选项"; sleep 1;;
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
  log "✅ 已卸载并清理所有相关文件与依赖。"
  echo "👋 已完成卸载并退出。"
  sleep 2
  exit 0
}

show_menu() {
  while true; do
    clear
    echo "============================"
    echo "☁️ 云厂商 ASN 封禁管理"
    echo "============================"
    echo "1️⃣ 安装并启用封禁规则"
    echo "2️⃣ 手动刷新 ASN 数据"
    echo "3️⃣ 查看当前封禁统计"
    echo "4️⃣ 白名单管理"
    echo "5️⃣ 卸载并清理"
    echo "0️⃣ 退出"
    echo "============================"
    read -p "请输入选项 [0-5]: " choice
    case "$choice" in
      1) install_firewall ;;
      2) refresh_rules ;;
      3) show_blocked_info ;;
      4) whitelist_menu ;;
      5) uninstall_firewall ;;
      0) echo "👋 再见！"; exit 0 ;;
      *) echo "❌ 无效选项"; sleep 1 ;;
    esac
  done
}

require_root
show_menu
