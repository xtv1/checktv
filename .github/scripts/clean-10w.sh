#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
RESULT="/tmp/parallel_result"
mkdir -p artifacts
> "$RESULT"
echo "0" > /tmp/removed_count

# 关键修复：不再提前写分组！而是整行发给 parallel，检测完再原样输出
INPUT="/tmp/all_lines_with_url.txt"
> "$INPUT"

echo "正在逐行读取并保留原始顺序（支持10万条）..."

# 第一遍：只提取包含URL的行，附带原始行内容（保持顺序）
mapfile -t all_lines < "$RAW"
for line in "${all_lines[@]}"; do
  # 完全保留：空行、注释、分组标题、#EXTINF 等都不检测，直接待会原样输出
  if ! [[ "$line" =~ (https?://|rtmp://|rtsp://) ]]; then
    # 不是URL行 → 直接稍后输出（不参与检测）
    continue
  fi

  # 是URL行 → 提取第一个URL + 原始整行
  if [[ $line =~ (https?://[^[:space:]]+|rtmp://[^[:space:]]+|rtsp://[^[:space:]]+) ]]; then
    url="${BASH_REMATCH[1]}"
    printf '%s\t%s\n' "$url" "$line" >> "$INPUT"
  fi
done

TOTAL=$(wc -l < "$INPUT")
echo "发现 $TOTAL 条待检测链接，开始40线程高速检测（顺序不变）..."

check_url() {
  local url="$1"
  local orig_line="$2"

  # 双保险检测
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

# 并行检测（只检测URL行）
parallel -j 40 --bar --halt now,fail=1 --col-sep '\t' \
  check_url {1} {2} < "$INPUT" > "$RESULT"

# 第二遍：完整重建文件，保持原始顺序
{
  url_line_idx=0
  for line in "${all_lines[@]}"; do
    if ! [[ "$line" =~ (https?://|rtmp://|rtsp://) ]]; then
      # 非URL行（分组、注释、空行）原样输出
      echo "$line"
      continue
    fi

    # 是URL行 → 从 parallel 结果中取第 url_line_idx 行的判断
    result=$(sed -n "$((url_line_idx + 1))p" "$RESULT")
    url_line_idx=$((url_line_idx + 1))

    if [[ $result == OK* ]]; then
      echo "${result#OK|}"
    else
      echo "#失效已删除: ${result#FAIL|}" >&2   # 写入被删除日志
      (( $(cat /tmp/removed_count) + 1 )) > /tmp/removed_count
    fi
  done
} > "$FINAL"

# 记录被删除数量
echo $(cat /tmp/removed_count) > /tmp/removed_count

echo "============================================"
echo "清洗完成！完全保留原始分组顺序"
echo "总链接数: $TOTAL   剔除失效: $(cat /tmp/removed_count)   保留 $((TOTAL - $(cat /tmp/removed_count))) 条"
echo "最终文件 → list.txt（分组丝毫不乱）"

# 保存被删除的原始行供审计
grep "^FAIL|" "$RESULT" | cut -d'|' -f2- > "artifacts/removed_$(date +%Y%m%d_%H%M).txt"
