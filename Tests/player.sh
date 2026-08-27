#!/bin/bash
# 播放器层场景。会话层驱动看到 error=udpNoData 就结束了；
# 把那个错误变成「换交织重连、真的出画面」的逻辑在 RTSPPlayer 里，
# 只有从这一层驱动才覆盖得到。
#
# 三个场景对应三条不同的恢复路径，判据是 state_path 和 reconnect_attempts
# 一起看 —— 单看重连次数分不出「换传输重来」和「退避重连」。
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ADDR="rtsp://127.0.0.1:8554/livestream/1/"

# UDP 全程被吞：握手全绿、端口也谈成了，数据就是不到。
# 期望 state_path 里出现第二段 connecting（换交织重来），
# 且 reconnect_attempts=-（不是退避重连那条路）。
"$HERE/scenario.sh" player "UDP 黑洞 → 换交织" "--udp-blackhole" "$ADDR" "" "blackhole"
echo

# 对照：UDP 正常。期望一次 connecting 就直达 playing。
"$HERE/scenario.sh" player "UDP 正常（对照）" "--udp" "$ADDR" "" "SETUP trackID=0: UDP"
echo

# 连接中途真的断掉。这条压的是退避重连，
# 期望 reconnect_attempts 有值 —— 和上面两条区分开。
"$HERE/scenario.sh" player "中途断流 → 退避重连" "--drop-after 60" "$ADDR" "--long" \
    "dropping connection"
