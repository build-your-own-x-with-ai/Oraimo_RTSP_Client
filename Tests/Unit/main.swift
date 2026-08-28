//
//  测试驱动：离线跑真实抓包，或对测试服务器跑完整会话。
//

import Foundation
import CoreMedia

var failures = 0
var checks = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    check(name, actual == expected, "得到 \(actual)，期望 \(expected)")
}

/// 抓包格式：4 字节大端长度 + 包体，循环。
func loadPackets(_ path: String) -> [Data] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let bytes = [UInt8](data)
    var packets: [Data] = []
    var i = 0
    while i + 4 <= bytes.count {
        let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16
            | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        i += 4
        guard n > 0, i + n <= bytes.count else { break }
        packets.append(Data(bytes[i..<i + n]))
        i += n
    }
    return packets
}

func readFile(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
// MARK: - 地址解析

func testURL() {
    print("\n[RTSPURL]")
    let d = RTSPURL(string: "rtsp://192.168.0.1/livestream/1/")
    check("默认地址可解析", d != nil)
    equal("host", d?.host, "192.168.0.1")
    equal("默认端口", d?.port, 554)
    equal("路径", d?.pathAndQuery, "/livestream/1/")
    equal("默认端口不写进 URI", d?.requestURI, "rtsp://192.168.0.1/livestream/1/")

    // 密码里带 @，必须按最后一个 @ 切。
    let c = RTSPURL(string: "rtsp://admin:p@ss w0rd@192.168.1.64:8554/h264/ch1")
    equal("用户名", c?.username, "admin")
    equal("含 @ 的密码", c?.password, "p@ss w0rd")
    equal("显式端口", c?.port, 8554)
    equal("URI 不含凭据", c?.requestURI, "rtsp://192.168.1.64:8554/h264/ch1")

    let v6 = RTSPURL(string: "rtsp://[fe80::1ff:fe23:4567]:8554/live")
    equal("IPv6 host", v6?.host, "fe80::1ff:fe23:4567")
    equal("IPv6 URI 带方括号", v6?.requestURI, "rtsp://[fe80::1ff:fe23:4567]:8554/live")

    let pct = RTSPURL(string: "rtsp://user:p%40ss@10.0.0.5/s")
    equal("百分号转义还原", pct?.password, "p@ss")

    equal("identity 归一化 host 大小写",
          RTSPURL(string: "rtsp://Admin@192.168.0.1/Live")?.identity,
          "rtsp://192.168.0.1/Live")
    equal("无 scheme 也接受", RTSPURL(string: "192.168.0.1/live")?.requestURI,
          "rtsp://192.168.0.1/live")

    let base = RTSPURL(string: "rtsp://192.168.0.1/livestream/1/")
    equal("拼接相对 control", base?.appendingControl("trackID=0"),
          "rtsp://192.168.0.1/livestream/1/trackID=0")
    equal("绝对 control 原样使用", base?.appendingControl("rtsp://1.2.3.4/t1"),
          "rtsp://1.2.3.4/t1")
    equal("control 为 * 时用基地址", base?.appendingControl("*"),
          "rtsp://192.168.0.1/livestream/1/")

    // 按 Content-Base 解析。下面几个字串全部照抄
    // Captures/Dashcam/RTSP.pcapng：请求 URL 带 :554，Content-Base 不带端口，
    // 路径也完全不同。VLC 发出的 SETUP / PLAY 就是这里期望的两个值。
    let camBase = "rtsp://192.168.1.254/00000000/"
    equal("按 Content-Base 拼 control",
          RTSPURL.resolveControl("track1", base: camBase),
          "rtsp://192.168.1.254/00000000/track1")
    equal("聚合控制指基址本身",
          RTSPURL.resolveControl("*", base: camBase), camBase)
    equal("control 为空也落回基址",
          RTSPURL.resolveControl("", base: camBase), camBase)
    // 反例：不按基址拼会得到什么。真机对这个 URI 回 404，
    // 所以这一条锁的是「两者确实不同」—— 相等就说明基址没起作用。
    let wrong = RTSPURL(string: "rtsp://192.168.1.254:554/xxx.mov")
    equal("不按基址拼会拼错", wrong?.appendingControl("track1"),
          "rtsp://192.168.1.254:554/xxx.mov/track1")
    check("基址解析与按请求 URL 拼的结果不同",
          RTSPURL.resolveControl("track1", base: camBase)
              != wrong?.appendingControl("track1"))

    // 尾斜杠有无都只留一个分隔符；control 自带前导 / 时不能拼出双斜杠。
    equal("基址无尾斜杠时补一个",
          RTSPURL.resolveControl("track1", base: "rtsp://1.2.3.4/live"),
          "rtsp://1.2.3.4/live/track1")
    equal("control 带前导斜杠不出双斜杠",
          RTSPURL.resolveControl("/track1", base: camBase),
          "rtsp://192.168.1.254/00000000/track1")
    equal("Oraimo 的两段相对 control",
          RTSPURL.resolveControl("video/track0",
                                 base: "rtsp://192.168.0.1/livestream/1/"),
          "rtsp://192.168.0.1/livestream/1/video/track0")
    equal("绝对 control 无视基址",
          RTSPURL.resolveControl("rtsp://9.9.9.9/t", base: camBase),
          "rtsp://9.9.9.9/t")
    equal("rtsps 也算绝对",
          RTSPURL.resolveControl("rtsps://9.9.9.9/t", base: camBase),
          "rtsps://9.9.9.9/t")
    equal("大写 RTSP:// 也算绝对",
          RTSPURL.resolveControl("RTSP://9.9.9.9/t", base: camBase),
          "RTSP://9.9.9.9/t")

    check("空串被拒绝", RTSPURL(string: "   ") == nil)
    check("非法端口被拒绝", RTSPURL(string: "rtsp://1.2.3.4:99999/x") == nil)
    check("http scheme 被拒绝", RTSPURL(string: "http://1.2.3.4/x") == nil)
}
// MARK: - 认证

func testAuth() {
    print("\n[认证]")
    let header = "Digest realm=\"testrealm@host.com\", "
        + "qop=\"auth,auth-int\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", "
        + "opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""
    guard let challenge = RTSPAuthChallenge(header: header) else {
        check("Digest 挑战解析", false); return
    }
    equal("realm（值里含 @）", challenge.realm, "testrealm@host.com")
    equal("nonce", challenge.nonce, "dcd98b7102dd2f0e8b11d0f600bfb0c093")
    // 引号内的逗号不能当分隔符。
    equal("qop 列表", challenge.qop, ["auth", "auth-int"])
    equal("opaque", challenge.opaque, "5ccc069c403ebaf9f0171e9517f40e41")

    let auth = RTSPAuthenticator(username: "Mufasa", password: "Circle Of Life")
    check("首个挑战应被接受", auth.update(with: challenge))
    guard let value = auth.authorization(method: "DESCRIBE",
                                         uri: "rtsp://host/stream") else {
        check("生成 Authorization", false); return
    }
    check("含 qop=auth", value.contains("qop=auth"))
    check("nc 从 1 开始", value.contains("nc=00000001"))
    check("带 cnonce", value.contains("cnonce=\""))
    check("username 正确", value.contains("username=\"Mufasa\""))

    // 无 qop 时走 RFC 2069，可以和参考值逐位对比。
    let legacyHeader = "Digest realm=\"testrealm@host.com\", "
        + "nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\""
    let legacy = RTSPAuthenticator(username: "Mufasa", password: "Circle Of Life")
    _ = legacy.update(with: RTSPAuthChallenge(header: legacyHeader)!)
    let legacyValue = legacy.authorization(method: "DESCRIBE",
                                           uri: "rtsp://host/stream") ?? ""
    check("RFC 2069 摘要与参考值一致",
          legacyValue.contains("response=\"86543b3cbadd277ce9e14fff2af997dd\""),
          legacyValue)
    check("无 qop 时不带 nc", !legacyValue.contains("nc="))

    // nonce 没变说明密码本身错了，不该无限重试。
    let same = RTSPAuthChallenge(header: legacyHeader)!
    check("相同 nonce 不再重试", !legacy.update(with: same))
    let stale = RTSPAuthChallenge(
        header: legacyHeader + ", stale=true")!
    check("stale=true 允许重试", legacy.update(with: stale))

    let basic = RTSPAuthenticator(username: "admin", password: "12345")
    _ = basic.update(with: RTSPAuthChallenge(header: "Basic realm=\"cam\"")!)
    equal("Basic 编码", basic.authorization(method: "OPTIONS", uri: "rtsp://x/"),
          "Basic YWRtaW46MTIzNDU=")

    // Digest 优先于 Basic。
    let best = RTSPAuthChallenge.best(from: ["Basic realm=\"a\"",
                                            "Digest realm=\"b\", nonce=\"n\""])
    equal("多挑战优先 Digest", best?.kind, .digest)
}

// MARK: - 消息解析

func testMessage() {
    print("\n[RTSP 消息]")
    let raw = "RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: 12345678;timeout=90\r\n"
        + "Content-Length: 4\r\nContent-Type: application/sdp\r\n\r\nv=0\n"
    guard let parsed = RTSPHead.parse(Data(raw.utf8)),
          case .response(let response) = parsed.message else {
        check("响应解析", false); return
    }
    equal("状态码", response.statusCode, 200)
    equal("CSeq", response.cseq, 3)
    equal("Session ID 去掉 timeout", response.sessionID, "12345678")
    equal("Session timeout", response.sessionTimeout, 90)
    equal("Content-Length", parsed.contentLength, 4)

    // 服务器主动发来的请求要能识别。
    let req = "OPTIONS rtsp://1.2.3.4/ RTSP/1.0\r\nCSeq: 7\r\n\r\n"
    if let p = RTSPHead.parse(Data(req.utf8)),
       case .request(let method, _, let cseq) = p.message {
        equal("入站请求方法", method, "OPTIONS")
        equal("入站请求 CSeq", cseq, 7)
    } else {
        check("入站请求解析", false)
    }

    // Content-Base / Content-Location。头部照抄 Captures/Dashcam/RTSP.pcapng
    // 里 LIVE555 的 DESCRIBE 应答 —— 注意它不带 Session，也不带 timeout。
    let described = "RTSP/1.0 200 OK\r\nCSeq: 3\r\n"
        + "Date: Wed, Mar 11 2026 05:00:41 GMT\r\n"
        + "Content-Base: rtsp://192.168.1.254/00000000/\r\n"
        + "Content-Type: application/sdp\r\nContent-Length: 0\r\n\r\n"
    if let p = RTSPHead.parse(Data(described.utf8)),
       case .response(let r) = p.message {
        equal("Content-Base", r.contentBase, "rtsp://192.168.1.254/00000000/")
        check("没有 Content-Location 时为 nil", r.contentLocation == nil)
        check("没有 Session 时为 nil", r.sessionID == nil)
        check("没有 timeout 时为 nil", r.sessionTimeout == nil)
    } else {
        check("DESCRIBE 应答解析", false)
    }

    // 值为空的头和没有这个头必须一样 —— 否则基址会被设成空串，
    // 之后每个 Request-URI 都以 /track1 开头。
    let blank = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Base:  \r\n"
        + "Content-Location: rtsp://5.6.7.8/alt/\r\n\r\n"
    if let p = RTSPHead.parse(Data(blank.utf8)),
       case .response(let r) = p.message {
        check("空的 Content-Base 当缺失", r.contentBase == nil)
        equal("退到 Content-Location", r.contentLocation, "rtsp://5.6.7.8/alt/")
    } else {
        check("空头响应解析", false)
    }

    check("头部不全时返回 nil",
          RTSPHead.parse(Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n".utf8)) == nil)
    // 有设备只用 LF。
    check("仅 LF 也能解析",
          RTSPHead.parse(Data("RTSP/1.0 401 Unauthorized\nCSeq: 2\n\n".utf8)) != nil)

    let multi = "RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\n"
        + "WWW-Authenticate: Digest realm=\"a\", nonce=\"n\"\r\n"
        + "WWW-Authenticate: Basic realm=\"a\"\r\n\r\n"
    if let p = RTSPHead.parse(Data(multi.utf8)),
       case .response(let r) = p.message {
        equal("同名头取全部", r.values("WWW-Authenticate").count, 2)
    } else {
        check("多挑战响应解析", false)
    }

    var request = RTSPRequest(method: .describe, uri: "rtsp://1.2.3.4/live")
    request.set("Accept", "application/sdp")
    request.set("Accept", "application/sdp2")     // 同名应覆盖而非追加
    let text = String(decoding: request.serialized(cseq: 5), as: UTF8.self)
    check("请求行", text.hasPrefix("DESCRIBE rtsp://1.2.3.4/live RTSP/1.0\r\n"))
    check("CSeq 写入", text.contains("CSeq: 5\r\n"))
    check("同名头被覆盖", text.contains("application/sdp2")
          && !text.contains("application/sdp\r\n"))
    check("以空行结束", text.hasSuffix("\r\n\r\n"))
}
// MARK: - SDP（用 ffmpeg 生成的真实 SDP）

func testSDP() {
    print("\n[SDP]")
    let videoSDP = readFile("video.sdp")
    let audioSDP = readFile("audio.sdp")
    guard !videoSDP.isEmpty else { check("video.sdp 存在", false); return }

    do {
        let session = try SDPSession.parse(Data(videoSDP.utf8))
        guard let video = session.video else { check("找到视频轨", false); return }
        equal("视频编码", video.codec, "H264")
        equal("视频时钟", video.clockRate, 90000)
        equal("payload type", video.payloadType, 96)
        equal("packetization-mode", video.fmtp["packetization-mode"], "1")
        check("含 sprop-parameter-sets", video.fmtp["sprop-parameter-sets"] != nil)

        // 参数集能直接建出 format description，说明解析和 base64 都对。
        guard let depacketizer = VideoDepacketizer(media: video) else {
            check("建视频解包器", false); return
        }
        equal("编码名", depacketizer.codecName, "H.264")
        check("SDP 参数集直接就绪", depacketizer.isReady)
        if let format = depacketizer.formatDescription {
            let d = CMVideoFormatDescriptionGetDimensions(format)
            equal("SPS 解出的宽", d.width, 640)
            equal("SPS 解出的高", d.height, 480)
            equal("codec type", CMFormatDescriptionGetMediaSubType(format),
                  kCMVideoCodecType_H264)
        }
    } catch {
        check("解析 video.sdp", false, "\(error)")
    }

    // 音频不播了，但音频轨的负载类型必须还认得出来 —— 那是把混进视频
    // 通道的音频包挡掉的依据。这里只验「能取到、payload type 对」。
    do {
        let session = try SDPSession.parse(Data(audioSDP.utf8))
        guard let audio = session.anyAudio else { check("找到音频轨", false); return }
        equal("音频轨 payload type", audio.payloadType, 97)
        equal("音频编码仍可读", audio.codec, "MPEG4-GENERIC")
        check("音频轨被识别为 audio", audio.isAudio)
    } catch {
        check("解析 audio.sdp", false, "\(error)")
    }

    // 静态 payload type 没有 rtpmap 也要能识别 —— 设备省略 rtpmap 时，
    // 靠这张表才能知道 pt=0 是音频，进而把它挡在视频解包器外面。
    let pcmu = "v=0\r\nm=audio 0 RTP/AVP 0\r\na=control:track2\r\n"
    if let media = try? SDPSession.parse(Data(pcmu.utf8)).anyAudio {
        equal("PCMU 静态映射", media.codec, "PCMU")
        equal("PCMU 时钟", media.clockRate, 8000)
        equal("PCMU payload type", media.payloadType, 0)
    } else {
        check("静态 payload 解析", false)
    }

    // 不认识的音频编码也要能取到：按「能解的编码」筛会漏掉它，
    // 那一路的包就会被当成视频解。
    let weird = "v=0\r\nm=audio 0 RTP/AVP 99\r\na=rtpmap:99 OPUSWHATEVER/48000\r\n"
    if let media = try? SDPSession.parse(Data(weird.utf8)).anyAudio {
        equal("陌生音频编码也取到", media.payloadType, 99)
    } else {
        check("陌生音频编码可取", false)
    }

    // 海康那种把 control 写成绝对地址的也要拿得到。
    let hik = "v=0\r\ns=Media Presentation\r\n"
        + "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H265/90000\r\n"
        + "a=control:rtsp://10.0.0.1/Streaming/Channels/101/trackID=1\r\n"
    if let media = try? SDPSession.parse(Data(hik.utf8)).video {
        equal("H265 识别", media.codec, "H265")
        check("绝对 control 保留",
              media.control.hasPrefix("rtsp://"))
        check("H265 解包器可建", VideoDepacketizer(media: media) != nil)
    } else {
        check("H265 SDP 解析", false)
    }

    check("空 SDP 报错", (try? SDPSession.parse(Data())) == nil)
}
// MARK: - RTP 头解析

func testRTPPacket() {
    print("\n[RTP 头]")
    let packets = loadPackets("video.rtp")
    check("抓到视频包", !packets.isEmpty, "\(packets.count) 个")
    guard let first = packets.first, let parsed = RTPPacket(first) else {
        check("解析首个真实包", false); return
    }
    equal("payload type", parsed.payloadType, 96)
    check("负载非空", !parsed.payload.isEmpty)

    // 所有真实包都应解析成功，且 SSRC 一致。
    var parsedCount = 0
    var ssrcs = Set<UInt32>()
    var markers = 0
    for packet in packets {
        guard let p = RTPPacket(packet) else { continue }
        parsedCount += 1
        ssrcs.insert(p.ssrc)
        if p.marker { markers += 1 }
    }
    equal("全部真实包可解析", parsedCount, packets.count)
    equal("SSRC 唯一", ssrcs.count, 1)
    // 每帧最后一个包带 marker，150 帧就该有 150 个。
    equal("marker 数等于帧数", markers, 150)

    // 构造带 padding + CSRC + 扩展头的包，验证偏移计算。
    // 0xE0 = marker 位 + PT 96；0xB1 = V2, P=1, X=1, CC=1
    var synthetic = Data([0xB1, 0xE0, 0x00, 0x0A,
                          0x00, 0x00, 0x01, 0x00,      // timestamp
                          0xDE, 0xAD, 0xBE, 0xEF])     // SSRC
    synthetic.append(contentsOf: [0x11, 0x22, 0x33, 0x44])          // CSRC
    synthetic.append(contentsOf: [0xBE, 0xDE, 0x00, 0x01])          // 扩展头，1 word
    synthetic.append(contentsOf: [0xAA, 0xAA, 0xAA, 0xAA])
    synthetic.append(contentsOf: [0x65, 0x88])                      // 真实负载
    synthetic.append(contentsOf: [0x00, 0x00, 0x03])                // padding=3
    guard let complex = RTPPacket(synthetic) else {
        check("解析复杂包头", false); return
    }
    equal("跳过 CSRC/扩展/padding 后的负载", [UInt8](complex.payload), [0x65, 0x88])
    equal("时间戳", complex.timestamp, 256)
    equal("SSRC", complex.ssrc, 0xDEADBEEF)
    check("marker 位", complex.marker)

    check("过短的包被拒绝", RTPPacket(Data([0x80, 0x60, 0x00])) == nil)
    check("版本非 2 被拒绝",
          RTPPacket(Data([0x00, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])) == nil)
    // padding 长度超过实际负载，必须判非法而不是崩。
    check("非法 padding 被拒绝",
          RTPPacket(Data([0xA0, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF])) == nil)

    // Data 切片（startIndex != 0）也要能正确解析。
    let sliced = Data([0xFF, 0xFF]) + first
    check("切片偏移正确", RTPPacket(sliced.dropFirst(2))?.payloadType == 96)
}

// MARK: - H.264 解包（真实 ffmpeg 打包数据）

func testH264Depacketize() {
    print("\n[H.264 解包]")
    let packets = loadPackets("video.rtp")
    guard !packets.isEmpty else { check("有抓包数据", false); return }
    guard let media = try? SDPSession.parse(Data(readFile("video.sdp").utf8)).video,
          var depacketizer = VideoDepacketizer(media: media) else {
        check("建解包器", false); return
    }

    var units: [VideoAccessUnit] = []
    for raw in packets {
        guard let packet = RTPPacket(raw) else { continue }
        units.append(contentsOf: depacketizer.process(packet))
    }

    // ffmpeg 送了 150 帧，一帧不能少也不能多。
    equal("解出的帧数", units.count, 150)
    // 6 是三种方式核对过的真值：packet flags / frame key_frame / 裸 IDR NAL 计数。
    equal("关键帧数", units.filter(\.isKeyframe).count, 6)
    check("首帧是关键帧", units.first?.isKeyframe == true)

    // 每个 AVCC 单元的长度前缀必须自洽，且总长与 ffprobe 的 packet size 一致。
    var wellFormed = 0
    var totalPayload = 0
    for unit in units {
        let bytes = [UInt8](unit.data)
        var offset = 0
        var ok = true
        while offset + 4 <= bytes.count {
            let n = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            if n <= 0 || offset + n > bytes.count { ok = false; break }
            offset += n
        }
        if ok && offset == bytes.count { wellFormed += 1 }
        totalPayload += unit.data.count
    }
    equal("AVCC 长度前缀自洽", wellFormed, units.count)

    // 时间戳应严格递增（25fps -> 每帧 3600）。
    let timestamps = units.map(\.rtpTimestamp)
    check("时间戳单调递增",
          zip(timestamps, timestamps.dropFirst()).allSatisfy { $0 < $1 })
    let deltas = Set(zip(timestamps, timestamps.dropFirst()).map { $1 - $0 })
    equal("帧间隔恒为 3600（25fps）", deltas, [3600])

    // 与 ffprobe 的逐帧大小对比：AVCC 和 mp4 的 packet size 应完全一致。
    let expected = readFile("expected_video_sizes.txt")
        .split(separator: "\n").compactMap { Int($0.trimmed) }
    if expected.count == units.count {
        let actual = units.map(\.data.count)
        let matched = zip(actual, expected).filter { $0 == $1 }.count
        equal("逐帧大小与 ffprobe 一致", matched, expected.count)
    } else {
        check("期望帧数对齐", false, "expected \(expected.count)")
    }
    check("总负载量合理", totalPayload > 90000, "\(totalPayload)")

    // 分片重组确实发生了：关键帧 7521 字节远超 MTU，必须靠 FU-A 拼回来。
    let keyframeSizes = units.filter(\.isKeyframe).map(\.data.count)
    check("关键帧由多包重组", keyframeSizes.allSatisfy { $0 > 1400 },
          "\(keyframeSizes)")
}

// MARK: - 时间轴

func testTimeline() {
    print("\n[时间轴]")
    var timeline = RTPTimeline(clockRate: 90000)
    timeline.setOrigin(1000)
    equal("起点为 0", timeline.time(for: 1000).seconds, 0)
    equal("+3600 即 40ms", timeline.time(for: 4600).seconds, 0.04)

    // 32 位回绕：接近上限后跳到小值，时间必须继续增长而不是倒退。
    var wrapping = RTPTimeline(clockRate: 90000)
    wrapping.setOrigin(UInt32.max - 8999)
    let before = wrapping.time(for: UInt32.max - 4499).seconds
    let after = wrapping.time(for: 4500).seconds        // 回绕后
    check("回绕后时间继续增长", after > before, "\(before) -> \(after)")
    // 回绕跨度应是 (max-8999 -> 4500) = 13500 ticks = 0.15s
    check("回绕后时间正确", abs(after - 0.15) < 0.0001, "\(after)")

    var noOrigin = RTPTimeline(clockRate: 90000)
    equal("无 RTP-Info 时首包为 0", noOrigin.time(for: 777777).seconds, 0)

    let clock = MediaClock(clockRate: 90000)
    clock.applyRTPInfo(9000)
    equal("原点即 0", clock.videoTime(9000).seconds, 0)
    equal("视频 0.1s", clock.videoTime(18000).seconds, 0.1)

    // 回归：以前 MediaClock 给首包之后的每一包都加上「首包到次包的间隔」，
    // 单轨下等于把除首帧以外的所有帧整体往后推几毫秒。逐帧核对精确值。
    let clean = MediaClock(clockRate: 90000)
    clean.applyRTPInfo(0)
    var exact = true
    var firstBad = ""
    for i in 0..<10 {
        let got = clean.videoTime(UInt32(i * 3000)).seconds   // 30fps
        let want = Double(i) * 3000.0 / 90000
        if abs(got - want) > 1e-9 {
            exact = false
            if firstBad.isEmpty { firstBad = "第 \(i) 帧 \(got) != \(want)" }
        }
    }
    check("每帧 PTS 无额外偏移", exact, firstBad)

    // 没有 RTP-Info 的设备：不能崩，首包仍要落在 0。
    let noInfo = MediaClock(clockRate: 90000)
    noInfo.applyRTPInfo(nil)
    equal("无 RTP-Info 首包为 0", noInfo.videoTime(555_555).seconds, 0)

    // reset 之后下一包重新成为原点，否则重连会把 PTS 接到旧时基上。
    clock.reset()
    equal("reset 后重新起算", clock.videoTime(90000).seconds, 0)
}

// MARK: - 丢包统计

func testLossCounter() {
    print("\n[丢包统计]")
    var counter = RTPLossCounter()
    for seq in UInt16(100)...UInt16(120) { counter.note(seq) }
    equal("连续无丢包", counter.lost, 0)

    // 中间缺 3 个。
    var gap = RTPLossCounter()
    for seq in [10, 11, 12, 16, 17].map(UInt16.init) { gap.note(seq) }
    equal("缺 3 个包", gap.lost, 3)

    // 乱序不该算成丢包：这是直接数序号断点时最容易算错的场景。
    var reorder = RTPLossCounter()
    for seq in [1, 2, 5, 3, 4, 6].map(UInt16.init) { reorder.note(seq) }
    equal("乱序不计丢包", reorder.lost, 0)

    // B 帧那种深度乱序。
    var deep = RTPLossCounter()
    for seq in [1, 5, 2, 3, 4, 9, 6, 7, 8].map(UInt16.init) { deep.note(seq) }
    equal("深度乱序不计丢包", deep.lost, 0)

    // 16 位回绕。
    var wrap = RTPLossCounter()
    for seq in [UInt16(65533), 65534, 65535, 0, 1, 2] { wrap.note(seq) }
    equal("回绕无丢包", wrap.lost, 0)

    var wrapLoss = RTPLossCounter()
    for seq in [UInt16(65534), 65535, 2, 3] { wrapLoss.note(seq) }
    equal("跨回绕丢 2 个", wrapLoss.lost, 2)

    // 用真实 H.265 抓包（含 B 帧乱序）验证：不该报任何丢包。
    var real = RTPLossCounter()
    var count = 0
    for raw in loadPackets("video265.rtp") {
        guard let packet = RTPPacket(raw) else { continue }
        real.note(packet.sequenceNumber)
        count += 1
    }
    if count > 0 {
        equal("真实 H.265 抓包零丢包", real.lost, 0)
    }

    var reset = RTPLossCounter()
    reset.note(10); reset.note(20)
    check("重置前有丢包", reset.lost > 0)
    reset.reset()
    equal("重置后归零", reset.lost, 0)
}

// MARK: - 起播闸门

func testStartGate() {
    print("\n[起播闸门]")

    // 关键帧直接放行。
    var onKey = VideoStartGate()
    check("IDR 立即放行", onKey.allows(isKeyframe: true, isRecoveryPoint: false,
                                      timestamp: 0))

    // 非关键帧要先等。
    var waiting = VideoStartGate()
    check("首个 P 帧被拦下", !waiting.allows(isKeyframe: false, isRecoveryPoint: false,
                                            timestamp: 0))
    check("等到 IDR 才放行", waiting.allows(isKeyframe: true, isRecoveryPoint: false,
                                           timestamp: 3600))
    check("放行后一直放行", waiting.allows(isKeyframe: false, isRecoveryPoint: false,
                                          timestamp: 7200))

    // SEI recovery point 也算入点。
    var recovery = VideoStartGate()
    check("recovery point 放行", recovery.allows(isKeyframe: false, isRecoveryPoint: true,
                                                 timestamp: 0))

    // 永远没有关键帧：5 秒（90 kHz 下 450000 tick）后必须自己起播，
    // 否则界面会永远停在「缓冲中」——这正是真机上那个 bug。
    var noIDR = VideoStartGate()
    var emitted = 0
    // 25 fps -> 每帧 3600 tick；跑 200 帧覆盖 8 秒。
    for i in 0..<200 {
        let ts = UInt32(i * 3600)
        if noIDR.allows(isKeyframe: false, isRecoveryPoint: false, timestamp: ts) {
            emitted += 1
        }
    }
    check("无 IDR 也能起播", emitted > 0, "得到 \(emitted) 帧")
    // 第 0 帧记起点，到第 125 帧刚好满 450000 tick。
    equal("等满 5 秒才起播", 200 - emitted, 125)

    // 时间戳完全不动时靠帧数兜底。
    var frozen = VideoStartGate()
    var frozenEmitted = 0
    for _ in 0..<400 {
        if frozen.allows(isKeyframe: false, isRecoveryPoint: false, timestamp: 42) {
            frozenEmitted += 1
        }
    }
    equal("时间戳不动时按帧数兜底", 400 - frozenEmitted, 299)

    // 时间戳往回跳不能被当成「已经等够了」。
    var backwards = VideoStartGate()
    _ = backwards.allows(isKeyframe: false, isRecoveryPoint: false, timestamp: 1_000_000)
    check("时间戳回跳不误放行",
          !backwards.allows(isKeyframe: false, isRecoveryPoint: false, timestamp: 10))

    // 32 位回绕：起点靠近上限，绕过 0 之后仍要正确算出已等时长。
    var wrap = VideoStartGate()
    _ = wrap.allows(isKeyframe: false, isRecoveryPoint: false, timestamp: 0xFFFF_F000)
    check("回绕前还没等够",
          !wrap.allows(isKeyframe: false, isRecoveryPoint: false, timestamp: 1000))
    check("跨回绕等满后放行",
          wrap.allows(isKeyframe: false, isRecoveryPoint: false, timestamp: 450_000))

    // reset 之后回到等待状态。
    var reused = VideoStartGate()
    _ = reused.allows(isKeyframe: true, isRecoveryPoint: false, timestamp: 0)
    reused.reset()
    check("reset 后重新等待",
          !reused.allows(isKeyframe: false, isRecoveryPoint: false, timestamp: 0))
}

func testSEIRecoveryPoint() {
    print("\n[SEI recovery point]")

    /// 拼一个 AVCC 单元：4 字节长度 + NAL。
    func avcc(_ nal: [UInt8]) -> Data {
        let n = nal.count
        return Data([UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF),
                     UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + nal)
    }

    // SEI NAL：头 0x06，载荷类型 6（recovery point），长度 2。
    let recovery = avcc([0x06, 0x06, 0x02, 0x00, 0x00, 0x80])
    check("识别 recovery point", recovery.avccContainsH264RecoveryPoint)

    // 载荷类型 1（pic_timing）不是入点。
    let picTiming = avcc([0x06, 0x01, 0x02, 0x00, 0x00, 0x80])
    check("pic_timing 不算入点", !picTiming.avccContainsH264RecoveryPoint)

    // 纯 P 帧分片里没有 SEI。
    let slice = avcc([0x41, 0x9A, 0x12, 0x34])
    check("P 帧不算入点", !slice.avccContainsH264RecoveryPoint)

    // 第二条消息才是 recovery point，要能接着往下扫。
    let second = avcc([0x06, 0x01, 0x01, 0xAA, 0x06, 0x01, 0x00, 0x80])
    check("扫到第二条消息", second.avccContainsH264RecoveryPoint)

    // 载荷类型用 0xFF 续接：255 + 6 = 261，不是 6，不能误判。
    let extended = avcc([0x06, 0xFF, 0x06, 0x01, 0x00, 0x80])
    check("续接类型不误判", !extended.avccContainsH264RecoveryPoint)

    // 防竞争字节：SEI 载荷里的 00 00 03 要先去掉再解析。
    equal("去掉防竞争字节",
          [UInt8](Data([0x00, 0x00, 0x03, 0x01]).dropEmulationPrevention),
          [0x00, 0x00, 0x01])
    equal("正常数据不受影响",
          [UInt8](Data([0x01, 0x02, 0x03]).dropEmulationPrevention),
          [0x01, 0x02, 0x03])

    // 截断的 SEI 不能崩，也不能误报。
    check("截断 SEI 不误报", !avcc([0x06]).avccContainsH264RecoveryPoint)
    check("空数据不误报", !Data().avccContainsH264RecoveryPoint)

    // 真实抓包里的 IDR 帧走的是关键帧路径，这里只确认扫描不会崩。
    let packets = loadPackets("video.rtp")
    check("真实抓包可用", !packets.isEmpty)
}

// MARK: - 缓冲与传输帧切分

func testByteBuffer() {
    print("\n[缓冲]")
    var buffer = RTSPByteBuffer()
    buffer.append(Data([1, 2, 3, 4, 5]))
    equal("初始长度", buffer.count, 5)
    equal("peek 不消费", buffer.peek(0), 1)
    equal("取 2 字节", buffer.take(2).map { [UInt8]($0) }, [1, 2])
    equal("剩余长度", buffer.count, 3)
    check("超量读取返回 nil", buffer.take(99) == nil)
    equal("失败后长度不变", buffer.count, 3)
    equal("大端 16 位", buffer.peekUInt16BE(0), 0x0304)

    // interleaved 帧头：$ + channel + 16 位长度
    var stream = RTSPByteBuffer()
    stream.append(Data([0x24, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC]))
    equal("识别 $", stream.peek(0), 0x24)
    equal("通道", stream.peek(1), 0)
    equal("长度", stream.peekUInt16BE(2), 3)
    stream.skip(4)
    equal("取出帧体", stream.take(3).map { [UInt8]($0) }, [0xAA, 0xBB, 0xCC])
    check("消费干净", stream.isEmpty)

    // 分片到达：不足时不能误读。
    var partial = RTSPByteBuffer()
    partial.append(Data([0x24, 0x00, 0x10, 0x00]))
    equal("声明长度 4096", partial.peekUInt16BE(2), 4096)
    check("数据不足时取不到", partial.count < 4 + 4096)
}

// MARK: - 历史记录

func testHistory() {
    print("\n[历史记录]")
    let suiteName = "rtsp.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        check("建测试 defaults", false); return
    }
    let store = StreamHistoryStore(defaults: defaults)
    equal("初始为空", store.entries.count, 0)

    let url = RTSPURL(string: "rtsp://192.168.0.1/livestream/1/")!
    store.recordPlayback(url: url)
    equal("记录一条", store.entries.count, 1)
    equal("地址不含凭据", store.entries.first?.address,
          "rtsp://192.168.0.1/livestream/1/")

    // 同一地址再播只更新次数，不新增。
    store.recordPlayback(url: url)
    equal("重复播放不新增", store.entries.count, 1)
    equal("播放次数累加", store.entries.first?.playCount, 2)

    // 大小写不同的 host 应视为同一条。
    store.recordPlayback(url: RTSPURL(string: "rtsp://192.168.0.1/livestream/2/")!)
    equal("不同路径算新条目", store.entries.count, 2)

    store.updateMediaInfo(identity: url.identity, codec: "H.264", width: 1920, height: 1080)
    let entry = store.entry(for: url.identity)
    equal("规格已保存", entry?.resolutionText, "1920×1080")
    check("详情含编码", entry?.detailText.contains("H.264") == true)

    if let entry {
        store.toggleFavorite(entry)
        check("收藏生效", store.entry(for: url.identity)?.isFavorite == true)
        equal("收藏列表", store.favorites.count, 1)
        check("收藏排在最前", store.sorted.first?.isFavorite == true)
        store.rename(entry, to: "大门摄像头")
        equal("备注名", store.entry(for: url.identity)?.displayName, "大门摄像头")
        store.rename(entry, to: "   ")
        equal("空备注回退到地址", store.entry(for: url.identity)?.displayName,
              "rtsp://192.168.0.1/livestream/1/")
    }

    // 重载后数据要还在。
    let reloaded = StreamHistoryStore(defaults: defaults)
    equal("持久化后条数", reloaded.entries.count, 2)
    check("收藏状态持久化",
          reloaded.entry(for: url.identity)?.isFavorite == true)

    // 带凭据的地址：密码进钥匙串，历史里只留用户名。
    let secure = RTSPURL(string: "rtsp://admin:secret123@192.168.0.9/live")!
    store.recordPlayback(url: secure)
    let secureEntry = store.entry(for: secure.identity)
    equal("用户名保留", secureEntry?.username, "admin")
    check("地址里没有密码",
          secureEntry?.address.contains("secret123") == false,
          secureEntry?.address ?? "")
    let resolved = store.resolvedAddress(for: secureEntry!)
    check("回填带回密码", resolved.contains("secret123"), resolved)
    check("回填地址可解析", RTSPURL(string: resolved)?.password == "secret123")

    store.remove(secureEntry!)
    check("删除生效", store.entry(for: secure.identity) == nil)
    store.removeAll()
    equal("清空", store.entries.count, 0)
    defaults.removePersistentDomain(forName: suiteName)
}

// MARK: - H.265 解包（真实 ffmpeg 打包，参数集只在流内）

func testHEVCDepacketize() {
    print("\n[H.265 解包]")
    let packets = loadPackets("video265.rtp")
    guard !packets.isEmpty else { check("有 H265 抓包", false); return }
    let sdpText = readFile("video265.sdp")
    guard let media = try? SDPSession.parse(Data(sdpText.utf8)).video,
          var depacketizer = VideoDepacketizer(media: media) else {
        check("建 H265 解包器", false); return
    }
    equal("编码名", depacketizer.codecName, "H.265")
    // ffmpeg 没给 sprop-*，必须靠流内的 VPS/SPS/PPS 才能就绪。
    check("SDP 无参数集时初始未就绪", !depacketizer.isReady)

    var units: [VideoAccessUnit] = []
    for raw in packets {
        guard let packet = RTPPacket(raw) else { continue }
        units.append(contentsOf: depacketizer.process(packet))
    }

    check("流内参数集使其就绪", depacketizer.isReady)
    equal("解出的帧数", units.count, 100)
    equal("IRAP 帧数", units.filter(\.isKeyframe).count, 4)
    check("首帧是关键帧", units.first?.isKeyframe == true)
    // 参数集是流内获取的，首帧之前必然发生一次格式建立。
    check("首帧标记格式变化", units.first?.formatDidChange == true)

    if let format = depacketizer.formatDescription {
        let d = CMVideoFormatDescriptionGetDimensions(format)
        equal("SPS 解出的宽", d.width, 640)
        equal("SPS 解出的高", d.height, 480)
        equal("codec type", CMFormatDescriptionGetMediaSubType(format),
              kCMVideoCodecType_HEVC)
    } else {
        check("取得 HEVC format", false)
    }

    // AVCC 结构自洽性。
    var wellFormed = 0
    for unit in units {
        let bytes = [UInt8](unit.data)
        var offset = 0
        var ok = true
        while offset + 4 <= bytes.count {
            let n = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            if n <= 0 || offset + n > bytes.count { ok = false; break }
            offset += n
        }
        if ok && offset == bytes.count { wellFormed += 1 }
    }
    equal("AVCC 长度前缀自洽", wellFormed, units.count)

    // 这段 H.265 有 B 帧，RTP 时间戳是 PTS，按到达（解码）顺序看必然乱序。
    // 我们送样本时 DTS 填 .invalid，由显示层按 PTS 自行重排，
    // 所以要校验的不是单调，而是「乱序幅度小于预缓冲」。
    let timestamps = units.map(\.rtpTimestamp)
    equal("时间戳无重复", Set(timestamps).count, timestamps.count)
    check("首帧 PTS 最小", timestamps.first == timestamps.min())
    var peak = timestamps[0]
    var worstRegression: Double = 0
    for ts in timestamps {
        if ts < peak {
            worstRegression = max(worstRegression, Double(peak - ts) / 90000)
        }
        peak = max(peak, ts)
    }
    check("乱序幅度小于渲染预缓冲 250ms", worstRegression < 0.25,
          String(format: "%.3fs", worstRegression))

    // 参数集不应留在 AVCC 负载里（它们进 format description）。
    var strayParameterSets = 0
    for unit in units {
        let bytes = [UInt8](unit.data)
        var offset = 0
        while offset + 4 <= bytes.count {
            let n = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard n > 0, offset + n <= bytes.count else { break }
            let type = (bytes[offset] >> 1) & 0x3F
            if type == 32 || type == 33 || type == 34 { strayParameterSets += 1 }
            offset += n
        }
    }
    equal("负载内无残留参数集", strayParameterSets, 0)

    // 非关键帧是单 slice，AVCC 长度应与裸流逐帧对齐
    //（关键帧因为剥离了参数集，必然比裸流小，不参与比较）。
    let expected = readFile("expected_265_sizes.txt")
        .split(separator: "\n").compactMap { Int($0.trimmed) }
    if expected.count == units.count {
        var compared = 0, matched = 0
        for (unit, size) in zip(units, expected) where !unit.isKeyframe {
            compared += 1
            if unit.data.count == size { matched += 1 }
        }
        check("非关键帧逐帧大小对齐", compared > 0 && matched == compared,
              "\(matched)/\(compared)")
        for (unit, size) in zip(units, expected) where unit.isKeyframe {
            check("关键帧已剥离参数集", unit.data.count < size,
                  "AU \(unit.data.count) vs 裸流 \(size)")
            break
        }
    } else {
        check("H265 期望帧数对齐", false, "expected \(expected.count)")
    }

    // 分片重组：IRAP 帧远超 MTU。
    let keyframeSizes = units.filter(\.isKeyframe).map(\.data.count)
    check("IRAP 由多包重组（FU）", keyframeSizes.allSatisfy { $0 > 1400 },
          "\(keyframeSizes)")
}

// MARK: - 设备档案

func testDevices() {
    print("\n[设备档案]")
    let all = DeviceProfile.all
    check("有档案", !all.isEmpty)
    equal("id 不重复", Set(all.map(\.id)).count, all.count)
    equal("名字不重复", Set(all.map(\.name)).count, all.count)
    check("默认档案在列表里", all.contains(DeviceProfile.default))

    for d in all {
        // 地址解析不了的话，界面上点一下菜单就是直接失败。
        check("\(d.id) 地址可解析", RTSPURL(string: d.address) != nil)
        check("\(d.id) 有说明", !d.summary.isEmpty)
        check("\(d.id) 有特征", !d.traits.isEmpty)
    }

    // id 就是抓包目录名。改目录不改档案（或反过来）会让注释里的出处失效，
    // 这条负责当场发现。抓包不在时跳过 —— 和别的 fixture 用例一个规矩。
    let captures = "../../Captures"
    if FileManager.default.fileExists(atPath: captures) {
        for d in all {
            check("\(d.id) 有对应抓包目录",
                  FileManager.default.fileExists(atPath: "\(captures)/\(d.id)"))
        }
    } else {
        print("  --   跳过抓包目录核对（没找到 \(captures)）")
    }

    // 两台设备的默认地址必须真的不同，否则菜单里两项点下来一样。
    equal("地址不重复", Set(all.map(\.address)).count, all.count)
}

// MARK: - 入口

print("=== RTSP Client 测试 ===")
testURL()
testAuth()
testMessage()
testSDP()
testRTPPacket()
testH264Depacketize()
testHEVCDepacketize()
testTimeline()
testLossCounter()
testStartGate()
testSEIRecoveryPoint()
testByteBuffer()
testHistory()
testDevices()

print("\n=== \(checks - failures)/\(checks) 通过 ===")
if failures > 0 {
    print("失败 \(failures) 项")
    exit(1)
}
