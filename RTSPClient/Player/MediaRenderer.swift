//
//  MediaRenderer.swift
//  RTSPClient
//
//  用 AVSampleBufferRenderSynchronizer 驱动视频层，按 PTS 播放。
//
//  直播没有固定时长，时钟起点取首帧 PTS 往前挪一点作为缓冲；
//  摄像机时钟和本机时钟长期有漂移，所以延迟超限时把时基往前跳一次。
//

import Foundation
import AVFoundation
import CoreMedia

nonisolated final class MediaRenderer: @unchecked Sendable {
    /// 预缓冲的起点。这一段直接计入端到端延迟：设成多少，画面就至少落后多少。
    ///
    /// 原来是固定 250ms，那是为了音视频同步和音频渲染器不断流才给这么足 ——
    /// 音频一旦欠数据就会爆音，视频卡一帧只是不流畅。只收视频之后这个顾虑没了，
    /// 局域网直连的到达抖动也就几毫秒，80ms（30fps 下约 2 帧）够吸收。
    private static let basePreroll = CMTime(value: 80, timescale: 1000)
    /// 预缓冲的上限。乱序再深也不再往上加。
    private static let maxPreroll = CMTime(value: 400, timescale: 1000)

    /// 实际使用的预缓冲。从 basePreroll 起步，遇到乱序会往上长，只长不缩。
    ///
    /// 为什么不能固定成 80ms：带 B 帧的流在解码顺序里 PTS 不单调，帧送进渲染器
    /// 时它的 PTS 可能已经过去了。实测那条 H.265 流乱序幅度 120ms，固定 80ms
    /// 会让 85 帧里 40 帧「迟到」（最多迟 44.7ms），画面就是顿。
    ///
    /// 为什么不干脆固定成 250ms：摄像机直播基本都是 baseline/main 不带 B 帧，
    /// 实测 H.264 抓包和那台 Oraimo 的真实流乱序幅度都是 0。为了少数带 B 帧的流
    /// 让所有人一直背着 170ms 延迟不值得。
    ///
    /// 所以按实际观测到的欠量长：第一个迟到帧就把这条流的乱序深度暴露了，
    /// 补上欠量之后就不再迟到。只长不缩 —— 乱序深度是流的属性，缩回去只会再迟一次。
    private var preroll = MediaRenderer.basePreroll

    /// 累计延迟超过这个值就重置时基，防止越播越滞后。
    ///
    /// 原来固定 1200ms，那个宽松的阈值是怕跳时基把音频跳出爆音；现在跳一次
    /// 最多是画面顿一下，不值得为它一直背着一秒多的延迟，所以收到 500ms。
    /// 下界必须留在 preroll 之上：preroll 因乱序长上去之后，正常的 lag 就等于
    /// preroll，阈值贴着它会把正常状态误判成漂移，反复重置时基。
    private var maxLatency: CMTime {
        CMTimeMaximum(CMTime(value: 500, timescale: 1000),
                      CMTimeAdd(preroll, CMTime(value: 200, timescale: 1000)))
    }

    /// 期望在主线程创建（CALayer 不是线程安全的）。
    let displayLayer = AVSampleBufferDisplayLayer()

    private let videoRenderer: AVSampleBufferVideoRenderer
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "com.iosdevlog.rtsp.render")

    private var clockStarted = false
    private var onFirstFrame: (() -> Void)?

    init() {
        videoRenderer = displayLayer.sampleBufferRenderer
        synchronizer.addRenderer(videoRenderer)
    }

    func setFirstFrameHandler(_ handler: @escaping () -> Void) {
        queue.async { self.onFirstFrame = handler }
    }

    // MARK: - 送样本

    func enqueueVideo(_ buffer: CMSampleBuffer) {
        // 样本在会话队列建好后就只交给渲染队列，不存在并发访问。
        let box = SampleBox(buffer)
        queue.async {
            let buffer = box.buffer
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            self.startClockIfNeeded(at: pts)
            // 乱序的流要先把预缓冲补够，再决定这一帧怎么送。
            self.growPrerollIfLate(pts)
            // iOS 上进过后台、或解码器出错之后，必须 flush 才会重新开始解码。
            // 不处理的话画面就永远停住，而 enqueue 依旧「成功」，看不出问题。
            if self.videoRenderer.requiresFlushToResumeDecoding {
                self.videoRenderer.flush()
            }
            // 解码器来不及就丢非关键帧，宁可跳一下也不要越积越多。
            guard self.videoRenderer.isReadyForMoreMediaData
                    || buffer.isKeyframeSample else { return }
            self.videoRenderer.enqueue(buffer)
            self.rebaseIfDrifting(pts)
            if let handler = self.onFirstFrame {
                self.onFirstFrame = nil
                handler()
            }
        }
    }

    /// 换分辨率 / 参数集时清一次队列，避免旧尺寸的帧混进来。
    func flushForFormatChange() {
        queue.async { self.videoRenderer.flush() }
    }

    // MARK: - 播放控制

    func pause() {
        queue.async { self.synchronizer.setRate(0, time: self.synchronizer.currentTime()) }
    }

    func resume() {
        queue.async {
            guard self.clockStarted else { return }
            self.synchronizer.setRate(1, time: self.synchronizer.currentTime())
        }
    }

    func stop() {
        queue.async {
            self.synchronizer.setRate(0, time: .zero)
            self.videoRenderer.flush()
            self.clockStarted = false
            self.onFirstFrame = nil
            // 换一条流可能压根不乱序，长上去的预缓冲不该带过去。
            self.preroll = Self.basePreroll
        }
    }

    /// 当前播放时刻，用于统计显示。
    var currentTime: CMTime { synchronizer.currentTime() }

    // MARK: - 时基

    private func startClockIfNeeded(at pts: CMTime) {
        guard !clockStarted, pts.isValid else { return }
        clockStarted = true
        // 从首帧 PTS 减去预缓冲开始跑，给后续帧留出到达时间。
        synchronizer.setRate(1, time: CMTimeSubtract(pts, preroll))
    }

    /// 帧送进来时 PTS 已经过去了，说明预缓冲装不下这条流的乱序幅度。
    ///
    /// 按欠量把 preroll 补上，再把时基往回挪一次。这一下会让画面顿一次，
    /// 但只发生在遇到第一个迟到帧时 —— 补够之后就不再触发。
    private func growPrerollIfLate(_ pts: CMTime) {
        guard clockStarted, pts.isValid,
              CMTimeCompare(preroll, Self.maxPreroll) < 0 else { return }
        let now = synchronizer.currentTime()
        guard now.isValid else { return }
        let lag = CMTimeSubtract(pts, now)
        guard lag.isValid, lag.seconds < 0 else { return }
        // 欠多少补多少，再加 20ms 余量，免得贴着边界反复触发。
        let grown = min(preroll.seconds - lag.seconds + 0.02, Self.maxPreroll.seconds)
        preroll = CMTime(seconds: grown, preferredTimescale: 1000)
        synchronizer.setRate(synchronizer.rate, time: CMTimeSubtract(pts, preroll))
    }

    /// 相机时钟偏快时缓冲会一直堆积，落后太多就把时基向前对齐一次。
    private func rebaseIfDrifting(_ pts: CMTime) {
        guard clockStarted, pts.isValid else { return }
        let now = synchronizer.currentTime()
        guard now.isValid else { return }
        let lag = CMTimeSubtract(pts, now)
        guard CMTimeCompare(lag, maxLatency) > 0 else { return }
        synchronizer.setRate(synchronizer.rate, time: CMTimeSubtract(pts, preroll))
    }
}

nonisolated extension CMSampleBuffer {
    /// 没有 NotSync 标记就是同步帧（关键帧）。
    var isKeyframeSample: Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(self,
                                                                 createIfNecessary: false),
              CFArrayGetCount(array) > 0 else { return true }
        let raw = CFArrayGetValueAtIndex(array, 0)
        let dictionary = unsafeBitCast(raw, to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        guard let value = CFDictionaryGetValue(dictionary, key) else { return true }
        return !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }
}
