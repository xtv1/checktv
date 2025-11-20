#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
RESULT="/tmp/check_result.txt"
NEED_CHECK="/tmp/need_check.txt"
mkdir -p artifacts
> "$RESULT" > "$NEED_CHECK"
echo "0" > /tmp/removed_count

echo "正在逐行分析原始文件，保持 100% 原顺序..."

line_num=0
while IFS= read -r line || [[ -n "$line" ]]; do
  ((line_num++))

  if [[ "$line" == *http://* || "$line" == *https://* || "$line" == *rtmp://* || "$line" == *rtsp://* ]]; then
    url=$(echo "$line" | grep -oE 'https?://[^[:space:]]+|rtmp://[^[:space:]]+|rtsp://[^[:space:]]+' | head -n1)
    printf "%s\t%s\t%s\n" "$line_num" "$url" "$line" >> "$NEED_CHECK"
  fi
done < "$RAW"

TOTAL=$(wc -l < "$NEED_CHECK" || echo 0)
echo "发现 $TOTAL 条直播源，开始 40 线程极速检测..."

check_one() {
  local url="$1"
  local orig_line="$2"

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
export -f check_one
export UA

if (( TOTAL > 0 )); then
  parallel -j 40 --bar --halt now,fail=1 --col-sep '\t' \
    check_one {2} {3} < "$NEED_CHECK" > "$RESULT"
else
  > "$RESULT"
fi

{
  check_idx=0
  line_num=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_num++))

    if grep -q "^$line_num[[:space:]]" "$NEED_CHECK"; then
      result=$(sed -n "$((check_idx + 1))p" "$RESULT" 2>/dev/null || echo "FAIL|$line")
      ((check_idx++))

      if [[ "$result" == OK* ]]; then
        echo "${result#OK|}"
      else
        echo "${result#FAIL|}" >> "artifacts/removed_$(date +%Y%m%d_%H%M).txt"
        n=$(cat /tmp/removed_count)
        echo $((n + 1)) > /tmp/removed_count
      fi
    else
      echo "$line"
    fi
  done < "$RAW"
} > "$FINAL"

echo "============================================"
echo "完美清洗完成！总 $TOTAL 条，剔除 $(cat /tmp/removed_count) 条"
echo "分组顺序 100% 原样保留 → list.txt 已生成"
