#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
VALID="/tmp/valid_lines"
REMOVED="/tmp/removed_lines"
RESULT="/tmp/parallel_result"
mkdir -p artifacts
> "$VALID" > "$REMOVED" > "$RESULT"
echo "0" > /tmp/removed_count

# 1. 按行读取，保留所有非URL行（分组、注释、空行）直接过
#    只把包含 http/rtmp/rtsp 的行送去检测
INPUT_LIST="/tmp/need_check.txt"
> "$INPUT_LIST"

echo "正在扫描分组与链接（支持10万条）..."
while IFS= read -r line || [[ -n "$line" ]]; do
  # 直接保留：分组标题、#EXTINF、注释、空行
  if [[ "$line" == "#genre#"* ]] || [[ "$line" == "#EXTINF"* ]] || [[ "$line" == \#* ]] || [[ -z "$line" ]]; then
    echo "$line" >> "$VALID"
    continue
  fi

  # 提取URL（支持中间有空格、$ 等情况）
  if [[ $line =~ (https?://[^[:space:]]+|rtmp://[^[:space:]]+|rtsp://[^[:space:]]+) ]]; then
    url="${BASH_REMATCH[1]}"
    echo -e "$url\t$line" >> "$INPUT_LIST"
  else
    # 极少数异常行也保留
    echo "$line" >> "$VALID"
  fi
done < "$RAW"

TOTAL=$(wc -l < "$INPUT_LIST")
echo "发现 $TOTAL 条链接，开始 40 线程高速检测（已加UA）..."

check_url() {
  local url="$1"
  local orig_line="$2"

  # 双保险检测（任意一个成功即为有效）
  if timeout 20 ffmpeg -user_agent "$UA" -i "$url" -t 4 -f null - -y >/dev/null 2>&1; then
    echo "OK|$orig_line"
    return
  fi
  if timeout 25 ffprobe -user_agent "$UA" -v error -select_streams v:0 \
      -show_entries stream=width,height -of csv=p=0 "$url" 2>/dev/null \
      | grep -qE '^[0-9]+,[0-9]+$'; then
    echo "OK|$orig_line"
    return
  fi
  echo "FAIL|$orig_line"
}
export -f check_url
export UA

# 防卡死 + 高并发核心
parallel -j 40 --bar --halt now,fail=1 --col-sep '\t' \
  check_url {1} {2} < "$INPUT_LIST" > "$RESULT"

# 分类写入
while IFS= read -r r; do
  if [[ $r == OK* ]]; then
    echo "${r#OK|}" >> "$VALID"
  else
    echo "${r#FAIL|}" >> "$REMOVED"
    n=$(cat /tmp/removed_count)
    echo $((n+1)) > /tmp/removed_count
  fi
done < "$RESULT"

mv "$VALID" "$FINAL"
REMOVED_COUNT=$(cat /tmp/removed_count)

echo "============================================"
echo "万条级清洗完成！"
echo "总链接数: $TOTAL   剔除失效: $REMOVED_COUNT   保留 $(($TOTAL - $REMOVED_COUNT)) 条"
echo "分组、标题、注释全部原样保留！"
cp "$REMOVED" "artifacts/removed_$(date +%Y%m%d_%H%M).txt"

echo "最终干净源已写入 list.txt，即将自动提交！"
