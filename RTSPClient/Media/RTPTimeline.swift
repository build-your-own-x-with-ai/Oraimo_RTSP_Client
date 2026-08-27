//
//  RTPTimeline.swift
//  RTSPClient
//
//  32 位 RTP 时间戳会回绕，而且音视频起点不同。
//  这里把它展开成单调递增值，再折算成统一时间轴上的 CMTime。
//

import Foundation
import CoreMedia

nonisolated struct RTPTimeline {
    let clockRate: Int32
    /// PLAY 的 RTP-Info 给出的起始时间戳；没有就用首包。
    private var origin: UInt64?
    private var lastRaw: UInt32?
    private var wrapCount: UInt64 = 0

    init(clockRate: Int) {
        self.clockRate = Int32(clockRate > 0 ? clockRate : 90000)
    }

    /// RTP-Info 带了 rtptime 时预置原点，让音视频对齐同一个零点。
    mutating func setOrigin(_ timestamp: UInt32) {
        origin = UInt64(timestamp)
        lastRaw = timestamp
        wrapCount = 0
    }

    mutating func reset() {
        origin = nil
        lastRaw = nil
        wrapCount = 0
    }

    /// 展开回绕后的绝对时间戳。
    private mutating func extend(_ raw: UInt32) -> UInt64 {
        if let last = lastRaw {
            // 差值超过半个周期就认为发生了回绕（含少量乱序容忍）。
            if last > raw, last - raw > UInt32.max / 2 {
                wrapCount += 1
            } else if raw > last, raw - last > UInt32.max / 2, wrapCount > 0 {
                wrapCount -= 1                     // 迟到的旧包
            }
        }
        lastRaw = raw
        return wrapCount << 32 | UInt64(raw)
    }

    /// 相对起点的时间。首包会把自己设为起点。
    mutating func time(for raw: UInt32) -> CMTime {
        let extended = extend(raw)
        if origin == nil { origin = extended }
        let base = origin ?? extended
        // 起点之后的包一律非负；起点之前的（乱序首包）截到 0。
        let delta = extended >= base ? extended - base : 0
        return CMTime(value: CMTimeValue(delta), timescale: clockRate)
    }

    /// 在包内按帧推进（AAC 一个包可能带多帧）。
    func advanced(_ time: CMTime, frames: Int, samplesPerFrame: Int) -> CMTime {
        guard frames > 0, samplesPerFrame > 0 else { return time }
        let offset = CMTime(value: CMTimeValue(frames * samplesPerFrame), timescale: clockRate)
        return CMTimeAdd(time, offset)
    }
}
