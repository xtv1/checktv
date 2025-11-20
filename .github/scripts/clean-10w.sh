#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
RESULT="/tmp/check_result.txt"
NEED_CHECK="/tmp/need_check.txt"

mkdir -p artifacts
: > "$RESULT" > "$NEED_CHECK"
echo "0" > /tmp/removed_count

echo "正在逐行分析原始文件，保持 100% 原顺序..."

# 第一步：提取所有含 URL 的行 + 行号（兼容 dash）
line_num=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line_num=$((line_num + 1))

  if echo "$line" | grep -Eq 'https?://|rtmp://|rtsp://'; then
    url=$(echo "$line" | grep -Eo 'https?://[^ ]+|rtmp://[^ ]+|rtsp://[^ ]+' | head -n1)
    printf '%s\t%s\t%s\n' "$line_num" "$url" "$line" >> "$NEED_CHECK"
  fi
done < "$RAW"

TOTAL=$(wc -l < "$NEED_CHECK" 2>/dev/null || echo 0)
echo "发现 $TOTAL 条直播源，开始 40 线程极速检测..."

# 检测函数（不变）
check_one() {
  local url="$1"
  local orig_line="$2"

  if timeout 20 ffmpeg -user_agent "$UA" -i "$url" -t 4 -f null - -y >/dev/null 2>&1; then
    echo "OK|$orig_line"
    return
  fi
  if timeout 25 ffprobe -user_agent "$UA" -v error -select_streams v:0 \
      -show_entries stream=width,height -of csv=p=0 "$url" 2>/dev/null | \
      grep -qE '^[0-9]+,[0-9]+$'; then
    echo "OK|$orig_line"
    return
  fi
  echo "FAIL|$orig_line"
}
export -f check_one
export UA

# 并行检测（有源才跑）
if [ "$TOTAL" -gt 0 ]; then
  parallel -j 40 --bar --halt now,fail=1 --col-sep '\t' \
    check_one {2} {3} < "$NEED_CHECK" > "$RESULT"
else
  : > "$RESULT"
fi

# 第二步：完美重建文件（关键保序逻辑）
{
  check_idx=0
  line_num=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))

    # 判断当前行是否需要检测
    if grep -q "^$line_num[[:space:]]" "$NEED_CHECK" 2>/dev/null; then
      result=$(sed -n "$((check_idx + 1))p" "$RESULT" 2>/dev/null || echo "FAIL|$line")
      check_idx=$((check_idx + 1))

      if echo "$result" | grep -q "^OK|"; then
        echo "$result" | cut -d'|' -f2-
      else
        echo "$result" | cut -d'|' -f2- >> "artifacts/removed_$(date +%Y%m%d_%H%M).txt"
        count=$(cat /tmp/removed_count)
        echo $((count + 1)) > /tmp/removed_count
      fi
    else
      # 分组标题、空行、注释等原样输出
      echo "$line"
    fi
  done < "$RAW"
} > "$FINAL"

echo "============================================"
echo "清洗完成！共检测 $TOTAL 条，剔除 $(cat /tmp/removed_count) 条死链"
echo "分组顺序 100% 原样保留 → list.txt 已生成，可直接用于 TV 盒子"
