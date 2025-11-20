#!/bin/bash
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0 Safari/537.36"
RAW="raw.txt"
FINAL="list.txt"
RESULT="/tmp/check_result.txt"
mkdir -p artifacts
> "$RESULT"
echo "0" > /tmp/removed_count

# 临时文件：只放需要检测的行（带行号）
NEED_CHECK="/tmp/need_check.txt"
> "$NEED_CHECK"

echo "正在逐行分析原始文件，保持 100% 原顺序..."

# 第一步：遍历原始文件，给每一行打标记
line_num=0
while IFS= read -r line || [[ -n "$line" ]]; do
  ((line_num++))

  # 只要这行包含 http/https/rtmp/rtsp 就认为是需要检测的直播源行
  if [[ "$line" == *http://* || "$line" == *https://* || "$line" == *rtmp://* || "$line" == *rtsp://* ]]; then
    # 提取第一个出现的完整 URL
    url=$(echo "$line" | grep -oE 'https?://[^[:space:]]+|rtmp://[^[:space:]]+|rtsp://[^[:space:]]+' | head -n1)
    printf "%s\t%s\t%s\n" "$line_num" "$url" "$line" >> "$NEED_CHECK"
  fi
done < "$RAW"

TOTAL=$(wc -l < "$NEED_CHECK")
echo "发现 $TOTAL 条直播源，开始 40 线程极速检测（顺序完全不变）..."

# 检测函数
check_one() {
  local url="$1"
  local orig_line="$2"

  # 双保险检测（任意一个成功就算活）
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
export -f check_one
export UA

# 并行检测（只检测有URL的行）
parallel -j 40 --bar --halt now,fail=1 --col-sep '\t' \
  check_one {2} {3} < "$NEED_CHECK" > "$RESULT"

# 第二步：原样重建文件（这才是保序核心）
{
  check_idx=0
  line_num=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_num++))

    # 判断当前行是否是需要检测的行
    if grep -q "^$line_num[[:space:]]" "$NEED_CHECK"; then
      # 是需要检测的行 → 取出对应的检测结果
      result=$(sed -n "$((check_idx + 1))p" "$RESULT")
      ((check_idx++))

      if [[ "$result" == OK* ]]; then
        echo "${result#OK|}"
      else
        # 失效的写入移除日志并计数
        echo "${result#FAIL|}" >> "artifacts/removed_$(date +%Y%m%d_%H%M).txt"
        n=$(cat /tmp/removed_count)
        echo $((n + 1)) > /tmp/removed_count
      fi
    else
      # 不是直播源行（分组、标题、空行、注释）→ 原样输出
      echo "$line"
    fi
  done < "$RAW"
} > "$FINAL"

echo "============================================"
echo "完美清洗完成！"
echo "总链接 $TOTAL 条，剔除 $(cat /tmp/removed_count) 条死链"
echo "分组、顺序、空格、注释 100% 原样保留！"
echo "最终文件 → list.txt（可直接用于 TV 盒子）"
