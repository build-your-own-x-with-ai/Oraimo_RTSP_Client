//
//  MediaClock.swift
//  RTSPClient
//
//  把音视频各自的 RTP 时间戳映射到同一条播放时间轴。
//  首选 PLAY 响应里的 RTP-Info（两路指向同一个播放起点）；
//  设备不给就按首包到达时刻估一个偏移，至少不会音视频错开一大截。
//

import Foundation
import CoreMedia

nonisolated final class MediaClock {
    private var video: RTPTimeline
    private var audio: RTPTimeline
    private var videoOffset: CMTime = .zero
    private var audioOffset: CMTime = .zero
    private var hasRTPInfo = false
    /// 任意一路首包到达的时刻，用来估算另一路的起始偏移。
    private var firstArrival: CFAbsoluteTime?

    init(videoClockRate: Int, audioClockRate: Int) {
        video = RTPTimeline(clockRate: videoClockRate)
        audio = RTPTimeline(clockRate: audioClockRate)
    }

    /// RTP-Info 里的 rtptime，SETUP 之后、收包之前调用。
    func applyRTPInfo(video videoTime: UInt32?, audio audioTime: UInt32?) {
        if let videoTime { video.setOrigin(videoTime); hasRTPInfo = true }
        if let audioTime { audio.setOrigin(audioTime); hasRTPInfo = true }
    }

    func reset() {
        video.reset()
        audio.reset()
        videoOffset = .zero
        audioOffset = .zero
        hasRTPInfo = false
        firstArrival = nil
    }

    func videoTime(_ raw: UInt32) -> CMTime {
        let offset = resolveOffset(isVideo: true)
        return CMTimeAdd(video.time(for: raw), offset)
    }

    func audioTime(_ raw: UInt32) -> CMTime {
        let offset = resolveOffset(isVideo: false)
        return CMTimeAdd(audio.time(for: raw), offset)
    }

    /// AAC 一个 RTP 包可能带多帧，需要在包内按帧号推进。
    func audioTime(_ raw: UInt32, frameOffset: Int, samplesPerFrame: Int) -> CMTime {
        let base = audioTime(raw)
        guard frameOffset > 0 else { return base }
        return audio.advanced(base, frames: frameOffset, samplesPerFrame: samplesPerFrame)
    }

    /// 没有 RTP-Info 时，用首包到达的时间差补齐两路的起点。
    private func resolveOffset(isVideo: Bool) -> CMTime {
        if hasRTPInfo { return .zero }
        let now = CFAbsoluteTimeGetCurrent()
        guard let start = firstArrival else {
            firstArrival = now
            return .zero
        }
        let existing = isVideo ? videoOffset : audioOffset
        guard existing == .zero else { return existing }
        // 迟到的那一路整体后移，避免它被判定为“早该播完”而被丢弃。
        let delta = max(0, now - start)
        let offset = CMTime(seconds: delta, preferredTimescale: 90000)
        if isVideo { videoOffset = offset } else { audioOffset = offset }
        return offset
    }
}
