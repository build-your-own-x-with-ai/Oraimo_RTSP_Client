//
//  RTSPSession.swift
//  RTSPClient
//
//  握手流程：OPTIONS -> DESCRIBE -> SETUP(视频) -> SETUP(音频) -> PLAY，
//  之后按 Session 的 timeout 定时发保活请求。
//  所有状态都只在 connection.queue 上访问。
//

import Foundation
import CoreMedia

nonisolated final class RTSPSession: @unchecked Sendable {
    struct MediaInfo: Sendable, Equatable {
        var videoCodec: String?
        var audioCodec: String?
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

    /// 哪一条轨。SETUP 流程必须显式带着它走，不能靠通道号反推。
    enum Track: Sendable, Equatable { case video, audio }

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
        case audio(SampleBox)
        case formatChanged
        case statistics(Statistics)
        case failed(RTSPError)
    }

    // 下面这些状态跨文件的 extension（握手、收流）要访问，所以是 internal 而非
    // private。约束不变：只在 connection.queue 上读写。
    let url: RTSPURL
    let wantsAudio: Bool
    let connection: RTSPConnection
    let events: (Event) -> Void
    var authenticator: RTSPAuthenticator?

    var sessionID: String?
    var sessionTimeout = 60
    var stage: Stage = .connecting
    var isStopped = false

    /// interleaved 通道号：视频 0/1，音频 2/3。
    var videoChannel = 0
    var audioChannel = 2

    /// 当前传输方式，SETUP 期间可能被服务器的应答改掉。
    var transportMode: TransportMode
    var videoUDP: RTPUDPTransport?
    var audioUDP: RTPUDPTransport?
    /// PLAY 之后守着第一个 RTP 包；UDP 收不到就换交织重来。
    var firstMediaWatchdog: DispatchSourceTimer?
    var didReceiveMedia = false
    /// UDP 起播的宽限时间。局域网里摄像机在 PLAY 应答之后马上就发，
    /// 3 秒足够；真被防火墙挡了也不用让用户等满 12 秒的首帧超时。
    static let udpFirstMediaTimeout: TimeInterval = 3

    /// SDP 声明的负载类型。两条轨被塞进同一个通道时靠它把数据分开；
    /// 即使音频轨后来被丢掉，这个值也要留着，用来把音频包挡在视频解包器外面。
    var videoPayloadType = -1
    var audioPayloadType = -1

    var videoMedia: SDPMedia?
    var audioMedia: SDPMedia?
    var videoDepacketizer: VideoDepacketizer?
    var audioDepacketizer: AudioDepacketizer?
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

    init(url: RTSPURL, wantsAudio: Bool, transport: TransportMode = .udp,
         events: @escaping (Event) -> Void) {
        self.url = url
        self.wantsAudio = wantsAudio
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
                var request = RTSPRequest(method: .teardown, uri: self.url.requestURI)
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
        audioUDP?.close(); audioUDP = nil
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
