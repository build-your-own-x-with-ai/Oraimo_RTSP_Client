//
//  RTSPSession.swift
//  RTSPClient
//
//  握手流程：OPTIONS -> DESCRIBE -> SETUP -> PLAY，
//  之后按 Session 的 timeout 定时发保活请求。
//  所有状态都只在 connection.queue 上访问。
//
//  只收视频。SDP 里的音频轨不 SETUP，但它声明的负载类型要留着 ——
//  见 audioPayloadType。
//

import Foundation
import CoreMedia

nonisolated final class RTSPSession: @unchecked Sendable {
    struct MediaInfo: Sendable, Equatable {
        var videoCodec: String?
        var width: Int32 = 0
        var height: Int32 = 0
        var sessionName: String = ""
    }

    struct Statistics: Sendable, Equatable {
        var bytesReceived: Int = 0
        var videoFrames: Int = 0
        var droppedPackets: Int = 0
        var bitrateKbps: Double = 0
        var fps: Double = 0
    }

    enum Stage: Sendable, Equatable {
        case connecting, describing, settingUp, playing, stopped
    }

    /// RTP 走哪条路。
    ///
    /// 默认先试 UDP：抓包对比过 VLC，摄像机那边压根没有 TCP 交织这条路，
    /// SETUP 里只认 `RTP/AVP;unicast;client_port=...`。以前只发交织请求，
    /// 于是一个字节都收不到，界面永远停在「缓冲中」。
    /// UDP 不通时退回交织 —— 有些 NVR 反过来只给交织。
    enum TransportMode: Sendable, Equatable { case udp, interleaved }

    enum Event: Sendable {
        case stage(Stage)
        case info(MediaInfo)
        case video(SampleBox)
        case formatChanged
        case statistics(Statistics)
        case failed(RTSPError)
    }

    // 下面这些状态跨文件的 extension（握手、收流）要访问，所以是 internal 而非
    // private。约束不变：只在 connection.queue 上读写。
    let url: RTSPURL
    let connection: RTSPConnection
    let events: (Event) -> Void
    var authenticator: RTSPAuthenticator?

    /// DESCRIBE 应答定下的基址，SDP 里的相对 control 都按它解析。
    /// 应答到手之前等于请求 URL —— OPTIONS/DESCRIBE 发的就是它。
    var baseURI: String
    /// 聚合控制的 URI，PLAY / keep-alive / TEARDOWN 用这个。
    /// 会话级 `a=control:` 给了绝对地址就用它，否则就是基址。
    var aggregateURI: String

    var sessionID: String?
    var sessionTimeout = 60
    var stage: Stage = .connecting
    var isStopped = false

    /// interleaved 通道号：RTP 0，RTCP 1。
    var videoChannel = 0

    /// 当前传输方式，SETUP 期间可能被服务器的应答改掉。
    var transportMode: TransportMode
    var videoUDP: RTPUDPTransport?
    /// PLAY 之后守着第一个 RTP 包；UDP 收不到就换交织重来。
    var firstMediaWatchdog: DispatchSourceTimer?
    var didReceiveMedia = false
    /// UDP 起播的宽限时间。局域网里摄像机在 PLAY 应答之后马上就发，
    /// 3 秒足够；真被防火墙挡了也不用让用户等满 12 秒的首帧超时。
    static let udpFirstMediaTimeout: TimeInterval = 3

    /// SDP 声明的视频负载类型。
    var videoPayloadType = -1
    /// SDP 声明的音频负载类型。音频不播，但这个值必须留着。
    ///
    /// 有固件不管客户端 SETUP 了什么，照样把音频往视频那一路发。不按负载类型
    /// 把它挡在视频解包器外面，后果分两种，都实测过（同一段字节流，
    /// 只把这道保护关掉作对照）：
    ///
    /// - PCMA：裸样本字节被当成 H.264 NAL 解，凭空造出假帧。
    ///   126 帧 / 6 关键帧 / 0 乱序 → 151 帧 / 12 关键帧 / 22 乱序。
    /// - AAC：负载头两字节是 00 10，NAL type 0 是 unspecified，解包器直接丢，
    ///   所以帧数不变；但音频的 RTP 序号会污染丢包统计，
    ///   丢包 0 → 823，界面上会显示一条完好的流「丢包 823」。
    ///
    /// 所以这不是音频功能，是画面和统计的正确性保障。
    /// 复现：matrix.sh 里的 mismux_pcma / ctl_pcma / mismux_tcp / ctl_aac。
    var audioPayloadType = -1

    var videoMedia: SDPMedia?
    var videoDepacketizer: VideoDepacketizer?
    var clock: MediaClock?
    var info = MediaInfo()

    var videoFormat: CMFormatDescription?
    var lastFrameDuration = CMTime(value: 1, timescale: 30)
    var lastVideoPTS: CMTime?

    var keepAlive: DispatchSourceTimer?
    var statsTimer: DispatchSourceTimer?
    var supportsGetParameter = false
    var stats = Statistics()
    var statsWindowBytes = 0
    var statsWindowFrames = 0
    var statsWindowStart = CFAbsoluteTimeGetCurrent()
    var videoLoss = RTPLossCounter()

    init(url: RTSPURL, transport: TransportMode = .udp,
         events: @escaping (Event) -> Void) {
        self.url = url
        self.baseURI = url.requestURI
        self.aggregateURI = url.requestURI
        self.transportMode = transport
        self.events = events
        self.connection = RTSPConnection(host: url.host, port: url.port, usesTLS: url.usesTLS)
        if let user = url.username {
            self.authenticator = RTSPAuthenticator(username: user, password: url.password ?? "")
        }
    }

    /// 播放中途补上凭据时用（先前 401）。
    func setCredentials(username: String, password: String) {
        connection.queue.async {
            self.authenticator = RTSPAuthenticator(username: username, password: password)
        }
    }

    var queue: DispatchQueue { connection.queue }

    // MARK: - 生命周期

    func start() {
        connection.start(events: { [weak self] event in
            self?.handle(event)
        }, ready: { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(with: error)
                return
            }
            self.sendOptions()
        })
    }

    func stop() {
        connection.queue.async {
            guard !self.isStopped else { return }
            self.isStopped = true
            self.keepAlive?.cancel(); self.keepAlive = nil
            self.statsTimer?.cancel(); self.statsTimer = nil
            self.firstMediaWatchdog?.cancel(); self.firstMediaWatchdog = nil
            self.closeUDP()
            // 尽力发一次 TEARDOWN，成不成都要关连接。
            if let sessionID = self.sessionID {
                var request = RTSPRequest(method: .teardown, uri: self.aggregateURI)
                request.set("Session", sessionID)
                self.authorize(&request)
                self.connection.send(request, timeout: 2) { _ in }
            }
            self.stage = .stopped
            self.connection.queue.asyncAfter(deadline: .now() + 0.15) {
                self.connection.close()
            }
        }
    }

    func finish(with error: RTSPError) {
        guard !isStopped else { return }
        isStopped = true
        keepAlive?.cancel(); keepAlive = nil
        statsTimer?.cancel(); statsTimer = nil
        firstMediaWatchdog?.cancel(); firstMediaWatchdog = nil
        closeUDP()
        stage = .stopped
        events(.failed(error))
        connection.close()
    }

    /// 收掉 UDP 端口。必须走到：socket 的 fd 归 DispatchSource 管，
    /// 不 cancel 就一直挂着。
    func closeUDP() {
        videoUDP?.close(); videoUDP = nil
    }

    func setStage(_ new: Stage) {
        guard stage != new, !isStopped else { return }
        stage = new
        events(.stage(new))
    }

    // MARK: - 请求装配

    func authorize(_ request: inout RTSPRequest) {
        request.set("User-Agent", "RTSPClient/1.0 (Darwin)")
        if let header = authenticator?.authorization(method: request.method.rawValue,
                                                    uri: request.uri) {
            request.set("Authorization", header)
        }
    }

    /// 401 处理：更新挑战后重试一次。返回 true 表示已经重试。
    func retryIfUnauthorized(_ response: RTSPResponse,
                             retry: @escaping () -> Void) -> Bool {
        guard response.statusCode == 401 else { return false }
        guard let challenge = RTSPAuthChallenge.best(from: response.values("WWW-Authenticate"))
        else {
            finish(with: .authenticationFailed)
            return true
        }
        guard let authenticator else {
            finish(with: .authenticationRequired)
            return true
        }
        guard authenticator.update(with: challenge) else {
            finish(with: .authenticationFailed)
            return true
        }
        retry()
        return true
    }
}
