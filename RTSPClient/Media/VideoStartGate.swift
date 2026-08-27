//
//  VideoStartGate.swift
//  RTSPClient
//
//  决定「从哪一帧开始往解码器送数据」。
//
//  首选是等一个 IDR / IRAP：从随机访问点起播，画面干净。
//  但有摄像机压根不发 IDR —— 长 GOP 只在第一帧给一次，或者靠
//  intra refresh + SEI recovery point 表示可以入点。这类流如果
//  死等关键帧，就会一帧都出不来，UI 永远停在「缓冲中」。
//
//  所以等待是有上限的：超过时限就从任意一个完整帧开始送。
//  代价是开头可能花几十毫秒的屏，比彻底放不出来好。
//

import Foundation

nonisolated struct VideoStartGate {
    /// 视频 RTP 时间戳固定 90 kHz（RFC 3551），不用从 SDP 取。
    private static let clockRate: UInt32 = 90_000
    /// 最多等这么久的「流内时间」。常见 GOP 是 1~4 秒，5 秒足够覆盖。
    private static let maxWaitTicks: UInt32 = 5 * clockRate
    /// 时间戳异常（不推进、乱跳）时的兜底：丢够这么多帧就起播。
    private static let maxSkippedUnits = 300

    private var started = false
    private var skipped = 0
    private var firstTimestamp: UInt32?

    /// 是否已经放行过，供统计和调试使用。
    var hasStarted: Bool { started }
    /// 起播前丢掉的帧数。
    var skippedUnits: Int { skipped }

    mutating func reset() {
        started = false
        skipped = 0
        firstTimestamp = nil
    }

    /// 返回 true 表示这一帧可以送去解码。
    /// - Parameters:
    ///   - isKeyframe: 本帧是否为 IDR / IRAP。
    ///   - isRecoveryPoint: 本帧是否带 SEI recovery point（H.264）。
    ///   - timestamp: 本帧的 RTP 时间戳。
    mutating func allows(isKeyframe: Bool, isRecoveryPoint: Bool,
                         timestamp: UInt32) -> Bool {
        // 起播之后来什么送什么，P 帧链由解码器自己接。
        if started { return true }

        if isKeyframe || isRecoveryPoint {
            started = true
            return true
        }

        guard let first = firstTimestamp else {
            firstTimestamp = timestamp
            skipped += 1
            return false
        }

        skipped += 1
        // 32 位回绕用环绕减法；结果落在后半程说明时间戳往回跳了，按 0 处理。
        let elapsed = timestamp &- first
        let advanced = elapsed < 0x8000_0000 && elapsed >= Self.maxWaitTicks
        if advanced || skipped >= Self.maxSkippedUnits {
            started = true
            return true
        }
        return false
    }
}

nonisolated extension Data {
    /// AVCC 数据里是否含 SEI recovery point（H.264 SEI 载荷类型 6）。
    /// 摄像机用它标记「从这里开始解码可以逐步恢复」，可以当入点。
    var avccContainsH264RecoveryPoint: Bool {
        let bytes = [UInt8](self)
        var offset = 0
        while offset + 4 < bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { return false }
            if bytes[offset] & 0x1F == 6,
               Data(bytes[offset..<offset + length]).seiHasRecoveryPoint {
                return true
            }
            offset += length
        }
        return false
    }

    /// 单个 SEI NAL（含 1 字节头）里是否有 recovery point 消息。
    /// SEI 结构：若干个 (payloadType, payloadSize, payload)，
    /// 两个字段都用 0xFF 续接。
    var seiHasRecoveryPoint: Bool {
        // 类型和长度字段里也可能插了防竞争字节，先去掉再解析。
        let bytes = [UInt8](dropEmulationPrevention.dropFirst())
        var offset = 0
        while offset < bytes.count {
            var type = 0
            while offset < bytes.count, bytes[offset] == 0xFF {
                type += 255
                offset += 1
            }
            guard offset < bytes.count else { return false }
            type += Int(bytes[offset])
            offset += 1

            var size = 0
            while offset < bytes.count, bytes[offset] == 0xFF {
                size += 255
                offset += 1
            }
            guard offset < bytes.count else { return false }
            size += Int(bytes[offset])
            offset += 1

            if type == 6 { return true }                 // recovery_point
            guard size >= 0, offset + size <= bytes.count else { return false }
            offset += size
            // 0x80 是 rbsp_trailing_bits，后面没有消息了。
            if offset < bytes.count, bytes[offset] == 0x80 { return false }
        }
        return false
    }

    /// 去掉 00 00 03 里的 03（防竞争字节）。
    var dropEmulationPrevention: Data {
        let bytes = [UInt8](self)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 0x03 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            output.append(byte)
        }
        return Data(output)
    }
}
