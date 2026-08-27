//
//  MediaClock.swift
//  RTSPClient
//
//  把 RTP 时间戳映射到播放时间轴。
//  首选 PLAY 响应里的 RTP-Info 给出的起点，设备不给就用首包。
//
//  以前这里还负责给音视频各算一个起始偏移。只剩一条轨之后那套逻辑没了意义 ——
//  而且它在单轨下有副作用：首包偏移 0，之后每一包都被加上「首包到次包的间隔」，
//  等于把除首帧以外的所有帧整体往后推了几毫秒。一并去掉。
//

import Foundation
import CoreMedia

nonisolated final class MediaClock {
    private var video: RTPTimeline

    init(clockRate: Int) {
        video = RTPTimeline(clockRate: clockRate)
    }

    /// RTP-Info 里的 rtptime，PLAY 之后、收包之前调用。传 nil 表示设备没给，
    /// 那就让首包自己当起点。
    func applyRTPInfo(_ origin: UInt32?) {
        guard let origin else { return }
        video.setOrigin(origin)
    }

    func reset() {
        video.reset()
    }

    func videoTime(_ raw: UInt32) -> CMTime {
        video.time(for: raw)
    }
}
