#!/bin/bash
# 跑单元测试。
#
# 单独一个脚本只为一件事：驱动按相对路径读抓包，必须从 Fixtures 里跑。
# 直接敲 .build/unit 会静默少掉一批用例（读不到 video.sdp 就 return），
# 看起来还是「全部通过」。
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ ! -x "$HERE/.build/unit" ]; then
    echo "找不到 $HERE/.build/unit，先跑 Tests/build.sh" >&2
    exit 1
fi

cd "$HERE/Fixtures" || exit 1
exec "$HERE/.build/unit" "$@"
