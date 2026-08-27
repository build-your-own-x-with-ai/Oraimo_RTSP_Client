#!/bin/bash
# 跑一个端到端场景：起服务器、跑驱动、确认参数真的生效。
#
# 用法: scenario.sh <驱动> "<场景名>" "<服务器参数>" "<地址>" "<驱动参数>" "<日志标记>"
#   驱动 = session（会话层，直接开 RTSPSession）
#        | player （播放器层，走 RTSPPlayer，能覆盖换传输重连）
#
# 之前踩过的坑：陈旧的 server.py 还占着 8554 时，新起的进程直接退出，
# 于是 --drop-after 之类的参数根本没生效，测试却「通过」了。
# 所以这里三件事都要确认：端口先是空的、新进程活着、
# 跑完服务器日志里出现了该参数的标记。少一件，结论就不可信。
set -u

DRIVER="$1"; NAME="$2"; SRVARGS="${3:-}"
ADDR="${4:-rtsp://127.0.0.1:8554/livestream/1/}"
DRVARGS="${5:-}"; MARKER="${6:-}"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=$HERE/.build/$DRIVER
LOG=$HERE/.build/server_run.log

if [ ! -x "$BIN" ]; then
    echo "### $NAME: 找不到驱动 $BIN，先跑 Tests/build.sh，测试无效"; exit 1
fi

# 匹配 "server.py" 而不是 "python3 server.py"：Homebrew 的 python3 是个符号链接，
# 进程命令行里是解析后的绝对路径（.../MacOS/Python server.py），
# 带 python3 的那个模式一个也匹配不上，这道清理其实一直是空转。
pkill -f "server.py" 2>/dev/null
for _ in $(seq 1 60); do
  nc -z 127.0.0.1 8554 2>/dev/null || break
  sleep 0.1
done
if nc -z 127.0.0.1 8554 2>/dev/null; then
  echo "### $NAME: 端口 8554 仍被占用，测试无效"; exit 1
fi

# shellcheck disable=SC2086
python3 "$HERE/Server/server.py" $SRVARGS -v > "$LOG" 2>&1 &
SRVPID=$!
for _ in $(seq 1 60); do
  nc -z 127.0.0.1 8554 2>/dev/null && break
  sleep 0.1
done
if ! nc -z 127.0.0.1 8554 2>/dev/null; then
  echo "### $NAME: 服务器没起来，测试无效"; cat "$LOG"; exit 1
fi
if ! ps -p $SRVPID > /dev/null 2>&1; then
  echo "### $NAME: 服务器已退出，测试无效"; cat "$LOG"; exit 1
fi

echo "=== $NAME ==="
# 驱动按相对路径读抓包，所以从 Fixtures 里跑。
# shellcheck disable=SC2086
(cd "$HERE/Fixtures" && "$BIN" "$ADDR" $DRVARGS)

if [ -n "$MARKER" ]; then
  if grep -q "$MARKER" "$LOG"; then
    echo "server_marker=命中"
  else
    echo "server_marker=缺失（参数没生效，结论不可信）"
  fi
fi
kill $SRVPID 2>/dev/null
wait $SRVPID 2>/dev/null
exit 0
