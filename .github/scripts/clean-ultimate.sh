#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"

ORIGINAL="list.txt"
VALID="/tmp/valid.txt"
REMOVED="/tmp/removed.txt"
DEBUG="artifacts/debug_$(date +%Y%m%d).log"
RESULT="/tmp/parallel_result.txt"

mkdir -p artifacts
: > "$VALID" > "$REMOVED" > "$DEBUG" > "$RESULT"
echo "0" > /tmp/removed_count

TMP_INPUT="/tmp/input.txt"
: > "$TMP_INPUT"

echo "开始解析直播源..." | tee -a "$DEBUG"
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue
  [[ "$line" == \#* ]] && { echo "$line" >> "$VALID"; continue; }

  if [[ $line =~ (https?://[^[:space:]]+|rtmp://[^[:space:]]+|rtsp://[^[:space:]]+) ]]; then
    url="${BASH_REMATCH[1]}"
    name="${line%%"$url"*}"; name="${name%%,*}"; name="${name%%\$*}"; name=$(echo "$name" | xargs)
    [[ -z "$name" ]] && name="未命名"
    echo -e "$url\t$name\t$line" >> "$TMP_INPUT"
  fi
done < "$ORIGINAL"

TOTAL=$(wc -l < "$TMP_INPUT")
echo "共 $TOTAL 条，开始 30 线程检测（已加 User-Agent）..." | tee -a "$DEBUG"

check_one() {
  local url="$1"
  local line="$3"

  # 1. ffmpeg 快速试播 4 秒
  if timeout 18 ffmpeg -user_agent "$UA" -i "$url" -t 4 -f null - -y >/dev/null 2>&1; then
    echo "OK|$line"
    return
  fi

  # 2. ffprobe 检查是否有视频轨道
  if timeout 25 ffprobe -user_agent "$UA" -v error -select_streams v:0 \
      -show_entries stream=width,height -of csv=p=0 "$url" 2>/dev/null \
      | grep -qE '^[0-9]+,[0-9]+$'; then
    echo "OK|$line"
    return
  fi

  echo "FAIL|$line"
}
export -f check_one
export UA

# 防卡死核心写法
parallel -j 30 --bar --halt now,fail=1 --col-sep '\t' \
  check_one {1} {2} {3} \
  < "$TMP_INPUT" > "$RESULT"

# 处理结果
while IFS= read -r r; do
  if [[ $r == OK* ]]; then
    echo "${r#OK|}" >> "$VALID"
  else
    echo "${r#FAIL|}" >> "$REMOVED"
    n=$(cat /tmp/removed_count)
    echo $((n+1)) > /tmp/removed_count
  fi
done < "$RESULT"

# 替换原文件
mv "$VALID" "$ORIGINAL"

REMOVED_COUNT=$(cat /tmp/removed_count)
echo "==========================================" | tee -a "$DEBUG"
echo "检测完成！共 $TOTAL 条，剔除 $REMOVED_COUNT 条，保留 $((TOTAL - REMOVED_COUNT)) 条" | tee -a "$DEBUG"

# 正确复制被移除列表（修复上一版的致命 bug）
cp "$REMOVED" "artifacts/removed_$(date +%Y%m%d).txt"

echo "干净的 list.txt 已生成，被移除列表已保存到 artifacts" | tee -a "$DEBUG"
