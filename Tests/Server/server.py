#!/usr/bin/env python3
"""最小 RTSP 服务器：回放抓包，用于端到端测试。

用法：server.py [--auth] [--speed N] [--no-rtpinfo] [--server-request] [-v]
"""
import hashlib, os, re, socket, struct, sys, threading, time

HOST, PORT = "127.0.0.1", 8554
# 抓包按自己的位置找，不按启动目录找 —— 从仓库任何地方
# `python3 Tests/Server/server.py` 都该能跑起来。
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Fixtures")
REALM = "TestCam"
NONCE = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"
USER, PASSWORD = "admin", "s3cr#t@pw"

REQUIRE_AUTH = "--auth" in sys.argv
VERBOSE = "-v" in sys.argv
SEND_RTPINFO = "--no-rtpinfo" not in sys.argv
SERVER_REQUEST = "--server-request" in sys.argv
SPEED = 1.0
if "--speed" in sys.argv:
    SPEED = float(sys.argv[sys.argv.index("--speed") + 1])
# --chunk N：把每次写出的数据切成 N 字节小块发送。
CHUNK = 0
if "--chunk" in sys.argv:
    CHUNK = int(sys.argv[sys.argv.index("--chunk") + 1])
# --drop-after N：发完 N 个包直接断开，测试重连路径。
DROP_AFTER = 0
if "--drop-after" in sys.argv:
    DROP_AFTER = int(sys.argv[sys.argv.index("--drop-after") + 1])


def log(*a):
    if VERBOSE:
        print("[server]", *a, file=sys.stderr, flush=True)


def load(name):
    path = os.path.join(FIXTURES, name)
    if not os.path.exists(path):
        print(f"抓包缺失：{path}", file=sys.stderr)
        sys.exit(2)
    data = open(path, "rb").read()
    pkts, i = [], 0
    while i + 4 <= len(data):
        n = struct.unpack(">I", data[i:i + 4])[0]
        i += 4
        if n <= 0 or i + n > len(data):
            break
        pkts.append(data[i:i + n])
        i += n
    return pkts


