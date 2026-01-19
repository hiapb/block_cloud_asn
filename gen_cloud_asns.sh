cat >/root/gen_cloud_asns.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

need_cmd() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq >/dev/null 2>&1 || true
  apt-get install -y -qq curl jq ca-certificates >/dev/null 2>&1 || true
}

if ! need_cmd curl || ! need_cmd jq; then
  echo "[*] Installing dependencies (curl, jq, ca-certificates)..."
  install_deps
fi

if ! need_cmd curl || ! need_cmd jq; then
  echo "[!] Still missing curl/jq. Please install manually: apt-get install -y curl jq"
  exit 1
fi

# ---- RIPEstat searchcomplete fetch ----
fetch_asn_lines() {
  # $1 = query term
  local q="$1"
  curl -sS -m 20 "https://stat.ripe.net/data/searchcomplete/data.json?resource=${q// /%20}&limit=100" \
    | jq -r '
      .data.categories[]?
      | select(.category=="ASNs")
      | .suggestions[]?
      | "\(.label)\t\(.description)"'
}

# ---- Vendor grouping rules (match on description) ----
# We purposely use stricter tokens to avoid same-name unrelated ASNs.
is_alibaba()   { grep -Eiq 'ALIBABA-CN-NET|ALIBABACLOUD|ALIBABA CLOUD|ALIBABA(,| )' ; }
is_tencent()   { grep -Eiq 'TENCENT|TENCENTCLOUD|QCLOUD' ; }
is_huawei()    { grep -Eiq 'HUAWEI|HUAWEI CLOUD|HUAWEICLOUD' ; }
is_baidu()     { grep -Eiq 'BAIDU' ; }
is_jd()        { grep -Eiq 'JINGDONG|JD CLOUD|JD\.COM|JDCHINA|JD-?CLOUD' ; }
is_volc()      { grep -Eiq 'BYTEDANCE|VOLCENGINE|VOLCANO ENGINE|BYTE DANCE' ; }
is_ucloud()    { grep -Eiq 'UCLOUD' ; }
is_kingsoft()  { grep -Eiq 'KINGSOFT|KSYUN|KS CLOUD' ; }

# Exclusions to reduce false positives (extend if you see junk)
exclude_noise() {
  # Example: ALIBABA-TRAVELS-COMPANY (not Alibaba Cloud)
  grep -Ev 'ALIBABA-TRAVELS|TRAVELS-COMPANY'
}

extract_asn_numbers() {
  # from "AS12345<TAB>desc" -> "12345"
  grep -Eo 'AS[0-9]+' | sed 's/^AS//'
}

tmp="$(mktemp -d)"
all="$tmp/all.tsv"
: >"$all"

# Query terms per vendor (we query multiple synonyms for better recall)
queries=(
  "alibaba" "aliyun" "alibabacloud"
  "tencent" "qcloud" "tencentcloud"
  "huawei" "huawei cloud" "huaweicloud"
  "baidu"
  "jingdong" "jdcloud" "jd cloud" "jd.com"
  "bytedance" "volcengine" "volcano engine"
  "ucloud"
  "ksyun" "kingsoft"
)

for q in "${queries[@]}"; do
  fetch_asn_lines "$q" >>"$all" || true
done

# normalize + filter noise + uniq
sort -u "$all" | exclude_noise >"$tmp/uniq.tsv"

get_group() {
  local name="$1"
  local fn="$2"
  local out="$3"
  : >"$out"
  # shellcheck disable=SC2016
  awk -F'\t' '{print $1 "\t" $2}' "$tmp/uniq.tsv" \
    | while IFS= read -r line; do
        # pass line through matcher
        if echo "$line" | "$fn" >/dev/null 2>&1; then
          echo "$line"
        fi
      done \
    | extract_asn_numbers \
    | sort -n -u >"$out"
}

get_group "Alibaba"  is_alibaba  "$tmp/alibaba.txt"
get_group "Tencent"  is_tencent  "$tmp/tencent.txt"
get_group "Huawei"   is_huawei   "$tmp/huawei.txt"
get_group "Baidu"    is_baidu    "$tmp/baidu.txt"
get_group "JD"       is_jd       "$tmp/jd.txt"
get_group "Volc"     is_volc     "$tmp/volc.txt"
get_group "UCloud"   is_ucloud   "$tmp/ucloud.txt"
get_group "Kingsoft" is_kingsoft "$tmp/kingsoft.txt"

# helper to print quoted list in one line
print_line() {
  local file="$1"
  local comment="$2"
  local nums
  nums="$(paste -sd' ' "$file" 2>/dev/null || true)"
  if [[ -n "${nums// /}" ]]; then
    # print as "123" "456" ...
    echo -n "  "
    while read -r n; do
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
print_line "$tmp/alibaba.txt"  "阿里云/阿里系（ALIBABA/ALIBABACLOUD）"
print_line "$tmp/tencent.txt"  "腾讯云/腾讯系（TENCENT/QCLOUD）"
print_line "$tmp/huawei.txt"   "华为云/华为系（HUAWEI）"
print_line "$tmp/baidu.txt"    "百度云/百度系（BAIDU）"
print_line "$tmp/jd.txt"       "京东云/京东系（JINGDONG/JD CLOUD）"
print_line "$tmp/volc.txt"     "火山引擎/字节系（VOLCENGINE/BYTEDANCE）"
print_line "$tmp/ucloud.txt"   "UCloud（UCLOUD）"
print_line "$tmp/kingsoft.txt" "金山云（KSYUN/KINGSOFT）"
echo ')'
echo

echo "[*] Raw candidates saved: $tmp/uniq.tsv"
echo "[*] Tip: If you see missing vendors, run again and inspect $tmp/uniq.tsv for their exact description tokens."
EOF

chmod +x /root/gen_cloud_asns.sh
bash /root/gen_cloud_asns.sh
