#!/bin/bash
# 会话层场景矩阵。以前这些场景是直接敲在命令行里的，跑完就没了。
#
# 每个场景一行：id~显示名~服务器参数~驱动参数~服务器日志标记
# id 只用 ASCII，当日志文件名。
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

ADDR="rtsp://127.0.0.1:8554/livestream/1/"
# 密码是 s3cr#t@pw。# 必须转义成 %23，否则会被当成 fragment；
# 密码里的 @ 不用转 —— userinfo 按最后一个 @ 切分。
ADDR_AUTH="rtsp://admin:s3cr%23t@pw@127.0.0.1:8554/livestream/1/"

SCENARIOS=(
  "base~基线（UDP 被 461 后退交织）~~~"
  "forced~直接交织~~--interleaved~"
  "udp~UDP 正常~--udp~~SETUP trackID=0: UDP"
  "auth~Digest 认证~--auth~~"
  "nortpinfo~无 RTP-Info~--no-rtpinfo~~"
  "srvreq~服务器主动探活~--server-request~~"
  # 服务器每个小块 sleep 0.5ms，1 字节一块就是约 2000 B/s。
  # 默认 5 秒窗口连第一个关键帧（7.5KB）都传不完，必须给长窗口。
  "chunk~TCP 逐字节切分~--chunk 1~--long~"
  "drop~中途断流~--drop-after 60~~dropping connection"
  "h265~H.265~--h265~~"
  "pcma~PCMA 音频轨~--pcma~~"
  "renumber~通道重编号~--renumber~~assigned 2"
  # 去掉音频之后这个场景已经退化成基线：客户端只 SETUP 视频，
  # 服务器只给视频分了通道，音频落到默认的 2，客户端压根不收。
  # 留着当回归，真正压串轨的是下面的 mismux。
  "samechan~两轨同通道（已退化）~--same-channel~~"
  "udpreply~SETUP 回默认 UDP Transport~--udp-reply~~回默认 UDP Transport"
  "notransport~SETUP 无 Transport 头~--no-transport~~"
  "noidr~从不发关键帧~--no-idr~~"
  "nodata~答应了却不推流~--no-data~~不发任何媒体数据"
  "oraimo~Oraimo 真实回放~--oraimo --udp~~SETUP trackID=0: UDP"
  # 记录仪：Content-Base 的路径和请求 URL 不同（还不带端口），
  # 客户端必须按它拼 control。拼错服务器回 404，见下面的对照行。
  "dashcam~记录仪真实回放（UDP）~--dashcam --udp~~Content-Base="
  "dashcam_tcp~记录仪真实回放（交织）~--dashcam~~Content-Base="
  "mismux_tcp~音频串进视频通道（交织）~--mismux~~mismux"
  "mismux_udp~音频串进视频端口（UDP）~--udp --mismux~~mismux"
  "mismux_pcma~PCMA 串进视频通道~--pcma --mismux~~mismux"
  # 对照实验：SDP 不声明音频，负载类型保护自动失效。
  # 同样的字节流应该解出多余的假帧、丢包数飙高 —— 证明上面几行
  # 通过不是「本来就没事」，而是保护真的挡住了。这两行预期就是坏的。
  "ctl_aac~对照：AAC 串轨且保护失效~--mismux --hide-audio-sdp~~mismux"
  "ctl_pcma~对照：PCMA 串轨且保护失效~--pcma --mismux --hide-audio-sdp~~mismux"
  # 对照实验：记录仪模式下扣掉 Content-Base，别的一个字不动。
  # 客户端只剩请求 URL 可用，于是拼出 /livestream/1/track1，服务器回 404。
  # **这一行必须报错** —— 它通过说明上面两行压根没在验基址。
  "ctl_nobase~对照：记录仪缺 Content-Base~--dashcam --udp --no-content-base~~对照组"
)

LOGS=$HERE/.build/mlogs
mkdir -p "$LOGS"
rm -f "$LOGS"/*.log

field() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }

# dropped 这一列必须有。AAC 串轨时保护失效不会多出假帧
#（AAC 负载头两字节是 00 10，NAL type 0 是 unspecified，解包器直接丢），
# 但音频的 RTP 序号会污染丢包统计。没有这一列，对照组看起来和通过一样。
printf '%-12s %-34s %8s %6s %6s %7s %8s %s\n' \
       ID 场景 帧数 关键帧 乱序 丢包 字节 备注
for row in "${SCENARIOS[@]}"; do
  IFS='~' read -r id name srv drv marker <<< "$row"
  addr="$ADDR"
  [ "$id" = "auth" ] && addr="$ADDR_AUTH"
  "$HERE/scenario.sh" session "$name" "$srv" "$addr" "$drv" "$marker" \
      > "$LOGS/$id.log" 2>&1
  vs=$(field "$LOGS/$id.log" video_samples)
  kf=$(field "$LOGS/$id.log" keyframes)
  nm=$(field "$LOGS/$id.log" non_monotonic_video)
  dp=$(field "$LOGS/$id.log" dropped)
  by=$(field "$LOGS/$id.log" bytes)
  err=$(field "$LOGS/$id.log" error)
  mk=$(grep -m1 "^server_marker=" "$LOGS/$id.log" | cut -d= -f2-)
  note=""
  [ -n "$err" ] && note="err=$err"
  [ -n "$mk" ] && note="$note marker=$mk"
  grep -q "测试无效" "$LOGS/$id.log" && note="$note 【无效】"
  printf '%-12s %-34s %8s %6s %6s %7s %8s %s\n' \
         "$id" "$name" "${vs:--}" "${kf:--}" "${nm:--}" "${dp:--}" "${by:--}" "$note"
done