USE_H265 = "--h265" in sys.argv
USE_PCMA = "--pcma" in sys.argv
# --renumber：像某些摄像机那样忽略客户端请求的通道号，自己重新分配。
RENUMBER = "--renumber" in sys.argv
# --udp-reply：SETUP 回默认 UDP 的 Transport（不含 "UDP" 字面，也没有
# interleaved），模拟不肯走 TCP 交织却又回 200 的固件。
UDP_REPLY = "--udp-reply" in sys.argv
# --same-channel：两条轨都回同一个通道号，模拟固件 bug。
SAME_CHANNEL = "--same-channel" in sys.argv
# --no-transport：SETUP 回 200 但完全不带 Transport 头。
NO_TRANSPORT = "--no-transport" in sys.argv
# --no-idr：把视频里的 IDR NAL 类型改写成 1，模拟从不发关键帧的摄像机。
NO_IDR = "--no-idr" in sys.argv
# --no-data：握手全部成功，但 PLAY 之后一个媒体字节都不发，
# 只维持连接。复现「摄像机答应了却不推流」的死等场景。
NO_DATA = "--no-data" in sys.argv
# --udp：真的走 RTP over UDP。SETUP 只认 client_port，回的 Transport 照
# Oraimo 抓包原样 —— 只把 client_port 抄回来，不给 server_port 也不给 source。
# 收到 interleaved 请求就回 461，跟那台摄像机一样根本没有 TCP 交织这条路。
UDP_MODE = "--udp" in sys.argv
# --oraimo：回放那台摄像机的真实 RTP，连它的 SDP 一起。
# 关键帧是 FU-A 拼出来的单个 NAL，头上标着 type 7，里面其实是
# SPS + PPS + SEI + IDR 用 00 00 00 01 粘在一起。
ORAIMO = "--oraimo" in sys.argv
# --dashcam：回放那台行车记录仪（LIVE555）的真实 RTP，连它的 SDP 一起。
#
# 这个开关的要点不是流，是**基址**。真机用 /xxx.mov 收 DESCRIBE，应答里的
# Content-Base 却是另一条路径、而且不带端口。所以这里故意让三者都不一样：
#   请求 URL   rtsp://127.0.0.1:8554/livestream/1/
#   Content-Base rtsp://127.0.0.1/00000000/      ← 路径不同，端口也没了
#   media control track1                          ← 相对值
# 客户端必须发 SETUP rtsp://127.0.0.1/00000000/track1。按请求 URL 去拼会
# 得到 /livestream/1/track1，下面直接回 404 —— 不修 Content-Base 这行必挂。
#
# 基址不带端口是安全的：连接在 DESCRIBE 之前就建好了，Request-URI 只是
# 一个字符串，客户端不会照它重新拨号。真要有人改成重新拨号，这一行会以
# 连不上 127.0.0.1:554 的形式当场暴露，正是想要的。
DASHCAM = "--dashcam" in sys.argv
DASHCAM_BASE = "rtsp://127.0.0.1/00000000/"
DASHCAM_PATH = "/00000000/"
# --no-content-base：记录仪模式下把 Content-Base 那一行扣掉，别的一个字不动。
#
# --dashcam 的对照实验。客户端只能从这个头得知真正的基址；扣掉之后它只剩
# 请求 URL 可用，于是拼出 /livestream/1/track1，服务器 404。
# **这一行报错才是对的** —— 它通过说明 --dashcam 压根没在验基址。
NO_CONTENT_BASE = "--no-content-base" in sys.argv
# --udp-blackhole：UDP 的 SETUP 照样回 200，但一个 UDP 包都不发；
# 客户端改用交织重来时才真的推流。模拟 UDP 被防火墙吞掉的情况 ——
# 握手全绿、端口也谈成了，数据就是不到。
UDP_BLACKHOLE = "--udp-blackhole" in sys.argv
# --mismux：把音频包硬塞进视频的通道／端口，不管客户端有没有 SETUP 音频。
#
# 客户端不再 SETUP 音频之后，--same-channel 已经造不出串轨了（服务器只给
# 视频分了通道，音频落到默认的 2，客户端压根不收）。但真实固件是不管你
# SETUP 了什么的，照样往视频那一路发音频。客户端靠负载类型把它挡在
# H.264 解包器外面 —— 挡不住就会凭空多出假帧。这个开关专门压那条路。
MISMUX = "--mismux" in sys.argv
# --hide-audio-sdp：流里照发音频，但 SDP 里不声明音频轨。
#
# 这是 --mismux 的对照实验。客户端靠 SDP 里的音频负载类型来认出串轨的包；
# SDP 不声明，audioPayloadType 就是 -1，那道保护自动失效。
# 于是同样的字节流应该解出明显多余的假帧 —— 用来证明 --mismux 通过
# 不是因为「本来就没事」，而是因为保护真的挡住了。
HIDE_AUDIO_SDP = "--hide-audio-sdp" in sys.argv
if ORAIMO:
    VIDEO = load("oraimo_video.rtp")
elif DASHCAM:
    VIDEO = load("dashcam_video.rtp")
else:
    VIDEO = load("video_noidr.rtp" if NO_IDR else
                 ("video265.rtp" if USE_H265 else "video.rtp"))
if USE_H265 or ORAIMO or DASHCAM:
    # 两台真机在这里的情形并不相同，只是都没有音频包可发：
    # Oraimo 的音频没抓进那份文件，但 SDP 里照旧声明，客户端会 SETUP 然后
    # 一个包都收不到 —— 正好是真机上的样子。记录仪是真的只有视频一条轨，
    # SDP 里连 m=audio 都没有。
    AUDIO = []
