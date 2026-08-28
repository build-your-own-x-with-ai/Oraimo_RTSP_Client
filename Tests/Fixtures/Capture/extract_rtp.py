#!/usr/bin/env python3
"""从真实抓包里抽 RTP 包，写成 fixture。

用法：
    python3 Capture/extract_rtp.py <抓包> <输出.rtp> [tshark 显示过滤器]

过滤器默认 `rtp`，多半还要加方向 —— 客户端也会往同一个端口发几个空包
（NAT 打洞），混进来会被当成畸形 RTP。所以实际都写成
`rtp && ip.src==<设备IP>`。

fixture 格式是「4 字节大端长度 + 包体」重复，包体是完整 RTP 包（含 12
字节头），和 Capture/capture*.py 写出来的一样，server.py 直接读。

**保持抓包顺序，不排序。** RTP 时间戳在有 B 帧的流里本就不单调，按它排会
打乱序号，客户端会误报大量丢包。

这个脚本和 capture*.py 不同：那几个是用 ffmpeg 现推一条流录下来，
这个是从已有的设备抓包里抽。设备不在手边时只有后者可用。
"""
import os
import shutil
import struct
import subprocess
import sys


def find_tshark():
    """tshark 不一定在 PATH 上。Wireshark 4.x 只往 app bundle 里装，
    /usr/bin/tshark 那个软链接已经没有了。"""
    found = shutil.which("tshark")
    if found:
        return found
    bundled = "/Applications/Wireshark.app/Contents/MacOS/tshark"
    if os.access(bundled, os.X_OK):
        return bundled
    sys.exit("找不到 tshark：PATH 上没有，也不在 Wireshark.app 里")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    pcap, out = sys.argv[1], sys.argv[2]
    display_filter = sys.argv[3] if len(sys.argv) > 3 else "rtp"

    tshark = find_tshark()
    # -Y 是读取过滤（要跑完整解析，RTP 得靠 RTSP 的 SETUP 才认得出来），
    # 不能用 -f 抓包过滤。
    result = subprocess.run(
        [tshark, "-r", pcap, "-Y", display_filter,
         "-T", "fields", "-e", "udp.payload"],
        capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"tshark 失败：{result.stderr.strip()}")

    packets = []
    for line in result.stdout.splitlines():
        hexbytes = line.strip().replace(":", "")
        if not hexbytes:
            continue
        # 一帧里可能有多条记录（tshark 用逗号分隔），各自都是一个包。
        for piece in hexbytes.split(","):
            if piece:
                packets.append(bytes.fromhex(piece))

    if not packets:
        sys.exit(f"过滤器 {display_filter!r} 一个包都没匹配上")

    with open(out, "wb") as f:
        for p in packets:
            f.write(struct.pack(">I", len(p)))
            f.write(p)

    # RTP 头的第 2 字节低 7 位是负载类型，第 3-4 字节是序号。
    # 打出来是为了当场核对抽对了流 —— 抽错方向会得到一堆 PT 不一致的包。
    pts = {p[1] & 0x7F for p in packets if len(p) >= 2}
    first_seq = struct.unpack(">H", packets[0][2:4])[0]
    last_seq = struct.unpack(">H", packets[-1][2:4])[0]
    print(f"{out}: {len(packets)} 个包，负载类型 {sorted(pts)}，"
          f"序号 {first_seq}..{last_seq}")


if __name__ == "__main__":
    main()
