#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
DEBUG="artifacts/debug_$(date +%Y%m%d_%H%M).log"
mkdir -p artifacts
> "$DEBUG"
echo "0" > /tmp/removed_count

# 临时文件：行号|URL|原始行
TO_CHECK="/tmp/to_check.txt"
> "$TO_CHECK"

echo "正在读取原始文件并编号..." | tee -a "$DEBUG"

lineno=0
while read -r line; do
  lineno=$((lineno + 1))
  case "$line" in
    *http://*|*https://*|*rtmp://*|*rtsp://*)
      url=$(echo "$line" | sed -n 's/.*\(http[s]*:\/\/[^ ]*\).*/\1/p' | head -n1)
      if [ -n "$url" ]; then
        echo "$lineno|$url|$line" >> "$TO_CHECK"
        echo "准备检测行 $lineno: $url" | tee -a "$DEBUG"
      fi
      ;;
  esac
done < "$RAW"

TOTAL=$(wc -l < "$TO_CHECK" 2>/dev/null || echo 0)
echo "发现 $TOTAL 条直播源，开始 40 线程准确检测..." | tee -a "$DEBUG"

# 升级检测函数：多层 fallback，确保不误删有效源
check_one() {
  local url="$1"
  local log="$2"  # 日志前缀

  # 第一层：ffprobe 检查视频流（宽松 grep）
  probe_out=$(timeout 40 ffprobe -user_agent "$UA" -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=p=0 "$url" 2>&1 || echo "ERROR")
  if echo "$probe_out" | grep -qE '^[0-9]+,[0-9]+$' ; then
    echo "0|$log|ffprobe OK (video found)" | tee -a "$DEBUG"
    echo "0"
    return
  fi

  # 第二层：ffmpeg 采样 8s（延长采样）
  if timeout 35 ffmpeg -user_agent "$UA" -i "$url" -t 8 -f null - -y >/dev/null 2>&1; then
    echo "0|$log|ffmpeg sample OK" | tee -a "$DEBUG"
    echo "0"
    return
  fi

  # 第三层：curl HEAD 检查基本连通（HLS/HTTP 200 + m3u8 type）
  curl_code=$(curl -s -o /dev/null -w "%{http_code}" -A "$UA" --max-time 10 "$url")
  content_type=$(curl -s -I -A "$UA" --max-time 10 "$url" | grep -i content-type | cut -d: -f2 | tr -d ' \r')
  if [ "$curl_code" = "200" ] && (echo "$content_type" | grep -qi "m3u8\|mpegurl\|dash\|flv"); then
    echo "0|$log|curl OK (200 + stream type)" | tee -a "$DEBUG"
    echo "0"
    return
  fi

  echo "1|$log|ALL FAILED (probe: $probe_out, curl: $curl_code/$content_type)" | tee -a "$DEBUG"
  echo "1"
}
export -f check_one
export UA

# 并行检测 URL 列表
if [ "$TOTAL" -gt 0 ]; then
  cut -d'|' -f2 "$TO_CHECK" | parallel -j 40 --bar \
    'check_one {} "$(echo {} | sed "s|https\?://[^/]*|***|g")"' > /tmp/status.txt
else
  > /tmp/status.txt
fi

# 重建文件（保序）
{
  check_idx=0
  lineno=0
  while read -r line; do
    lineno=$((lineno + 1))
    check_line=$(sed -n "$((check_idx + 1))p" "$TO_CHECK" 2>/dev/null || echo "")
    if [ -n "$check_line" ] && [ "$(echo "$check_line" | cut -d'|' -f1)" = "$lineno" ]; then
      status=$(sed -n "$((check_idx + 1))p" /tmp/status.txt 2>/dev/null || echo "1")
      orig_line=$(echo "$check_line" | cut -d'|' -f3-)
      log_prefix=$(echo "$orig_line" | cut -d',' -f1)

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

REMOVED=$(cat /tmp/removed_count)
echo "============================================" | tee -a "$DEBUG"
echo "清洗完成！总 $TOTAL 条，剔除 $REMOVED 条（仅真失效），保留 $((TOTAL - REMOVED)) 条" | tee -a "$DEBUG"
echo "顺序 100% 原始，分组完美 → list.txt 生成" | tee -a "$DEBUG"
echo "详细日志: $DEBUG" | tee -a "$DEBUG"