elif USE_PCMA:
    AUDIO = load("audio_pcma.rtp")
else:
    AUDIO = load("audio.rtp")
AUDIO_CLOCK = 16000.0 if ORAIMO else (8000.0 if USE_PCMA else 48000.0)


def md5(s):
    return hashlib.md5(s.encode()).hexdigest()
def sdp():
    text = sdp_full()
    if HIDE_AUDIO_SDP:
        # 只砍掉 SDP 里的音频声明，音频照发。这个「声明与实际不一致」
        # 正是对照实验要的：客户端没有音频负载类型可比，保护失效。
        idx = text.find("m=audio")
        if idx >= 0:
            text = text[:idx]
    return text


def sdp_full():
    if ORAIMO:
        # 抓包里那台摄像机的 SDP，原样照抄。注意几处不常见的地方：
        # o= 行写的是 "IPV4"（规范是 IP4）、control 用 video/track0 这种
        # 两段相对路径、音频是 PCMA/16000 单声道（不是常见的 8000）。
        return ("v=0\r\n"
                "o=- 0 0 IN IPV4 127.0.0.1\r\n"
                "t=0 0\r\n"
                "s=SGK\r\n"
                "a=control:*\r\n"
                "c=IN IP4 127.0.0.1\r\n"
                "m=video 0 RTP/AVP 96\r\n"
                "a=rtpmap:96 H264/90000\r\n"
                "a=fmtp:96 profile-level-id=42001e; packetization-mode=1;"
                "sprop-parameter-sets=Z0IAHpY1QUB7TcBAQFAAAAMAEAAAAwPIQA==,aM4xsg==\r\n"
                "a=control:video/track0\r\n"
                "a=recvonly\r\n"
                "m=audio 0 RTP/AVP 97\r\n"
                "a=rtpmap:97 PCMA/16000/1\r\n"
                "a=control:audio/track1\r\n"
                "a=recvonly\r\n")
    if DASHCAM:
        # 抓包里那台记录仪的 SDP，原样照抄。要点：只有一条视频轨，
        # media control 是单段相对路径 track1，profile-level-id=640033
        # 是 High 5.1，b=AS:2000。参数集在流里每个 IDR 前还会重发一遍。
        return ("v=0\r\n"
                "o=- 1773205241250621 1 IN IP4 0.0.0.0\r\n"
                "s=Nvt RTSP, streamed by the LIVE555 Media Server\r\n"
                "i=00000000\r\n"
                "t=0 0\r\n"
                "a=tool:LIVE555 Streaming Media v2013.07.03\r\n"
                "a=type:broadcast\r\n"
                "a=control:*\r\n"
                "a=range:npt=0-\r\n"
                "m=video 0 RTP/AVP 96\r\n"
                "c=IN IP4 0.0.0.0\r\n"
                "b=AS:2000\r\n"
                "a=rtpmap:96 H264/90000\r\n"
                "a=fmtp:96 packetization-mode=1;profile-level-id=640033;"
                "sprop-parameter-sets=Z2QAM6wVFKDUPabgICAoAAAfQAAHUwAg,aO48sA==\r\n"
                "a=control:track1\r\n")
    head = ("v=0\r\n"
            "o=- 0 0 IN IP4 127.0.0.1\r\n"
            "s=Test Stream\r\n"
            "c=IN IP4 127.0.0.1\r\n"
            "t=0 0\r\n"
            "a=control:*\r\n")
    if USE_H265:
        # 故意不给 sprop-*，逼客户端从流内取 VPS/SPS/PPS。
        return (head +
                "m=video 0 RTP/AVP 96\r\n"
                "a=rtpmap:96 H265/90000\r\n"
                "a=control:trackID=0\r\n")
    if USE_PCMA:
        # 真实摄像机常见形态：PCMA 静态 payload，连 rtpmap 都省略。
        return (head +
                "m=video 0 RTP/AVP 96\r\n"
                "a=rtpmap:96 H264/90000\r\n"
                "a=fmtp:96 packetization-mode=1; "
                "sprop-parameter-sets=Z0LAHtkAoD2wEQAAAwABAAADADIPFi5I,aMuDyyA=\r\n"
                "a=control:trackID=0\r\n"
                "m=audio 0 RTP/AVP 8\r\n"
                "a=control:trackID=1\r\n")
    # 与抓包一致的两条轨，control 用相对路径（最常见的形式）。
    return (head +
            "m=video 0 RTP/AVP 96\r\n"
            "a=rtpmap:96 H264/90000\r\n"
            "a=fmtp:96 packetization-mode=1; "
            "sprop-parameter-sets=Z0LAHtkAoD2wEQAAAwABAAADADIPFi5I,aMuDyyA=\r\n"
            "a=control:trackID=0\r\n"
            "m=audio 0 RTP/AVP 97\r\n"
            "a=rtpmap:97 MPEG4-GENERIC/48000/2\r\n"
            "a=fmtp:97 profile-level-id=1;mode=AAC-hbr;sizelength=13;"
            "indexlength=3;indexdeltalength=3;config=119056E500\r\n"
            "a=control:trackID=1\r\n")


