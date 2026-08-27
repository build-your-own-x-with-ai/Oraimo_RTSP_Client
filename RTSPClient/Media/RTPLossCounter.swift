//
//  RTPLossCounter.swift
//  RTSPClient
//
//  丢包统计（RFC 3550 附录 A.3 的思路）：
//  用「应收数量 - 实收数量」而不是逐个数序号断点。
//  乱序和重复都不会把数字算歪 —— 直接数断点的话，
//  一个迟到的包会先算一次负跳、再算一次正跳，重复计数。
//

import Foundation

nonisolated struct RTPLossCounter {
    private var baseSeq: UInt16?
    private var maxSeq: UInt16 = 0
    private var cycles: UInt64 = 0
    private var received: UInt64 = 0

    mutating func reset() {
        baseSeq = nil
        maxSeq = 0
        cycles = 0
        received = 0
    }

    mutating func note(_ sequenceNumber: UInt16) {
        received += 1
        guard baseSeq != nil else {
            baseSeq = sequenceNumber
            maxSeq = sequenceNumber
            return
        }
        let delta = sequenceNumber &- maxSeq
        // delta 落在前半程视为新包（可能跨过 16 位回绕）；
        // 否则是迟到的旧包，只计入实收，不推进最大值。
        if delta < 0x8000 {
            if sequenceNumber < maxSeq { cycles += 1 }   // 回绕
            maxSeq = sequenceNumber
        }
    }

    /// 估算丢失数量；乱序不会造成虚高。
    var lost: Int {
        guard let base = baseSeq else { return 0 }
        let extendedMax = cycles << 16 | UInt64(maxSeq)
        let extendedBase = UInt64(base)
        guard extendedMax >= extendedBase else { return 0 }
        let expected = extendedMax - extendedBase + 1
        return expected > received ? Int(expected - received) : 0
    }
}
