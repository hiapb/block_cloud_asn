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
  "37963" "45102" "45103" "45104" "59028" "59051" "59052" "59053" "59054" "59055" "203513" # 阿里云/阿里系（ALIBABA-CN-NET / ALIBABACLOUD）
  "9390" "45090" "58835" "132203" "132591" "133478" "137876" # 腾讯云/腾讯系（TENCENT / QCLOUD / TENCENTCLOUD）
  "149640" # 华为云/华为系（HUAWEI / HUAWEI CLOUD）
  "38365" "38627" "45076" "45085" "55967" "63288" "63728" "63729" "131138" "131139" "131140" "131141" "133746" "199506" # 百度云/百度系（BAIDU）
  # (no matches) 京东云/京东系（JINGDONG / JD CLOUD）
  "137775" "396986" # 火山引擎/字节系（VOLCENGINE / BYTEDANCE）
  "59077" "135377" "139327" # UCloud（UCLOUD）
  "137280" # 金山云（KSYUN / KINGSOFT）
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

  local ok=0

  # ---------- Source A: RIPEstat (recommended) ----------
  # https://stat.ripe.net/data/announced-prefixes/data.json?resource=ASxxxxx
  local ripe_url="https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${asn}"
  local code
  code=$(curl -sS -m 15 -o "$TMPDIR/ripe_${asn}.json" -w "%{http_code}" "$ripe_url" || echo "curl_fail")
  if [[ "$code" == "200" ]] && [[ -s "$TMPDIR/ripe_${asn}.json" ]]; then
    # data.prefixes[].prefix
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
      # 粗暴抓 CIDR（页面里通常有 /xx）
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

  # 读取所有条目到数组（每行一个）
  mapfile -t lines < <(ipset -L cloudblock | grep -E '^[0-9]')
  total=${#lines[@]}

  if [ "$total" -eq 0 ]; then
    echo "📭 当前没有封禁条目。"
    read -p "按回车键返回菜单..."
    return
  fi

  page_size=20                        # 每页显示多少条（可按需调整）
  pages=$(( (total + page_size - 1) / page_size ))
  page=1

  while true; do
    clear
    echo "📊 当前已封禁 IPv4 段数：$total    第 ${page}/${pages} 页"
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
      q|Q)
        break
        ;;
      *)
        echo "⚠️ 无效选项"
        sleep 1
        ;;
    esac
  done
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
