#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
mkdir -p artifacts
echo "0" > /tmp/removed_count

# 临时文件：存行号列表
TO_CHECK="/tmp/to_check.txt"
> "$TO_CHECK"

# 临时文件：存原始检测行和URL（用简单文件而非数组，避免内存坑）
CHECK_CONTENT="/tmp/check_content.txt"
> "$CHECK_CONTENT"

echo "正在读取原始文件并编号..."

lineno=0
while read -r line; do
  lineno=$((lineno + 1))

  # 简单兼容的URL检查
  case "$line" in
    *http://*|*https://*|*rtmp://*|*rtsp://*)
      url=$(echo "$line" | sed -n 's/.*\(http[s]*:\/\/[^ ]*\).*/\1/p' | head -n1)
      if [ -n "$url" ]; then
        echo "$lineno" >> "$TO_CHECK"
        echo "$lineno|$url|$line" >> "$CHECK_CONTENT"
      fi
      ;;
  esac
done < "$RAW"

TOTAL=$(wc -l < "$TO_CHECK" 2>/dev/null || echo 0)
echo "发现 $TOTAL 条直播源，开始 40 线程检测..."

# 检测函数（输出 0=有效 1=失效）
check_one() {
  local url="$1"
  if timeout 20 ffmpeg -user_agent "$UA" -i "$url" -t 4 -f null - -y >/dev/null 2>&1; then
    echo "0"
  elif timeout 25 ffprobe -user_agent "$UA" -v error -select_streams v:0 \
       -show_entries stream=width,height -of csv=p=0 "$url" 2>/dev/null | \
       grep -qE '^[0-9]+,[0-9]+$' ; then
    echo "0"
  else
    echo "1"
  fi
}
export -f check_one
export UA

# 并行检测（简单 printf 喂 URL）
if [ "$TOTAL" -gt 0 ]; then
  grep -o '|[^|]*|' "$CHECK_CONTENT" | cut -d'|' -f2 | parallel -j 40 --bar check_one > /tmp/status.txt
else
  > /tmp/status.txt
fi

# 最终重建文件（简单循环，无数组）
{
  check_idx=0
  lineno=0
  while read -r line; do
    lineno=$((lineno + 1))

    # 检查是否是检测行
    if grep -q "^$lineno$" "$TO_CHECK" 2>/dev/null; then
      status=$(sed -n "$((check_idx + 1))p" /tmp/status.txt 2>/dev/null || echo "1")
      check_line=$(sed -n "$((check_idx + 1))p" "$CHECK_CONTENT" 2>/dev/null || echo "")
      orig_line=$(echo "$check_line" | cut -d'|' -f3-)

      if [ "$status" = "0" ]; then
        echo "$orig_line"
      else
        echo "$orig_line" >> "artifacts/removed_$(date +%Y%m%d_%H%M).txt"
        count=$(cat /tmp/removed_count)
        echo $((count + 1)) > /tmp/removed_count
      fi
      check_idx=$((check_idx + 1))
    else
      echo "$line"
    fi
  done < "$RAW"
} > "$FINAL"

echo "============================================"
echo "清洗完成！共检测 $TOTAL 条，剔除 $(cat /tmp/removed_count) 条真死链"
echo "顺序 100% 原始 → list.txt 已生成"
