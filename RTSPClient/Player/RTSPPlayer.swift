//
//  RTSPPlayer.swift
//  RTSPClient
//
//  串起会话、渲染和历史记录的协调者。
//  会话回调在网络队列上触发：样本直接交给渲染器（它自带队列），
//  状态变更切回主线程，用 DispatchQueue.main 保证先后顺序。
//

import Foundation
import Observation
import AVFoundation

@Observable
final class RTSPPlayer {
    enum State: Equatable {
        case idle
        case connecting
        /// 已连上，等第一帧画面。
        case buffering
        case playing
        case paused
        case failed(String)

        var isActive: Bool {
            switch self {
            case .connecting, .buffering, .playing, .paused: return true
            case .idle, .failed:                             return false
            }
        }
    }

    /// 默认地址：常见的设备出厂地址。
    static let defaultAddress = "rtsp://192.168.0.1/livestream/1/"

    private(set) var state: State = .idle
    private(set) var mediaInfo: RTSPSession.MediaInfo?
    private(set) var statistics: RTSPSession.Statistics?
    private(set) var currentAddress: String?
    /// 认证失败时置位，UI 弹出账号密码输入。
    var needsCredentials = false
    private(set) var reconnectAttempt = 0
    var isMuted = false {
        didSet { renderer.setMuted(isMuted) }
    }

    let renderer = MediaRenderer(enableAudio: true)
    private let history: StreamHistoryStore
    private var session: RTSPSession?
    private var currentURL: RTSPURL?
    private var reconnectWork: DispatchWorkItem?
    /// PLAY 成功后守着首帧，超时就报出具体原因而不是一直转圈。
    private var bufferingWatchdog: DispatchWorkItem?
    /// 用户主动停止后不再自动重连。
    private var stoppedByUser = false
    /// 这个地址上 UDP 已经证明不通，之后一律走交织。
    ///
    /// 记在播放器这一层而不是会话里：换传输方式要一条全新的 TCP 连接，
    /// 而重连本来就是这一层的活。只在 play(address:) 里清掉，
    /// 所以同一个地址反复重连不会每次都白等 3 秒。
    private var forcedInterleaved = false

    private static let maxReconnectAttempts = 5
    /// PLAY 成功到出第一帧的容忍时间。起播闸门最多等 5 秒流内时间，留足余量。
    private static let firstFrameTimeout: TimeInterval = 12

    init(history: StreamHistoryStore) {
        self.history = history
    }
    // MARK: - 播放控制

    /// 开始播放。地址里可以带 user:password@。
    func play(address: String) {
        guard let url = RTSPURL(string: address) else {
            state = .failed(RTSPError.invalidURL(address).localizedDescription)
            return
        }
        stopInternal(userInitiated: true)
        stoppedByUser = false
        reconnectAttempt = 0
        needsCredentials = false
        statistics = nil
        mediaInfo = nil
        currentURL = url
        currentAddress = url.displayString
        // 新地址重新试一遍 UDP：上一个地址不通不代表这个也不通。
        forcedInterleaved = false
        history.recordPlayback(url: url)
        startSession(url: url)
    }

    /// 从历史条目播放，自动带上存过的密码。
    func play(entry: StreamHistoryEntry) {
        play(address: history.resolvedAddress(for: entry))
    }

    /// 补齐凭据后重试当前地址。
    func retryWithCredentials(username: String, password: String) {
        guard var url = currentURL else { return }
        url.username = username
        url.password = password
        needsCredentials = false
        reconnectAttempt = 0
        stopInternal(userInitiated: true)
        stoppedByUser = false
        currentURL = url
        currentAddress = url.displayString
        history.recordPlayback(url: url)
        startSession(url: url)
    }

    func stop() {
        stopInternal(userInitiated: true)
        state = .idle
        statistics = nil
        // 交还音频会话，别一直占着别的 App 的播放权。
        AudioSessionSupport.deactivate()
    }

    func pause() {
        guard state == .playing else { return }
        renderer.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        renderer.resume()
        state = .playing
    }

    func togglePause() {
        switch state {
        case .playing: pause()
        case .paused:  resume()
        default:       break
        }
    }

    /// 手动重连当前地址。
    func reload() {
        guard let url = currentURL else { return }
        stopInternal(userInitiated: true)
        stoppedByUser = false
        reconnectAttempt = 0
        startSession(url: url)
    }

    // MARK: - 会话

