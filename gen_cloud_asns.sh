#!/usr/bin/env bash
# gen_cloud_asns.sh - Print-ready ASN block for major China cloud vendors
# Data source: RIPEstat searchcomplete (needs curl + jq)
set -euo pipefail

need_cmd() { command -v "$1" >/dev/null 2>&1; }

install_deps_debian() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq >/dev/null 2>&1 || true
  apt-get install -y -qq curl jq ca-certificates >/dev/null 2>&1 || true
}

ensure_deps() {
  local missing=0
  for c in curl jq; do
    need_cmd "$c" || missing=1
  done

  if [[ "$missing" -eq 1 ]]; then
    echo "[*] Installing dependencies (curl, jq, ca-certificates)..."
    if need_cmd apt-get; then
      install_deps_debian
    else
      echo "[!] apt-get not found. Please install curl + jq manually."
      exit 1
    fi
  fi

  for c in curl jq; do
    if ! need_cmd "$c"; then
      echo "[!] Missing dependency: $c"
      exit 1
    fi
  done
}

fetch_asn_lines() {
  # output: "AS12345<TAB>DESCRIPTION"
  local q="$1"
  curl -sS -m 25 "https://stat.ripe.net/data/searchcomplete/data.json?resource=${q// /%20}&limit=100" \
    | jq -r '
      .data.categories[]?
      | select(.category=="ASNs")
      | .suggestions[]?
      | "\(.label)\t\(.description)"'
}

exclude_noise() {
  # Avoid obvious same-name unrelated orgs
  grep -Ev 'ALIBABA-TRAVELS|TRAVELS-COMPANY'
}

extract_asn_numbers() {
  grep -Eo 'AS[0-9]+' | sed 's/^AS//'
}

# Matchers (tight-ish to reduce false positives)
is_alibaba()   { grep -Eiq 'ALIBABA-CN-NET|ALIBABACLOUD' ; }
is_tencent()   { grep -Eiq 'TENCENT|TENCENTCLOUD|QCLOUD' ; }
is_huawei()    { grep -Eiq 'HUAWEI|HUAWEI CLOUD|HUAWEICLOUD' ; }
is_baidu()     { grep -Eiq 'BAIDU' ; }
is_jd()        { grep -Eiq 'JINGDONG|JD CLOUD|JD\.COM|JDCHINA|JD-?CLOUD' ; }
is_volc()      { grep -Eiq 'BYTEDANCE|VOLCENGINE|VOLCANO ENGINE|BYTE DANCE' ; }
is_ucloud()    { grep -Eiq 'UCLOUD' ; }
is_kingsoft()  { grep -Eiq 'KINGSOFT|KSYUN|KS CLOUD' ; }

QUERIES=(
  # Alibaba
  "alibaba" "aliyun" "alibabacloud"
  # Tencent
  "tencent" "qcloud" "tencentcloud"
  # Huawei (searchcomplete sometimes needs broader terms)
  "huawei" "huawei cloud" "huaweicloud"
  # Baidu
  "baidu"
  # JD
  "jingdong" "jdcloud" "jd cloud" "jd.com"
  # ByteDance/Volcengine
  "bytedance" "volcengine" "volcano engine"
  # UCloud
  "ucloud"
  # Kingsoft Cloud
  "ksyun" "kingsoft"
)

main() {
  ensure_deps

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  local all="$tmp/all.tsv"
  : >"$all"

  for q in "${QUERIES[@]}"; do
    fetch_asn_lines "$q" >>"$all" || true
  done

  sort -u "$all" | exclude_noise >"$tmp/uniq.tsv"

  group_asns() {
    local matcher="$1"
    local outfile="$2"
    : >"$outfile"
    while IFS= read -r line; do
      if echo "$line" | "$matcher" >/dev/null 2>&1; then
        echo "$line"
      fi
    done <"$tmp/uniq.tsv" | extract_asn_numbers | sort -n -u >"$outfile"
  }

  group_asns is_alibaba  "$tmp/alibaba.txt"
  group_asns is_tencent  "$tmp/tencent.txt"
  group_asns is_huawei   "$tmp/huawei.txt"
  group_asns is_baidu    "$tmp/baidu.txt"
  group_asns is_jd       "$tmp/jd.txt"
  group_asns is_volc     "$tmp/volc.txt"
  group_asns is_ucloud   "$tmp/ucloud.txt"
  group_asns is_kingsoft "$tmp/kingsoft.txt"

  print_line() {
    local file="$1"
    local comment="$2"
    if [[ -s "$file" ]]; then
      echo -n "  "
      while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        echo -n "\"$n\" "
      done <"$file"
      echo "# $comment"
    else
      echo "  # (no matches) $comment"
    fi
  }

  echo
  echo 'ASNS=('
  print_line "$tmp/alibaba.txt"  "阿里云/阿里系（ALIBABA-CN-NET / ALIBABACLOUD）"
  print_line "$tmp/tencent.txt"  "腾讯云/腾讯系（TENCENT / QCLOUD / TENCENTCLOUD）"
  print_line "$tmp/huawei.txt"   "华为云/华为系（HUAWEI / HUAWEI CLOUD）"
  print_line "$tmp/baidu.txt"    "百度云/百度系（BAIDU）"
  print_line "$tmp/jd.txt"       "京东云/京东系（JINGDONG / JD CLOUD）"
  print_line "$tmp/volc.txt"     "火山引擎/字节系（VOLCENGINE / BYTEDANCE）"
  print_line "$tmp/ucloud.txt"   "UCloud（UCLOUD）"
  print_line "$tmp/kingsoft.txt" "金山云（KSYUN / KINGSOFT）"
  echo ')'
  echo
}

main "$@"
