//
//  MediaRenderer.swift
//  RTSPClient
//
//  用 AVSampleBufferRenderSynchronizer 驱动视频层和音频渲染器，
//  按 PTS 播放即可自然对齐音视频。
//
//  直播没有固定时长，时钟起点取首帧 PTS 往前挪一点作为缓冲；
//  摄像机时钟和本机时钟长期有漂移，所以延迟超限时把时基往前跳一次。
//

import Foundation
import AVFoundation
import CoreMedia

nonisolated final class MediaRenderer: @unchecked Sendable {
    /// 首帧起播前预留的缓冲，太小容易卡顿，太大延迟明显。
    private static let preroll = CMTime(value: 250, timescale: 1000)
    /// 累计延迟超过这个值就重置时基，防止越播越滞后。
    private static let maxLatency = CMTime(value: 1200, timescale: 1000)

    /// 期望在主线程创建（CALayer 不是线程安全的）。
    let displayLayer = AVSampleBufferDisplayLayer()

    private let videoRenderer: AVSampleBufferVideoRenderer
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "com.iosdevlog.rtsp.render")

    private var clockStarted = false
    private var volume: Float = 1
    private var muted = false
    private var onFirstFrame: (() -> Void)?

    init(enableAudio: Bool) {
        videoRenderer = displayLayer.sampleBufferRenderer
        synchronizer.addRenderer(videoRenderer)
        if enableAudio {
            let renderer = AVSampleBufferAudioRenderer()
            audioRenderer = renderer
            synchronizer.addRenderer(renderer)
        }
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

    func enqueueAudio(_ buffer: CMSampleBuffer) {
        let box = SampleBox(buffer)
        queue.async {
            guard let audioRenderer = self.audioRenderer else { return }
            let buffer = box.buffer
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            self.startClockIfNeeded(at: pts)
            guard audioRenderer.isReadyForMoreMediaData else { return }
            audioRenderer.enqueue(buffer)
        }
    }

    /// 换分辨率 / 参数集时清一次队列，避免旧尺寸的帧混进来。
    func flushForFormatChange() {
        queue.async {
            self.videoRenderer.flush()
            self.audioRenderer?.flush()
        }
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
            self.audioRenderer?.flush()
            self.clockStarted = false
            self.onFirstFrame = nil
        }
    }

    func setMuted(_ value: Bool) {
        queue.async {
            self.muted = value
            self.audioRenderer?.volume = value ? 0 : self.volume
        }
    }

    func setVolume(_ value: Float) {
        queue.async {
            self.volume = max(0, min(1, value))
            if !self.muted { self.audioRenderer?.volume = self.volume }
        }
    }

    /// 当前播放时刻，用于统计显示。
    var currentTime: CMTime { synchronizer.currentTime() }

    // MARK: - 时基

    private func startClockIfNeeded(at pts: CMTime) {
        guard !clockStarted, pts.isValid else { return }
        clockStarted = true
        // 从首帧 PTS 减去预缓冲开始跑，给后续帧留出到达时间。
        synchronizer.setRate(1, time: CMTimeSubtract(pts, Self.preroll))
    }

    /// 相机时钟偏快时缓冲会一直堆积，落后太多就把时基向前对齐一次。
    private func rebaseIfDrifting(_ pts: CMTime) {
        guard clockStarted, pts.isValid else { return }
        let now = synchronizer.currentTime()
        guard now.isValid else { return }
        let lag = CMTimeSubtract(pts, now)
        guard CMTimeCompare(lag, Self.maxLatency) > 0 else { return }
        synchronizer.setRate(synchronizer.rate, time: CMTimeSubtract(pts, Self.preroll))
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
