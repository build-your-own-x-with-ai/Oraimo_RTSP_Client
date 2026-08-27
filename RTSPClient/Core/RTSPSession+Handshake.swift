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

            if wantsAudio, let audio = sdp.audio,
               let audioDepacketizer = AudioDepacketizer(media: audio) {
                audioMedia = audio
                audioPayloadType = audio.payloadType
                self.audioDepacketizer = audioDepacketizer
                info.audioCodec = audio.codec == "MPEG4-GENERIC" ? "AAC" : audio.codec
            }

            clock = MediaClock(videoClockRate: video.clockRate,
                               audioClockRate: audioDepacketizer?.clockRate ?? 90000)
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

    // MARK: - SETUP

    private func setupVideo() {
        setStage(.settingUp)
        guard let media = videoMedia else {
            finish(with: .noSupportedMedia)
            return
        }
        // 端口开不出来就整个会话走交织。视频是第一条 SETUP 的轨，
        // 这个决定发生在任何请求发出之前，不会出现两条轨走不同路。
        if !prepareUDP(track: .video) { fallBackToInterleaved() }
        sendSetup(track: .video, control: media.control, channel: videoChannel) {
            [weak self] in
            guard let self else { return }
            if self.audioMedia != nil { self.setupAudio() } else { self.sendPlay() }
        }
    }

    private func setupAudio() {
        guard let media = audioMedia else {
            sendPlay()
            return
        }
        // 音频的端口开不出来时只丢音频：视频可能已经在 UDP 上谈成了，
        // 这时候把整个会话拽回交织会把画面一起弄没。
        if !prepareUDP(track: .audio) {
            dropAudio(then: { [weak self] in self?.sendPlay() })
            return
        }
        sendSetup(track: .audio, control: media.control, channel: audioChannel) {
            [weak self] in
            self?.sendPlay()
        }
    }

    /// UDP 模式下开好这条轨的收包端口。返回 false 表示没开出来。
    private func prepareUDP(track: Track) -> Bool {
        guard transportMode == .udp else { return true }
        guard let transport = RTPUDPTransport(queue: connection.queue) else { return false }
        // SETUP 之前就开始收：有固件在应答落地之前就往 client_port 发包了。
        transport.start { [weak self] datagram in
            self?.handleUDP(datagram, track: track)
        }
        switch track {
        case .video: videoUDP = transport
        case .audio: audioUDP = transport
        }
        return true
    }

    /// 放弃 UDP 改走 TCP 交织，之后的 SETUP 都发交织请求。
    func fallBackToInterleaved() {
        transportMode = .interleaved
        closeUDP()
    }

    /// track 必须显式传入：不能靠通道号反推是哪条轨。
    /// 服务器重编号后视频通道可能与音频的初始值相同，
    /// 那时用通道号判断会把两路认反，数据就整体串了。
    private func sendSetup(track: Track, control: String, channel: Int,
                           next: @escaping () -> Void) {
        let uri = url.appendingControl(control)
        var request = RTSPRequest(method: .setup, uri: uri)
        request.set("Transport", transportHeader(track: track, channel: channel))
        if let sessionID { request.set("Session", sessionID) }
        authorize(&request)
        connection.send(request) { [weak self] result in
            guard let self, !self.isStopped else { return }
            switch result {
            case .failure(let error):
                self.finish(with: error)
            case .success(let response):
                let retried = self.retryIfUnauthorized(response, retry: {
                    self.sendSetup(track: track, control: control,
                                   channel: channel, next: next)
                })
                if retried { return }
                guard response.isSuccess else {
                    // 音频 SETUP 失败不必整个失败，丢掉音频继续播画面。
                    if track == .audio {
                        self.dropAudio(then: next)
                        return
                    }
                    // 461 Unsupported Transport 之类：换交织在同一条连接上再试一次。
                    // fallBackToInterleaved() 会把 transportMode 改掉，所以不会来回弹。
                    if self.transportMode == .udp {
                        self.fallBackToInterleaved()
                        self.sendSetup(track: track, control: control,
                                       channel: channel, next: next)
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
                guard self.applyTransport(response, track: track, then: next) else { return }
                next()
            }
        }
    }

    /// 这条轨的 Transport 请求头。
    ///
    /// UDP 那行照 VLC 抓包里的原样发。摄像机只认这个形状，多写
    /// destination / mode 之类的参数反而有固件会整条判错。
    private func transportHeader(track: Track, channel: Int) -> String {
        if transportMode == .udp {
            let udp = track == .video ? videoUDP : audioUDP
            if let udp {
                return "RTP/AVP;unicast;client_port=\(udp.rtpPort)-\(udp.rtcpPort)"
            }
        }
        return "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)"
    }

    /// 落实服务器回的 Transport。返回 false 表示已经处理完（失败或丢音频），
    /// 调用方不要再往下走。
    ///
    /// 两个方向都要认：请求交织却回了 UDP，是服务器不肯走交织；请求 UDP 却回了
    /// interleaved，是服务器只给交织。按 RFC 2326，Transport 里不写 "TCP"
    /// 时默认就是 UDP，所以判断只能看有没有 interleaved 参数，不能找 "UDP" 字面。
    private func applyTransport(_ response: RTSPResponse, track: Track,
                                then next: @escaping () -> Void) -> Bool {
        let transport = response.value("Transport")

        // 请求的是 UDP。摄像机的应答里既没有 server_port 也没有 source，
        // 只把 client_port 抄回来 —— 发送端口无从得知，socket 也就不能 connect，
        // 谁发来都得收。所以这里没什么可落实的，没回 interleaved 就算谈成了。
        if transportMode == .udp, videoUDP != nil || audioUDP != nil {
            guard let transport, let assigned = Self.interleavedChannel(transport) else {
                return true
            }
            // 反过来了：我们要 UDP，它给交织。跟着它走。
            fallBackToInterleaved()
            switch track {
            case .video: videoChannel = assigned
            case .audio:
                guard assigned != videoChannel else {
                    dropAudio(then: next)
                    return false
                }
                audioChannel = assigned
            }
            return true
        }

        if let transport, let assigned = Self.interleavedChannel(transport) {
            // 服务器可以改通道号，按它回的为准。
            switch track {
            case .video:
                videoChannel = assigned
            case .audio:
                // 有固件会把两条轨回成同一个通道，那样音频包会被当视频解。
                // 宁可不要声音，也不能把画面搞坏。
                guard assigned != videoChannel else {
                    dropAudio(then: next)
                    return false
                }
                audioChannel = assigned
            }
            return true
        }

        if transport != nil {
            // 明确回了 Transport 但没有 interleaved：服务器不肯走 TCP。
            if track == .audio {
                dropAudio(then: next)
                return false
            }
            finish(with: .unsupportedTransport)
            return false
        }

        // 完全没回 Transport 头。有设备就是这么省事，按我们请求的通道继续。
        return true
    }

    /// 放弃音频轨，只播画面。
    private func dropAudio(then next: @escaping () -> Void) {
        audioMedia = nil
        audioDepacketizer = nil
        info.audioCodec = nil
        events(.info(info))
        next()
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
        var request = RTSPRequest(method: .play, uri: url.requestURI)
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
                // RTP-Info 给出两路的起始时间戳，音视频靠它对齐。
                if let rtpInfo = response.value("RTP-Info") {
                    let origins = Self.parseRTPInfo(rtpInfo,
                                                    videoControl: self.videoMedia?.control,
                                                    audioControl: self.audioMedia?.control)
                    self.clock?.applyRTPInfo(video: origins.video, audio: origins.audio)
                }
                self.setStage(.playing)
                self.startKeepAlive()
                self.startStatistics()
                self.startFirstMediaWatchdog()
            }
        }
    }

    /// RTP-Info: url=...;seq=1;rtptime=900,url=...;seq=1;rtptime=480
    static func parseRTPInfo(_ raw: String, videoControl: String?, audioControl: String?)
    -> (video: UInt32?, audio: UInt32?) {
        var result: (video: UInt32?, audio: UInt32?) = (nil, nil)
        // 按 url= 切段，段内的逗号不会误伤（rtptime 不含逗号）。
        let segments = raw.split(separator: ",").map { $0.trimmed }
        var ordered: [UInt32] = []
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
            // 优先按 control 匹配，匹配不上再按出现顺序兜底。
            if let control = videoControl, !control.isEmpty,
               streamURL.hasSuffix(control) || control.hasSuffix(streamURL) {
                result.video = rtptime
            } else if let control = audioControl, !control.isEmpty,
                      streamURL.hasSuffix(control) || control.hasSuffix(streamURL) {
                result.audio = rtptime
            } else {
                ordered.append(rtptime)
            }
        }
        if result.video == nil, let first = ordered.first { result.video = first }
        if result.audio == nil, audioControl != nil, ordered.count > 1 {
            result.audio = ordered[1]
        }
        return result
    }
}
