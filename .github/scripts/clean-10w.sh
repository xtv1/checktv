#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
mkdir -p artifacts
echo "0" > /tmp/removed_count

# 临时文件只存需要检测的行
TO_CHECK="/tmp/to_check.txt"
> "$TO_CHECK"

echo "正在读取原始文件并编号..."

# 第一步：读取原始文件，记录所有含 URL 的行（带行号）
declare -a check_lines   # 存需要检测的原始行
declare -a check_urls    # 对应 URL
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  ((lineno++))
  if echo "$line" | grep -Eq 'https?://|rtmp://|rtsp://'; then
    url=$(echo "$line" | grep -Eo 'https?://[^[:space:]]+|rtmp://[^[:space:]]+|rtsp://[^[:space:]]+' | head -n1)
    check_lines+=("$line")
    check_urls+=("$url")
    echo "$lineno" >> "$TO_CHECK"
  fi
done < "$RAW"

TOTAL=${#check_urls[@]}
echo "发现 $TOTAL 条直播源，开始 40 线程检测..."

# 检测函数（输出 0=有效 1=失效）
check_one() {
  local url="$1"
  if timeout 20 ffmpeg -user_agent "$UA" -i "$url" -t 4 -f null - -y >/dev/null 2>&1; then
    echo "0"
  elif timeout 25 ffprobe -user_agent "$UA" -v error -select_streams v:0 \
       -show_entries stream=width,height -of csv=p=0 "$url" 2>/dev/null | \
       grep -qE '^[0-9]+,[0-9]+$'; then
    echo "0"
  else
    echo "1"
  fi
}
export -f check_one
export UA

# 并行检测（只输出 0 或 1）
if (( TOTAL > 0 )); then
  printf "%s\n" "${check_urls[@]}" | parallel -j 40 --bar check_one > /tmp/status.txt
else
  > /tmp/status.txt
fi

# 第二步：最终重建文件（最稳方案）
{
  check_idx=0
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((lineno++))
    # 判断当前行是否在我们检测列表中
    if (( check_idx < TOTAL )) && grep -q "^$lineno$" "$TO_CHECK"; then
      status=$(sed -n "$((check_idx + 1))p" /tmp/status.txt)
      if [ "$status" = "0" ]; then
        echo "${check_lines[$check_idx]}"
      else
        echo "${check_lines[$check_idx]}" >> "artifacts/removed_$(date +%Y%m%d_%H%M).txt"
        echo $(( $(cat /tmp/removed_count) + 1 )) > /tmp/removed_count
      fi
      ((check_idx++))
    else
      # 分组标题、空行、注释原样输出
      echo "$line"
    fi
  done < "$RAW"
} > "$FINAL"

echo "============================================"
echo "清洗完成！共检测 $TOTAL 条，剔除 $(cat /tmp/removed_count) 条真死链"
echo "顺序 100% 原始 → list.txt 已生成"
