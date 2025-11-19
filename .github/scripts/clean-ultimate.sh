#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"

ORIGINAL="list.txt"
VALID="/tmp/valid.txt"
REMOVED="/tmp/removed.txt"
DEBUG="artifacts/debug_$(date +%Y%m%d).log"
RESULT_FILE="/tmp/parallel_results.txt"

mkdir -p artifacts
> "$VALID" > "$REMOVED" > "$DEBUG" > "$RESULT_FILE"
echo "0" > /tmp/removed_count

# 1. 解析源（同之前）
TMP="/tmp/to_check.txt"
> "$TMP"

echo "正在解析 live_ipv4.txt..." | tee -a "$DEBUG"
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue
  [[ $line == \#* ]] && { echo "$line" >> "$VALID"; continue; }

  if [[ $line =~ (https?://[^[:space:]]+|rtmp://[^[:space:]]+|rtsp://[^[:space:]]+) ]]; then
    url="${BASH_REMATCH[1]}"
    name="${line%%"$url"*}"
    name="${name%%,*}" ; name="${name%%\$*}" ; name=$(echo "$name" | xargs)
    [[ -z "$name" ]] && name="未知$(echo $url | md5sum | cut -c1-6)"
    echo "$url|||${name:-未知}|||$(echo "$line" | sed 's/|/PIPE/g')" >> "$TMP"
  fi
done < "$ORIGINAL"

TOTAL=$(wc -l < "$TMP")
echo "共 $TOTAL 条，开始防卡死并行检测（30 线程）..." | tee -a "$DEBUG"

# 2. 核心检测函数（加 UA + 双保险）
check_stream() {
  local url="$1"
  local orig="$3"

  # 第一招：ffmpeg 快速连通
  if timeout 18 ffmpeg -user_agent "$UA" -i "$url" -t 4 -f null - -y >/dev/null 2>&1; then
    echo "OK|$orig"
    return
  fi

  # 第二招：ffprobe 检查视频流
  if timeout 25 ffprobe -user_agent "$UA" -v error -select_streams v:0 \
      -show_entries stream=width,height -of csv=p=0 "$url" 2>/dev/null | grep -qE '^[0-9]+,[0-9]+$'; then
    echo "OK|$orig"
    return
  fi

  echo "FAIL|$orig"
}
export -f check_stream
export UA

# 3. 关键防卡死写法（不使用管道！）
#    --halt now,fail=1 一旦有子进程挂死立刻结束
#    -a 指定输入文件
#    --joblog 记录日志防止僵尸
parallel -j 30 \
  --bar \
  --halt now,fail=1 \
  --joblog /tmp/parallel_joblog.log \
  -a "$TMP" \
  check_stream {1} {2} {3} > "$RESULT_FILE"

# 4. 处理结果（从文件读，绝不卡）
while IFS= read -r res; do
  if [[ $res == OK* ]]; then
    echo "${res#OK|}" >> "$VALID"
  else
    echo "${res#FAIL|}" >> "$REMOVED"
    count=$(cat /tmp/removed_count)
    echo $((count+1)) > /tmp/removed_count
  fi
done < "$RESULT_FILE"

mv "$VALID" "$ORIGINAL"
REMOVED=$(cat /tmp/removed_count)

echo "==========================================" | tee -a "$DEBUG"
echo "检测完成！共 $TOTAL 条，剔除 $REMOVED 条（保留 $(($TOTAL-$REMOVED)) 条）" | tee -a "$DEBUG"
cp "$REMOVED" "artifacts/removed_$(date +%Y%m%d).txt"

echo "防卡死版本运行成功！新 list.txt 已生成" | tee -a "$DEBUG"
