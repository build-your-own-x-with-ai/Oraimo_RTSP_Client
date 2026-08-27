#!/bin/bash
# 编译全部测试驱动到 Tests/.build/。
#
# 这些测试不是 XCTest，是直接把 App 的源文件和一个 main.swift 一起 swiftc。
# 原因在 README 里：端到端场景要起真的 Python 服务器、连真的 socket，
# 挂在 Xcode test target 下面反而更难跑。
#
# 源文件用通配符展开 —— 以前 swiftc 命令是直接敲在命令行里的，
# 删掉一个源文件之后那个文件名还留在命令里反复报错，才落成脚本。
set -eu

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$HERE/../RTSPClient
OUT=$HERE/.build
mkdir -p "$OUT"

if [ ! -d "$SRC/Core" ]; then
    echo "找不到 App 源码：$SRC" >&2
    exit 1
fi

CORE=("$SRC"/Core/*.swift)
MEDIA=("$SRC"/Media/*.swift)
STORAGE=("$SRC"/Storage/*.swift)
# VideoLayerView 是 SwiftUI 的 NSViewRepresentable，命令行驱动用不到。
# 会话层和延迟驱动只要 MediaRenderer（为了 isKeyframeSample 这个扩展）；
# 带上 RTSPPlayer 会连累 Storage 一起要，没必要。
RENDERER=("$SRC"/Player/MediaRenderer.swift)
PLAYER=("${RENDERER[@]}" "$SRC"/Player/RTSPPlayer.swift)

FLAGS=(-swift-version 5 -sdk "$(xcrun --show-sdk-path --sdk macosx)")

echo "--- 单元测试 unit"
swiftc "${FLAGS[@]}" -o "$OUT/unit" "$HERE/Unit/main.swift" \
    "${CORE[@]}" "${MEDIA[@]}" "${STORAGE[@]}"

echo "--- 会话层 session"
swiftc "${FLAGS[@]}" -o "$OUT/session" "$HERE/SessionDriver/main.swift" \
    "${CORE[@]}" "${MEDIA[@]}" "${RENDERER[@]}"

echo "--- 播放器层 player"
swiftc "${FLAGS[@]}" -o "$OUT/player" "$HERE/PlayerDriver/main.swift" \
    "${CORE[@]}" "${MEDIA[@]}" "${PLAYER[@]}" "${STORAGE[@]}"

echo "--- 延迟测量 latency（现行 preroll）"
swiftc "${FLAGS[@]}" -o "$OUT/latency" "$HERE/LatencyDriver/main.swift" \
    "${CORE[@]}" "${MEDIA[@]}" "${RENDERER[@]}"

# 对照组：把预缓冲改回改动前的 250ms，别的一个字不动。
# 不碰仓库里的源文件 —— 复制出来打补丁再编。
# 补丁必须验证打上了：常量写法一变，sed 静默失配，
# 两个二进制就会一模一样，对照实验无声失效还看起来「通过」。
echo "--- 延迟测量 latency_old（对照 preroll=250ms）"
mkdir -p "$OUT/patched"
sed 's/CMTime(value: 80, timescale: 1000)/CMTime(value: 250, timescale: 1000)/' \
    "$SRC"/Player/MediaRenderer.swift > "$OUT/patched/MediaRenderer.swift"
if ! grep -q "value: 250" "$OUT/patched/MediaRenderer.swift"; then
    echo "补丁没打上：preroll 常量的写法变了，对照实验无效" >&2
    exit 1
fi
swiftc "${FLAGS[@]}" -o "$OUT/latency_old" "$HERE/LatencyDriver/main.swift" \
    "${CORE[@]}" "${MEDIA[@]}" "$OUT/patched/MediaRenderer.swift"

echo "--- 全部编译完成 → $OUT"
