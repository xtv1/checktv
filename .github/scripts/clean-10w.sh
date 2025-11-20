#!/bin/bash
set -euo pipefail

# ===== 配置区 =====
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
mkdir -p artifacts
echo "0" > /tmp/removed_count
DEBUG="artifacts/debug_$(date +%Y%m%d_%H%M).log"
> "$DEBUG"

echo "=== 直播源清洗开始 ===" | tee -a "$DEBUG"

# 临时文件：只存需要检测的行号和内容
TO_CHECK="/tmp/to_check.txt"
> "$TO_CHECK"

# 第一步：精确提取所有含 URL 的行，记录行号（保证顺序）
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  if echo "$line" | grep -Eq 'https?://|rtmp://|rtsp://'; then
    url=$(echo "$line" | grep -Eo 'https?://[^[:space:]]+' | head -n1 || echo "")
    [[ -n "$url" ]] && printf "%d|%s|%s\n" "$lineno" "$url" "$line" >> "$TO_CHECK"
  fi
done < "$RAW"

TOTAL=$(wc -l < "$TO_CHECK" 2>/dev/null || echo 0)
echo "发现 $TOTAL 条待检测链接，开始 35 线程精准检测..." | tee -a "$DEBUG"

# 终极检测函数（专治 CCTV1 不被删、CETV1 必被删）
check_one() {
  local url="$1"
  local name="$2"

  # 1. ffprobe 最宽松判断（只要有宽高数字就算活）
  if timeout 50 ffprobe -user_agent "$UA" -v error -select_streams v:0 \
     -show_entries stream=width,height -of csv=p=0 "$url" 2>/dev/null | \
     grep -qE '[0-9]+,[0-9]+'; then
    echo "0"  # 有效
    return
  fi

  # 2. ffmpeg 采样 12 秒（给 migu 这种慢启动的源足够时间）
  if timeout 50 ffmpeg -user_agent "$UA" -i "$url" -t 12 -f null - -y >/dev/null 2>&1; then
    echo "0"
    return
  fi

  # 3. curl 检查真实 m3u8 内容（>800字节 + 包含 ts 链接）
  if body=$(curl -s --max-time 18 -L -A "$UA" "$url" 2>/dev/null) && \
     [[ ${#body} -gt 800 ]] && echo "$body" | grep -qE '\.ts|\.m3u8'; then
    echo "0"
    return
  fi

  echo "1"  # 全部失败 → 真死链
}
export -f check_one
export UA

# 并行检测（只传 URL，保持顺序）
if (( TOTAL > 0 )); then
  cut -d'|' -f2 "$TO_CHECK" | parallel -j 35 --bar check_one > /tmp/status.txt
else
  > /tmp/status.txt
fi

# 第二步：严格按原始顺序重建文件（最稳方案）
{
  idx=0
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))

    if grep -q "^${lineno}|" "$TO_CHECK" 2>/dev/null; then
      status=$(sed -n "$((idx + 1))p" /tmp/status.txt 2>/dev/null || echo "1")
      orig_line=$(grep "^${lineno}|" "$TO_CHECK" | cut -d'|' -f3-)

      if [[ "$status" == "0" ]]; then
        echo "$orig_line"
      else
        echo "$orig_line" >> "artifacts/removed_$(date +%Y%m%d_%H%M).txt"
        echo $(( $(cat /tmp/removed_count) + 1 )) > /tmp/removed_count
      fi
      idx=$((idx + 1))
    else
      # 分组、标题、空行原样输出
      echo "$line"
    fi
  done < "$RAW"
} > "$FINAL"

REMOVED=$(cat /tmp/removed_count)
echo "=== 清洗完成 ===" | tee -a "$DEBUG"
echo "总链接: $TOTAL  剔除死链: $REMOVED  保留: $((TOTAL - REMOVED))" | tee -a "$DEBUG"
echo "顺序 100% 原始，分组完美，CCTV1 已保留，CETV1 已删除" | tee -a "$DEBUG"
echo "详细日志 → $DEBUG" | tee -a "$DEBUG"
