#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"

ORIGINAL="list.txt"
VALID="/tmp/valid.txt"
REMOVED="/tmp/removed.txt"
DEBUG="artifacts/debug_$(date +%Y%m%d).log"
mkdir -p artifacts
> "$VALID" > "$REMOVED" > "$DEBUG"
echo "0" > /tmp/removed_count

TMP="/tmp/to_check.txt"
> "$TMP"

echo "正在智能解析 live_ipv4.txt（支持 $ 分隔）..." | tee -a "$DEBUG"
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue
  [[ $line == \#* ]] && { echo "$line" >> "$VALID"; continue; }

  # 精准提取第一个 http/https/rtmp/rtsp 链接
  if [[ $line =~ (https?://[^[:space:]]+|rtmp://[^[:space:]]+|rtsp://[^[:space:]]+) ]]; then
    url="${BASH_REMATCH[1]}"
    name="${line%%"$url"*}"
    name="${name%%,*}" ; name="${name%%\$*}" ; name=$(echo "$name" | xargs)  # trim
    [[ -z "$name" ]] && name="未知频道$(echo $url | md5sum | cut -c1-6)"
    echo "$url|||${name:-未知}|||$(echo "$line" | sed 's/|/PIPE/g')" >> "$TMP"
  fi
done < "$ORIGINAL"

TOTAL=$(wc -l < "$TMP")
echo "共 $TOTAL 条待检测，开始 30 线程检测（已伪装浏览器 UA）..." | tee -a "$DEBUG"

check_stream() {
  local url="$1"
  local name="$2"
  local orig="$3"

  # 第一步：快速连通性测试（带 UA）
  if timeout 15 ffmpeg -user_agent "$UA" -i "$url" -t 4 -f null - -y >/dev/null 2>&1; then
    echo "OK|$orig"
    return
  fi

  # 第二步：再给一次机会，用 ffprobe 详细检查（很多源 ffmpeg 连不上但 ffprobe 能）
  if timeout 30 ffprobe -user_agent "$UA" -v error -select_streams v:0 \
      -show_entries stream=width,height -of csv=p=0 "$url" 2>/dev/null | grep -qE '^[0-9]+,[0-9]+$'; then
    echo "OK|$orig"
    return
  fi

  echo "FAIL|$orig"
}

export -f check_stream
export UA

cat "$TMP" | parallel -j 30 --bar --line-buffer \
  'line={}; url=$(echo $line|cut -d"|" -f1); name=$(echo $line|cut -d"|" -f2); orig=$(echo $line|cut -d"|" -f4- | sed "s/PIPE/|/g"); check_stream "$url" "$name" "$orig"' | \
while IFS= read -r res; do
  if [[ $res == OK* ]]; then
    echo "${res#OK|}" >> "$VALID"
  else
    echo "${res#FAIL|}" >> "$REMOVED"
    count=$(cat /tmp/removed_count)
    echo $((count+1)) > /tmp/removed_count
  fi
done

mv "$VALID" "$ORIGINAL"
REMOVED=$(cat /tmp/removed_count)

echo "==========================================" | tee -a "$DEBUG"
echo "检测完毕！共 $TOTAL 条，剔除 $REMOVED 条失效源（保留 $(($TOTAL - $REMOVED)) 条）" | tee -a "$DEBUG"
cp "$REMOVED" "artifacts/removed_$(date +%Y%m%d).txt"

echo "干净的 list.txt 已生成！被移除的源已打包为 artifact" | tee -a "$DEBUG"