def check_auth(headers, method, uri):
    """校验 Digest。返回 True 表示通过。"""
    value = headers.get("authorization", "")
    if not value.lower().startswith("digest"):
        return False
    # k="v" 或 k=v 都要支持
    fields = {m[0]: (m[1] or m[2])
              for m in re.findall(r'(\w+)=(?:"([^"]*)"|([^,\s]+))', value)}
    if fields.get("username") != USER or fields.get("nonce") != NONCE:
        return False
    ha1 = md5(f"{USER}:{REALM}:{PASSWORD}")
    ha2 = md5(f"{method}:{fields.get('uri', uri)}")
    if fields.get("qop") == "auth":
        expect = md5(f"{ha1}:{NONCE}:{fields.get('nc','')}:"
                     f"{fields.get('cnonce','')}:auth:{ha2}")
    else:
        expect = md5(f"{ha1}:{NONCE}:{ha2}")
    ok = expect == fields.get("response")
    log("auth", method, "->", "ok" if ok else "reject")
    return ok


class Client(threading.Thread):
    def __init__(self, conn):
        super().__init__(daemon=True)
        self.conn = conn
        self.buf = b""
        self.session = "12345678"
        self.channels = {}          # trackID -> 起始通道
        self.udp_ports = {}         # trackID -> 客户端 RTP 端口
        self.streaming = False
        self.lock = threading.Lock()

    @property
    def session_header(self):
        """SETUP 应答里 Session 头的值。

        记录仪真机不带 timeout（LIVE555 就是这样，客户端得自己按默认 60 秒
        算保活间隔）。别的场景照旧带上 —— 有 timeout 时客户端按它算，
        这两条路都要有人走过。
        """
        return self.session if DASHCAM else f"{self.session};timeout=60"

    def send_raw(self, data):
        with self.lock:
            try:
                if CHUNK > 0:
                    # 故意切碎，模拟 TCP 任意分段，考验增量解析。
                    for i in range(0, len(data), CHUNK):
                        self.conn.sendall(data[i:i + CHUNK])
                        time.sleep(0.0005)
                else:
                    self.conn.sendall(data)
            except OSError:
                self.streaming = False

    def check_dashcam_base(self, method, uri, cseq):
        """记录仪模式下校验 Request-URI 是按 Content-Base 拼的。

        返回 False 表示已经回了错误，调用方要直接 return。

        这是 --dashcam 唯一的判据。真机就是这么挑的：拼错基址的 SETUP
        它回 404。这里照做，不然客户端拼错了照样能播，场景等于白测。
        """
        if DASHCAM_PATH in uri:
            return True
        log(f"{method} 用错基址：{uri}（应含 {DASHCAM_PATH}）→ 404")
        self.reply(cseq, "404 Stream Not Found")
        return False

    def reply(self, cseq, status="200 OK", headers=None, body=""):
        text = f"RTSP/1.0 {status}\r\nCSeq: {cseq}\r\n"
        for k, v in (headers or {}).items():
            text += f"{k}: {v}\r\n"
        payload = body.encode()
        if payload:
            text += f"Content-Length: {len(payload)}\r\n"
        text += "\r\n"
        self.send_raw(text.encode() + payload)

    def run(self):
        try:
            self.loop()
        except Exception as e:
            log("client error:", e)
        finally:
            self.streaming = False
            self.conn.close()

    def loop(self):
        while True:
            while b"\r\n\r\n" not in self.buf:
                chunk = self.conn.recv(4096)
                if not chunk:
                    return
                self.buf += chunk
            head, self.buf = self.buf.split(b"\r\n\r\n", 1)
            lines = head.decode(errors="replace").split("\r\n")
            start = lines[0]
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip().lower()] = v.strip()
            parts = start.split()
            if len(parts) < 2:
                return
            method, uri = parts[0].upper(), parts[1]
            cseq = headers.get("cseq", "0")
            body_len = int(headers.get("content-length", "0"))
            while len(self.buf) < body_len:
                self.buf += self.conn.recv(4096)
            self.buf = self.buf[body_len:]
            log("<-", method, uri)
            self.handle(method, uri, cseq, headers)

    def handle(self, method, uri, cseq, headers):
        if REQUIRE_AUTH and method != "OPTIONS":
            if not check_auth(headers, method, uri):
                self.reply(cseq, "401 Unauthorized", {
                    "WWW-Authenticate":
                        f'Digest realm="{REALM}", nonce="{NONCE}", qop="auth"'})
                return

        if method == "OPTIONS":
            self.reply(cseq, headers={
                "Public": "OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN, GET_PARAMETER"})
        elif method == "DESCRIBE":
            hdrs = {"Content-Type": "application/sdp"}
            if DASHCAM and not NO_CONTENT_BASE:
                # 这一行就是整个场景的题眼。路径和请求 URL 不同，端口也没有。
                hdrs = {"Content-Base": DASHCAM_BASE, **hdrs}
                log(f"DESCRIBE: Content-Base={DASHCAM_BASE}（与请求 URL {uri} 不同）")
            elif DASHCAM:
                log("DESCRIBE: 对照组，故意不发 Content-Base")
            self.reply(cseq, headers=hdrs, body=sdp())
        elif method == "SETUP":
            transport = headers.get("transport", "")
            if DASHCAM and not self.check_dashcam_base(method, uri, cseq):
                return
            # Oraimo 的 control 是 video/track0 / audio/track1 这种两段相对路径，
            # 不是 trackID=N。两种都要认出来。
            #
            # 记录仪必须排除在这个判断之外：它唯一的**视频**轨 control 就叫
            # track1。判成音频的后果在交织模式下看不出来（视频落到默认通道 0，
            # 正好是客户端要的），UDP 模式下却是视频一个包都不发 ——
            # port_of 里没有 trackID=0 的条目。
            is_audio = (not DASHCAM) and ("trackID=1" in uri or "track1" in uri)
            track = "trackID=1" if is_audio else "trackID=0"
            wants_udp = "interleaved" not in transport and "client_port" in transport
            if (UDP_MODE or UDP_BLACKHOLE) and wants_udp:
                m = re.search(r"client_port=(\d+)-(\d+)", transport)
                port = int(m.group(1))
                self.udp_ports[track] = port
                log(f"SETUP {track}: UDP client_port={port}")
                # 照抓包原样回：只把 client_port 抄回来，
                # 既不给 server_port 也不给 source。
                self.reply(cseq, headers={
                    "Session": self.session_header,
                    "Transport": f"RTP/AVP;unicast;client_port={port}-{port + 1}"})
                return
            if UDP_MODE:
                # 那台摄像机压根没有 TCP 交织这条路，交织请求一律 461。
                # blackhole 模式故意不走这里：它要的就是客户端换交织之后能成。
                log(f"SETUP {track}: 拒绝非 UDP 请求（{transport}）")
                self.reply(cseq, "461 Unsupported Transport")
                return
            m = re.search(r"interleaved=(\d+)-(\d+)", transport)
            if "TCP" not in transport.upper() or not m:
                self.reply(cseq, "461 Unsupported Transport")
                return
            if UDP_REPLY:
                # 回 200，但 Transport 是默认 UDP：没有 "UDP" 字面也没有
                # interleaved。客户端必须判为不支持，而不是当成成功。
                log(f"SETUP {track}: 回默认 UDP Transport")
                self.reply(cseq, headers={
                    "Session": self.session_header,
                    "Transport": "RTP/AVP;unicast;client_port=6970-6971"
                                 ";server_port=6970-6971"})
                return
            if NO_TRANSPORT:
                log(f"SETUP {track}: 不带 Transport 头")
                self.reply(cseq, headers={"Session": self.session_header})
                self.channels[track] = int(m.group(1))
                return
            if SAME_CHANNEL:
                assigned = 0                      # 两条轨都塞进 0-1
            elif RENUMBER:
                # 摄像机自行分配：视频 2-3，音频 4-5，无视客户端请求的号。
                assigned = 2 if track == "trackID=0" else 4
            else:
                assigned = int(m.group(1))
            self.channels[track] = assigned
            log(f"SETUP {track}: client asked {m.group(1)}, assigned {assigned}")
            self.reply(cseq, headers={
                "Session": self.session_header,
                "Transport": f"RTP/AVP/TCP;unicast;interleaved={assigned}-{assigned+1}"})
        elif method == "PLAY":
            if DASHCAM and not self.check_dashcam_base(method, uri, cseq):
                return
            hdrs = {"Session": self.session}
            if SEND_RTPINFO:
                # 各轨的首包时间戳，客户端靠这个对齐音视频。
                parts = []
                if VIDEO:
                    vts = struct.unpack(">I", VIDEO[0][4:8])[0]
                    # 记录仪的轨名就是 control 的值，不是 trackID=N。
                    vtrack = "track1" if DASHCAM else "trackID=0"
                    parts.append(f"url={uri}{vtrack};seq=1;rtptime={vts}")
                if AUDIO:
                    ats = struct.unpack(">I", AUDIO[0][4:8])[0]
                    parts.append(f"url={uri}trackID=1;seq=1;rtptime={ats}")
                if parts:
                    hdrs["RTP-Info"] = ",".join(parts)
            self.reply(cseq, headers=hdrs)
            if not self.streaming:
                self.streaming = True
                threading.Thread(target=self.stream, daemon=True).start()
            if SERVER_REQUEST:
                # 模拟设备反向探活，客户端必须回 200。
                threading.Timer(0.4, lambda: self.send_raw(
                    b"OPTIONS * RTSP/1.0\r\nCSeq: 9001\r\n\r\n")).start()
        elif method in ("PAUSE", "GET_PARAMETER", "SET_PARAMETER"):
            self.reply(cseq, headers={"Session": self.session})
        elif method == "TEARDOWN":
            self.streaming = False
            self.reply(cseq, headers={"Session": self.session})
        else:
            self.reply(cseq, "501 Not Implemented")

    def interleave(self, channel, payload):
        return b"$" + bytes([channel]) + struct.pack(">H", len(payload)) + payload

    def stream(self):
        """按时间戳节奏交错发送两轨，模拟真实推流。"""
        if NO_DATA:
            # 答应了 PLAY 却不推流，连接留着不断。
            log("PLAY 之后不发任何媒体数据")
            while True:
                time.sleep(0.5)
        # blackhole：这条连接谈成的是 UDP（有 client_port、没有交织通道），
        # 那就一个包都不发。客户端换交织重连时是一条新连接、一个新 Client 实例，
        # udp_ports 是空的、channels 有值，于是走到下面正常推流。
        if UDP_BLACKHOLE and self.udp_ports and not self.channels:
            log("blackhole：UDP 谈成了但不发任何包")
            while True:
                if not self.streaming:
                    return
                time.sleep(0.2)
        vch = self.channels.get("trackID=0", 0)
        ach = self.channels.get("trackID=1", 2)
        if MISMUX:
            # 音频硬塞进视频那一路，客户端有没有 SETUP 音频都一样。
            ach = vch
            log(f"mismux：音频也发到视频通道 {vch}")
        # 两段抓包各自有随机起始时间戳，必须先按各自的首包归零，
        # 否则排序会把一整轨排到另一轨后面。
        # 关键：轨内必须保持抓包顺序。H.265 有 B 帧，时间戳(PTS)本身不单调，
        # 直接按时间戳排序会打乱 RTP 序号，客户端会误判成丢包。
        # 这里用「时间戳的运行最大值」当发送节奏键：轨内非递减，
        # 配合稳定排序即可保序，跨轨仍按时间交错。
        def schedule(packets, clock, channel):
            if not packets:
                return []
            base = struct.unpack(">I", packets[0][4:8])[0] / clock
            out, peak = [], 0.0
            for p in packets:
                rel = struct.unpack(">I", p[4:8])[0] / clock - base
                peak = max(peak, rel)
                out.append((peak, channel, p))
            return out

        items = schedule(VIDEO, 90000.0, vch) + schedule(AUDIO, AUDIO_CLOCK, ach)
        items.sort(key=lambda x: x[0])          # 稳定排序，轨内顺序不变

        # UDP 模式：往客户端 SETUP 时报的 client_port 发。
        # 源端口交给内核随便挑 —— 真机就是这样（抓包里是 32970，
        # 而 SETUP 应答里压根没提过这个号），客户端不能依赖它。
        udp = None
        port_of = {}
        if UDP_MODE:
            udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            peer = self.conn.getpeername()[0]
            if "trackID=0" in self.udp_ports:
                port_of[vch] = (peer, self.udp_ports["trackID=0"])
            if "trackID=1" in self.udp_ports:
                port_of[ach] = (peer, self.udp_ports["trackID=1"])
            log(f"UDP 推流目标 {port_of}")

        def emit(channel, payload):
            if udp is None:
                self.send_raw(self.interleave(channel, payload))
                return
            target = port_of.get(channel)
            if target:
                try:
                    udp.sendto(payload, target)
                except OSError:
                    pass

        base = 0.0
        start = time.time()
        sent = 0
        for offset, channel, payload in items:
            if not self.streaming:
                break
            target = (offset - base) / SPEED
            delay = target - (time.time() - start)
            if delay > 0:
                time.sleep(delay)
            emit(channel, payload)
            sent += 1
            if DROP_AFTER and sent >= DROP_AFTER:
                log("dropping connection after", sent, "packets")
                self.streaming = False
                try:
                    self.conn.close()
                except OSError:
                    pass
                break
        log(f"streamed {sent} packets")
        print(f"STREAM_DONE {sent}", flush=True)


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(5)
    print(f"READY {HOST}:{PORT} video={len(VIDEO)} audio={len(AUDIO)} "
          f"auth={REQUIRE_AUTH} chunk={CHUNK} drop_after={DROP_AFTER} "
          f"speed={SPEED} pcma={USE_PCMA} renumber={RENUMBER}", flush=True)
    while True:
        conn, addr = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        log("connect from", addr)
        Client(conn).start()


if __name__ == "__main__":
    main()
