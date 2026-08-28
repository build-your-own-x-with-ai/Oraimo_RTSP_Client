//
//  RTSPSession+Handshake.swift
//  RTSPClient
//
//  OPTIONS -> DESCRIBE -> SETUP -> PLAY 的请求序列。
//

import Foundation
import CoreMedia

// 默认隔离是 MainActor，别的文件里的 extension 不会自动继承类型上的
// nonisolated，必须显式标注，否则这些方法会被当成主线程方法。
nonisolated extension RTSPSession {
    // MARK: - OPTIONS

    func sendOptions() {
        var request = RTSPRequest(method: .options, uri: url.requestURI)
        authorize(&request)
        connection.send(request) { [weak self] result in
            guard let self, !self.isStopped else { return }
            switch result {
            case .failure(let error):
                self.finish(with: error)
            case .success(let response):
                if self.retryIfUnauthorized(response, retry: { self.sendOptions() }) { return }
                // OPTIONS 失败不致命，有些设备直接不支持。
                let allow = (response.value("Public") ?? "").uppercased()
                self.supportsGetParameter = allow.contains("GET_PARAMETER")
                self.sendDescribe()
            }
        }
    }

    // MARK: - DESCRIBE

    func sendDescribe() {
        setStage(.describing)
        var request = RTSPRequest(method: .describe, uri: url.requestURI)
        request.set("Accept", "application/sdp")
        authorize(&request)
        connection.send(request) { [weak self] result in
            guard let self, !self.isStopped else { return }
            switch result {
            case .failure(let error):
                self.finish(with: error)
            case .success(let response):
                if self.retryIfUnauthorized(response, retry: { self.sendDescribe() }) { return }
                guard response.isSuccess else {
                    self.finish(with: .status(code: response.statusCode,
                                              reason: response.reasonPhrase,
                                              method: "DESCRIBE"))
                    return
                }
                self.consumeSDP(response)
            }
        }
    }

    private func consumeSDP(_ response: RTSPResponse) {
        do {
            let sdp = try SDPSession.parse(response.body)
            info.sessionName = sdp.sessionName
            adoptBaseURI(from: response, sdp: sdp)

            guard let video = sdp.video, let depacketizer = VideoDepacketizer(media: video) else {
                finish(with: .noSupportedMedia)
                return
            }
            videoMedia = video
            videoPayloadType = video.payloadType
            info.videoCodec = depacketizer.codecName
            // SDP 带了 sprop 参数集时，初始化里已经建好 format。
            videoFormat = depacketizer.formatDescription
            videoDepacketizer = depacketizer

            // 音频轨不 SETUP，只记下它声明的负载类型，
            // 用来把混进视频通道的音频包挡在解包器外面。
            audioPayloadType = sdp.anyAudio?.payloadType ?? -1

            clock = MediaClock(clockRate: video.clockRate)
            if let format = videoFormat {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                info.width = dimensions.width
                info.height = dimensions.height
            }
            events(.info(info))
            setupVideo()
        } catch let error as RTSPError {
            finish(with: error)
        } catch {
            finish(with: .sdpParseFailed(error.localizedDescription))
        }
    }

    /// 定下基址和聚合控制 URI。必须在任何 SETUP 之前跑。
    ///
    /// RFC 2326 的优先级：Content-Base > Content-Location > 请求 URL。
    /// 那台记录仪（LIVE555）就靠这一步才能过 SETUP —— 它用 `/xxx.mov` 收
    /// DESCRIBE，Content-Base 给的却是 `rtsp://192.168.1.254/00000000/`。
    /// Oraimo 两个头都不发，于是落回请求 URL，行为和以前一模一样。
    private func adoptBaseURI(from response: RTSPResponse, sdp: SDPSession) {
        // 相对的 Content-Base 见过，但绝对的才有意义：拿它当基址是为了换掉
        // 请求 URL 的路径，相对值给不了这个。不合格就当没这个头。
        let declared = [response.contentBase, response.contentLocation]
            .compactMap(\.self)
            .first { $0.isAbsoluteRTSP }
        baseURI = declared ?? url.requestURI

        // 会话级 a=control 是绝对地址时它就是聚合控制的目标，
        // 否则（`*` 或没有）聚合控制就指基址本身。
        let sessionControl = sdp.control ?? "*"
        aggregateURI = RTSPURL.resolveControl(sessionControl, base: baseURI)
    }

    // MARK: - SETUP

    private func setupVideo() {
        setStage(.settingUp)
        guard let media = videoMedia else {
            finish(with: .noSupportedMedia)
            return
        }
        // 端口开不出来就走交织。这个决定发生在任何请求发出之前。
        if !prepareUDP() { fallBackToInterleaved() }
        sendSetup(control: media.control, channel: videoChannel)
    }

    /// UDP 模式下开好收包端口。返回 false 表示没开出来。
    private func prepareUDP() -> Bool {
        guard transportMode == .udp else { return true }
        guard let transport = RTPUDPTransport(queue: connection.queue) else { return false }
        // SETUP 之前就开始收：有固件在应答落地之前就往 client_port 发包了。
        transport.start { [weak self] datagram in
            self?.handleUDP(datagram)
        }
        videoUDP = transport
        return true
    }

    /// 放弃 UDP 改走 TCP 交织，之后的 SETUP 都发交织请求。
    func fallBackToInterleaved() {
        transportMode = .interleaved
        closeUDP()
    }

    private func sendSetup(control: String, channel: Int) {
        let uri = RTSPURL.resolveControl(control, base: baseURI)
        var request = RTSPRequest(method: .setup, uri: uri)
        request.set("Transport", transportHeader(channel: channel))
        if let sessionID { request.set("Session", sessionID) }
        authorize(&request)
        connection.send(request) { [weak self] result in
            guard let self, !self.isStopped else { return }
            switch result {
            case .failure(let error):
                self.finish(with: error)
            case .success(let response):
                let retried = self.retryIfUnauthorized(response, retry: {
                    self.sendSetup(control: control, channel: channel)
                })
                if retried { return }
                guard response.isSuccess else {
                    // 461 Unsupported Transport 之类：换交织在同一条连接上再试一次。
                    // fallBackToInterleaved() 会把 transportMode 改掉，所以不会来回弹。
                    if self.transportMode == .udp {
                        self.fallBackToInterleaved()
                        self.sendSetup(control: control, channel: channel)
                        return
                    }
                    self.finish(with: .status(code: response.statusCode,
                                              reason: response.reasonPhrase,
                                              method: "SETUP"))
                    return
                }
                guard let sessionID = response.sessionID else {
                    self.finish(with: .sessionMissing)
                    return
                }
                self.sessionID = sessionID
                if let timeout = response.sessionTimeout, timeout > 10 {
                    self.sessionTimeout = timeout
                }
                guard self.applyTransport(response) else { return }
                self.sendPlay()
            }
        }
    }

    /// Transport 请求头。
    ///
    /// UDP 那行照 VLC 抓包里的原样发。摄像机只认这个形状，多写
    /// destination / mode 之类的参数反而有固件会整条判错。
    private func transportHeader(channel: Int) -> String {
        if transportMode == .udp, let udp = videoUDP {
            return "RTP/AVP;unicast;client_port=\(udp.rtpPort)-\(udp.rtcpPort)"
        }
        return "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)"
    }

    /// 落实服务器回的 Transport。返回 false 表示已经失败收场，调用方不要再往下走。
    ///
    /// 两个方向都要认：请求交织却回了 UDP，是服务器不肯走交织；请求 UDP 却回了
    /// interleaved，是服务器只给交织。按 RFC 2326，Transport 里不写 "TCP"
    /// 时默认就是 UDP，所以判断只能看有没有 interleaved 参数，不能找 "UDP" 字面。
    private func applyTransport(_ response: RTSPResponse) -> Bool {
        let transport = response.value("Transport")

        // 请求的是 UDP。摄像机的应答里既没有 server_port 也没有 source，
        // 只把 client_port 抄回来 —— 发送端口无从得知，socket 也就不能 connect，
        // 谁发来都得收。所以这里没什么可落实的，没回 interleaved 就算谈成了。
        if transportMode == .udp, videoUDP != nil {
            guard let transport, let assigned = Self.interleavedChannel(transport) else {
                return true
            }
            // 反过来了：我们要 UDP，它给交织。跟着它走。
            fallBackToInterleaved()
            videoChannel = assigned
            return true
        }

        if let transport, let assigned = Self.interleavedChannel(transport) {
            // 服务器可以改通道号，按它回的为准。
            videoChannel = assigned
            return true
        }

        if transport != nil {
            // 明确回了 Transport 但没有 interleaved：服务器不肯走 TCP。
            finish(with: .unsupportedTransport)
            return false
        }

        // 完全没回 Transport 头。有设备就是这么省事，按我们请求的通道继续。
        return true
    }

    /// 从 Transport 头里取 interleaved 的起始通道。
    static func interleavedChannel(_ transport: String) -> Int? {
        for part in transport.split(separator: ";") {
            let piece = part.trimmed
            guard piece.lowercased().hasPrefix("interleaved") else { continue }
            guard let (_, value) = piece.splitOnce("=") else { continue }
            let first = value.split(separator: "-").first.map(String.init) ?? value
            return Int(first.trimmed)
        }
        return nil
    }

    // MARK: - PLAY

    func sendPlay() {
        guard let sessionID else {
            finish(with: .sessionMissing)
            return
        }
        var request = RTSPRequest(method: .play, uri: aggregateURI)
        request.set("Session", sessionID)
        request.set("Range", "npt=0.000-")
        authorize(&request)
        connection.send(request) { [weak self] result in
            guard let self, !self.isStopped else { return }
            switch result {
            case .failure(let error):
                self.finish(with: error)
            case .success(let response):
                if self.retryIfUnauthorized(response, retry: { self.sendPlay() }) { return }
                guard response.isSuccess else {
                    self.finish(with: .status(code: response.statusCode,
                                              reason: response.reasonPhrase,
                                              method: "PLAY"))
                    return
                }
                // RTP-Info 给出这一路的起始时间戳，时间轴以它为原点。
                if let rtpInfo = response.value("RTP-Info") {
                    let origin = Self.parseRTPInfo(rtpInfo,
                                                   videoControl: self.videoMedia?.control)
                    self.clock?.applyRTPInfo(origin)
                }
                self.setStage(.playing)
                self.startKeepAlive()
                self.startStatistics()
                self.startFirstMediaWatchdog()
            }
        }
    }

    /// RTP-Info: url=...;seq=1;rtptime=900,url=...;seq=1;rtptime=480
    ///
    /// 只取视频那一段。设备照旧会把音频段一起回来（我们没 SETUP 音频，
    /// 但有固件不管这个），所以匹配不上 control 时不能盲取第一段 ——
    /// 那可能是音频的 rtptime，拿它当视频原点会让首帧 PTS 整体偏掉。
    static func parseRTPInfo(_ raw: String, videoControl: String?) -> UInt32? {
        // 按 url= 切段，段内的逗号不会误伤（rtptime 不含逗号）。
        let segments = raw.split(separator: ",").map { $0.trimmed }
        var unmatched: [UInt32] = []
        for segment in segments {
            var streamURL = ""
            var rtptime: UInt32?
            for field in segment.split(separator: ";") {
                guard let (key, value) = field.trimmed.splitOnce("=") else { continue }
                switch key.trimmed.lowercased() {
                case "url":     streamURL = value.trimmed
                case "rtptime": rtptime = UInt32(value.trimmed)
                default:        break
                }
            }
            guard let rtptime else { continue }
            if let control = videoControl, !control.isEmpty,
               streamURL.hasSuffix(control) || control.hasSuffix(streamURL) {
                return rtptime
            }
            unmatched.append(rtptime)
        }
        // control 匹配不上时才按顺序兜底，且只在唯一一段时才敢用。
        return unmatched.count == 1 ? unmatched[0] : nil
    }
}
