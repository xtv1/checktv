#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
mkdir -p artifacts
echo "0" > /tmp/removed_count

# 临时文件：格式 "行号|||URL|||原始行"
TEMP="/tmp/check.txt"
> "$TEMP"

echo "正在读取原始文件并编号..."

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  if echo "$line" | grep -Eq 'https?://|rtmp://|rtsp://'; then
    url=$(echo "$line" | grep -Eo 'https?://[^[:space:]]+|rtmp://[^[:space:]]+|rtsp://[^[:space:]]+' | head -n1)
    printf "%d|||%s|||%s\n" "$lineno" "$url" "$line" >> "$TEMP"
  fi
done < "$RAW"

TOTAL=$(wc -l < "$TEMP")
echo "发现 $TOTAL 条链接，开始 40 线程检测（顺序永不乱）..."

check() {
  local input="$1"
  local lineno=$(echo "$input" | cut -d'|' -f1)
  local url=$(echo "$input" | cut -d'|' -f4- | cut -d'|' -f1)
  local orig=$(echo "$input" | cut -d'|' -f7-)

  if timeout 20 ffmpeg -user_agent "$UA" -i "$url" -t 4 -f null - -y >/dev/null 2>&1; then
    echo "$lineno|||OK|||$orig"
  elif timeout 25 ffprobe -user_agent "$UA" -v error -select_streams v:0 \
       -show_entries stream=width,height -of csv=p=0 "$url" 2>/dev/null | \
       grep -qE '^[0-9]+,[0-9]+$'; then
    echo "$lineno|||OK|||$orig"
  else
    echo "$lineno|||FAIL|||$orig"
  fi
}
export -f check
export UA

if [ "$TOTAL" -gt 0 ]; then
  parallel --keep-order -j 40 --bar check :::: "$TEMP" > /tmp/result.txt
else
  > /tmp/result.txt
fi

# 精确重建文件（关键修复）
{
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))

    # 精确匹配行号
    result=$(grep "^${lineno}\\|" /tmp/result.txt || echo "")
    if [ -n "$result" ]; then
      status=$(echo "$result" | cut -d'|' -f4)
      content=$(echo "$result" | cut -d'|' -f7-)
      if [ "$status" = "OK" ]; then
        echo "$content"
      else
        echo "$content" >> "artifacts/removed_$(date +%Y%m%d_%H%M).txt"
        echo $(( $(cat /tmp/removed_count) + 1 )) > /tmp/removed_count
      fi
    else
      # 分组、标题、空行原样输出
      echo "$line"
    fi
  done < "$RAW"
} > "$FINAL"

echo "============================================"
echo "清洗完成！共检测 $TOTAL 条，成功剔除 $(cat /tmp/removed_count) 条死链"
echo "顺序 100% 原始，分组完美 → list.txt 已生成"
