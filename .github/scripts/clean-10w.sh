#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
mkdir -p artifacts
echo "0" > /tmp/removed_count

# 临时文件：每行格式 "行号|||原始行|||URL"
INPUT="/tmp/check_lines.txt"
> "$INPUT"

echo "正在读取原始文件并编号（保持 100% 原顺序）..."

# 第一步：给每一行打上永久编号，只提取含 URL 的行
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  ((lineno++))
  # 如果这行包含 http/https/rtmp/rtsp，则需要检测
  if echo "$line" | grep -Eq 'https?://|rtmp://|rtsp://'; then
    url=$(echo "$line" | grep -Eo 'https?://[^ ]+|rtmp://[^ ]+|rtsp://[^ ]+' | head -n1)
    printf "%05d|||%s|||%s\n" "$lineno" "$line" "$url" >> "$INPUT"
  fi
done < "$RAW"

TOTAL=$(wc -l < "$INPUT")
echo "发现 $TOTAL 条直播源，开始 40 线程检测（顺序永不乱）..."

# 检测函数：输出带编号的结果
check_one() {
  local numbered_line="$1"
  local lineno=$(echo "$numbered_line" | cut -d'|' -f1)
  local orig_line=$(echo "$numbered_line" | cut -d'|' -f3- | cut -d'|' -f1)
  local url=$(echo "$numbered_line" | cut -d'|' -f5-)

  if timeout 20 ffmpeg -user_agent "$UA" -i "$url" -t 4 -f null - -y >/dev/null 2>&1; then
    echo "$lineno|||OK|||$orig_line"
  elif timeout 25 ffprobe -user_agent "$UA" -v error -select_streams v:0 \
       -show_entries stream=width,height -of csv=p=0 "$url" 2>/dev/null | \
       grep -qE '^[0-9]+,[0-9]+$'; then
    echo "$lineno|||OK|||$orig_line"
  else
    echo "$lineno|||FAIL|||$orig_line"
  fi
}
export -f check_one
export UA

# 并行检测（--keep-order 强制保持输入顺序！这才是王道）
parallel --keep-order -j 40 --bar check_one ::: "$(cat "$INPUT")" > /tmp/check_result.txt

# 第二步：严格按原始行号顺序重建文件
declare -A results  # 关联数组：key=行号，value=OK/FAIL + 行内容

while IFS= read -r result; do
  lineno=$(echo "$result" | cut -d'|' -f1)
  status=$(echo "$result" | cut -d'|' -f4)
  line=$(echo "$result" | cut -d'|' -f7-)
  results["$lineno"]="$status|||${line}"
done < /tmp/check_result.txt

# 最终输出：逐行重建原始文件
{
  current_line=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((current_line++))
    if [[ -v results[$current_line] ]]; then
      status=$(echo "${results[$current_line]}" | cut -d'|' -f1)
      content=$(echo "${results[$current_line]}" | cut -d'|' -f4-)
      if [[ "$status" == "OK" ]]; then
        echo "$content"
      else
        # 失效的写入移除列表
        echo "$content" >> "artifacts/removed_$(date +%Y%m%d_%H%M).txt"
        echo $(( $(cat /tmp/removed_count) + 1 )) > /tmp/removed_count
      fi
    else
      # 分组、标题、空行、注释等原样输出
      echo "$line"
    fi
  done < "$RAW"
} > "$FINAL"

echo "============================================"
echo "清洗完成！共检测 $TOTAL 条，剔除 $(cat /tmp/removed_count) 条死链"
echo "分组顺序 100% 原样保留！→ list.txt 已生成"
echo "被移除的源已保存到 artifacts/"
