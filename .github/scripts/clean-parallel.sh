#!/bin/bash
set -euo pipefail

ORIGINAL="list.txt"
BACKUP="list.txt.bak.$(date +%Y%m%d)"
VALID_FILE="/tmp/valid.txt"
REMOVED_FILE="/tmp/removed.txt"
REMOVED_COUNT="/tmp/removed_count"

cp "$ORIGINAL" "$BACKUP"           # 备份原始文件
> "$VALID_FILE"
> "$REMOVED_FILE"
echo "0" > "$REMOVED_COUNT"

# 临时文件：每行格式 "url|||name|||original_line"
TMP_INPUT="/tmp/streams_to_check.txt"
> "$TMP_INPUT"

echo "正在解析直播源列表..."
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^# ]] && { echo "$line" >> "$VALID_FILE"; continue; }  # 保留注释

  url=$(echo "$line" | cut -d',' -f1)
  name=$(echo "$line" | cut -d',' -f2-)
  echo "$url|||${name:-未知频道}|||$(echo "$line" | sed 's/|/PIPE/g')" >> "$TMP_INPUT"
done < "$ORIGINAL"

TOTAL=$(wc -l < "$TMP_INPUT")
echo "共发现 $TOTAL 条待检测源，开始并行检测（最高 50 线程）..."

# 核心：并行检测函数
check_stream() {
  local line="$1"
  local url=$(echo "$line" | cut -d'|' -f1 -d'|')
  local name=$(echo "$line" | cut -d'|' -f4- -d'|' | sed 's/PIPE/|/g')  # 还原原始行

  if timeout 25 ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height,duration \
      -of csv=p=0 "$url" 2>/dev/null | grep -q ",N/A$"; then
    echo "OK|$line"
  else
    if timeout 20 ffmpeg -i "$url" -t 1 -f null /dev/null -y 2>/dev/null; then
      echo "OK|$line"   # 极少数特殊流 ffprobe 判不出，但 ffmpeg 能连上
    else
      echo "FAIL|$line"
    fi
  fi
}

export -f check_stream
export VALID_FILE REMOVED_FILE REMOVED_COUNT

# 并行执行！50 线程 + 进度条
cat "$TMP_INPUT" | \
  parallel -j 50 --bar --line-buffer \
  check_stream {} | \
  while IFS= read -r result; do
    status=$(echo "$result" | cut -d'|' -f1)
    original_line=$(echo "$result" | cut -d'|' -f5- | sed 's/PIPE/|/g')

    if [[ "$status" == "OK" ]]; then
      echo "$original_line" >> "$VALID_FILE"
    else
      echo "$original_line" >> "$REMOVED_FILE"
      echo "$original_line" >> "$REMOVED_FILE"
      count=$(cat "$REMOVED_COUNT")
      echo $((count + 1)) > "$REMOVED_COUNT"
    fi
  done

# 最终替换
mv "$VALID_FILE" "$ORIGINAL"

REMOVED=$(cat "$REMOVED_COUNT")
echo "=========================================="
echo "多线程检测完成！共 $TOTAL 条，剔除 $REMOVED 条失效源"
echo "新 list.txt 已生成（仅保留有效源）"
echo "被移除的源已保存到 artifacts/removed_$(date +%F).txt"

mkdir -p artifacts
cp "$REMOVED_FILE" "artifacts/removed_$(date +%F).txt"
