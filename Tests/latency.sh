#!/bin/bash
# 量预缓冲摊进端到端延迟的那一段，并和改动前的 250ms 对照。
#
# 不需要服务器：抓包直接喂给真的 MediaRenderer，按 PTS 配速，
# 量每帧送进渲染器那一刻 PTS 比当前播放时刻晚多少。那个差值就是延迟。
#
# 两条流都要跑。H.264 那条没有 B 帧，量的是收益；
# H.265 那条乱序 120ms，量的是自适应预缓冲有没有把乱序装下 ——
# late_frames 必须是 0，否则帧送进去时 PTS 已经过去了，画面会顿。
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for b in latency latency_old; do
    if [ ! -x "$HERE/.build/$b" ]; then
        echo "找不到 $HERE/.build/$b，先跑 Tests/build.sh" >&2
        exit 1
    fi
done

cd "$HERE/Fixtures" || exit 1
run() { "$HERE/.build/$1" "$2" ${3:-} | grep -E "added_latency_mean_ms|max_reorder_ms|late_frames"; }

echo "=== H.264（无 B 帧，量收益）==="
echo "--- 现行（自适应，从 80ms 起步）"
run latency current
echo "--- 对照（固定 250ms）"
run latency_old baseline

echo
echo "=== H.265（乱序 120ms，量乱序装不装得下）==="
echo "--- 现行（自适应）"
run latency current-h265 --h265
echo "--- 对照（固定 250ms）"
run latency_old baseline-h265 --h265