    private func startSession(url: RTSPURL) {
        state = .connecting
        // iOS 上不激活音频会话就没有声音。
        AudioSessionSupport.activate()
        let session = RTSPSession(url: url, wantsAudio: true,
                                  transport: forcedInterleaved ? .interleaved : .udp) {
            [weak self] event in
            // 网络队列上触发，需要主线程的部分自己切。
            self?.handle(event)
        }
        self.session = session
        renderer.setFirstFrameHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.state.isActive, self.state != .paused else { return }
                self.bufferingWatchdog?.cancel()
                self.bufferingWatchdog = nil
                self.state = .playing
            }
        }
        renderer.setMuted(isMuted)
        session.start()
    }

    private func stopInternal(userInitiated: Bool) {
        if userInitiated { stoppedByUser = true }
        reconnectWork?.cancel()
        reconnectWork = nil
        bufferingWatchdog?.cancel()
        bufferingWatchdog = nil
        session?.stop()
        session = nil
        renderer.stop()
    }

    /// 会话事件入口。样本直送渲染器，其余切主线程改状态。
    private nonisolated func handle(_ event: RTSPSession.Event) {
        switch event {
        case .video(let box):
            renderer.enqueueVideo(box.buffer)
        case .audio(let box):
            renderer.enqueueAudio(box.buffer)
        case .formatChanged:
            renderer.flushForFormatChange()
        case .stage(let stage):
            DispatchQueue.main.async { self.applyStage(stage) }
        case .info(let info):
            DispatchQueue.main.async { self.applyInfo(info) }
        case .statistics(let stats):
            DispatchQueue.main.async { self.statistics = stats }
        case .failed(let error):
            DispatchQueue.main.async { self.applyFailure(error) }
        }
    }

    private func applyStage(_ stage: RTSPSession.Stage) {
        switch stage {
        case .connecting, .describing, .settingUp:
            if state != .paused { state = .connecting }
        case .playing:
            // 收到 PLAY 成功，但真正起播要等第一帧解出来。
            if state != .paused {
                state = .buffering
                startBufferingWatchdog()
            }
            reconnectAttempt = 0
        case .stopped:
            break
        }
    }

    /// PLAY 成功却一直没有画面时，把「卡在哪一步」说清楚。
    /// 以前这里没有兜底，遇到服务器不走 TCP 交织、或者摄像机不发关键帧，
    /// 界面就永远停在「缓冲中」，用户完全无从判断。
    private func startBufferingWatchdog() {
        bufferingWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .buffering else { return }
            self.bufferingWatchdog = nil
            self.stopInternal(userInitiated: true)
            self.state = .failed(self.stalledDiagnosis)
        }
        bufferingWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstFrameTimeout, execute: work)
    }

    /// 按统计数据区分是「一个字节都没来」还是「来了但解不出画面」。
    private var stalledDiagnosis: String {
        let received = statistics?.bytesReceived ?? 0
        let frames = statistics?.videoFrames ?? 0
        if received == 0 {
            // UDP 和 TCP 交织都试过了（UDP 收不到会自动换交织再来一轮），
            // 两条路都没数据，剩下的可能就是被网络拦了或者设备只是不发。
            return "PLAY 成功但 UDP 和 TCP 交织两种方式都没有收到媒体数据，"
                + "可能被防火墙拦截，或设备未真正推流"
        }
        if frames == 0 {
            return "收到了数据但解不出画面，视频编码可能不受支持"
        }
        return "解出了画面但无法显示，解码器可能已停止工作"
    }

    private func applyInfo(_ info: RTSPSession.MediaInfo) {
        mediaInfo = info
        guard let identity = currentURL?.identity else { return }
        history.updateMediaInfo(identity: identity, codec: info.videoCodec,
                                width: Int(info.width), height: Int(info.height))
    }

    private func applyFailure(_ error: RTSPError) {
        session = nil
        renderer.stop()

        if error.isAuthError {
            needsCredentials = true
            state = .failed(error.localizedDescription)
            return
        }
        // UDP 上一个字节都没来。立刻换 TCP 交织重来 —— 这不是网络故障，
        // 不该走退避，也不该记进重连次数（用户看到「重连中」会以为线路有问题）。
        if error == .udpNoData, !stoppedByUser, !forcedInterleaved, let url = currentURL {
            forcedInterleaved = true
            bufferingWatchdog?.cancel()
            bufferingWatchdog = nil
            state = .connecting
            startSession(url: url)
            return
        }
        guard !stoppedByUser, error != .cancelled else {
            if state != .idle, !stoppedByUser { state = .failed(error.localizedDescription) }
            return
        }
        // 网络类错误自动退避重连，摄像机重启或 Wi-Fi 抖动都很常见。
        guard let url = currentURL, reconnectAttempt < Self.maxReconnectAttempts else {
            state = .failed(error.localizedDescription)
            return
        }
        reconnectAttempt += 1
        state = .connecting
        let delay = min(8, pow(2, Double(reconnectAttempt - 1)))
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stoppedByUser else { return }
            self.startSession(url: url)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 展示辅助

    var statusText: String {
        switch state {
        case .idle:                 return "未播放"
        case .connecting:
            return reconnectAttempt > 0 ? "重连中（第 \(reconnectAttempt) 次）" : "连接中"
        case .buffering:            return "缓冲中"
        case .playing:              return "播放中"
        case .paused:               return "已暂停"
        case .failed(let message):  return message
        }
    }

    var formatText: String? {
        guard let mediaInfo else { return nil }
        var parts: [String] = []
        if let codec = mediaInfo.videoCodec { parts.append(codec) }
        if mediaInfo.width > 0 { parts.append("\(mediaInfo.width)×\(mediaInfo.height)") }
        if let audio = mediaInfo.audioCodec { parts.append(audio) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
