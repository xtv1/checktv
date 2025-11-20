#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
mkdir -p artifacts
echo "0" > /tmp/removed_count

# 临时文件：每行 "行号|||URL|||原始整行"
TEMP_INPUT="/tmp/to_check.txt"
> "$TEMP_INPUT"

echo "正在读取原始文件并编号（保证顺序）..."

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))

  # 只处理包含 http/https/rtmp/rtsp 的行
  if echo "$line" | grep -Eq 'https?://|rtmp://|rtsp://'; then
    url=$(echo "$line" | grep -Eo 'https?://[^[:space:]]+|rtmp://[^[:space:]]+|rtsp://[^[:space:]]+' | head -n1)
    printf "%05d|||%s|||%s\n" "$lineno" "$url" "$line" >> "$TEMP_INPUT"
  fi
done < "$RAW"

TOTAL=$(wc -l < "$TEMP_INPUT" 2>/dev/null || echo 0)
echo "发现 $TOTAL 条待检测链接，开始 40 线程检测..."

# 检测函数：输出带行号的结果
check() {
  local input="$1"
  local lineno=$(echo "$input" | cut -d'|' -f1)
  local url=$(echo "$input" | cut -d'|' -f4- | cut -d'|' -f1)
  local orig=$(echo "$input" | cut -d'|' -f7-)

  if timeout 20 ffmpeg -user_agent "$UA" -i "$url" -t 4 -f null - -y > /dev/null 2>&1; then
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

# 关键：用 -a 读文件 + --keep-order 强制顺序输出
if [ "$TOTAL" -gt 0 ]; then
  parallel --keep-order -j 40 --bar check :::: "$TEMP_INPUT" > /tmp/result.txt
else
  > /tmp/result.txt
fi

# 最终重建文件（严格按原始顺序）
{
  current=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    current=$((current + 1))

    # 检查这行是否在我们检测列表中
    if grep -q "^${current}$" "$TEMP_INPUT" 2>/dev/null; then
      result=$(grep "^${current}[^0-9]" /tmp/result.txt || echo "")
      if [[ -n "$result" && "$result" == *OK* ]]; then
        echo "$result" | cut -d'|' -f7-
      else
        # 失效的记录
        if [[ -n "$result" ]]; then
          echo "$result" | cut -d'|' -f7- >> "artifacts/removed_$(date +%Y%m%d_%H%M).txt"
        fi
        count=$(cat /tmp/removed_count)
        echo $((count + 1)) > /tmp/removed_count
      fi
    else
      # 分组标题、空行等原样输出
      echo "$line"
    fi
  done < "$RAW"
} > "$FINAL"

echo "============================================"
echo "清洗完成！共检测 $TOTAL 条，剔除 $(cat /tmp/removed_count) 条死链"
echo "顺序 100% 原样保留 → list.txt 已生成"
