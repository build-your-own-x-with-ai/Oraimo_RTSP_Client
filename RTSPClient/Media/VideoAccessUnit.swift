//
//  VideoAccessUnit.swift
//  RTSPClient
//
//  解包产物：一个 AVCC 格式的访问单元。
//  VideoToolbox 要求 4 字节大端长度前缀，不是 Annex-B 起始码。
//

import Foundation

nonisolated struct VideoAccessUnit: Sendable {
    var data: Data
    var rtpTimestamp: UInt32
    var isKeyframe: Bool
    /// 本单元之前参数集发生过变化，渲染端需要换 format description。
    var formatDidChange: Bool = false
}

nonisolated extension Data {
    /// 按 AVCC 追加一个 NAL（4 字节长度 + 负载）。
    mutating func appendAVCC(_ nal: Data) {
        guard !nal.isEmpty else { return }
        let n = UInt32(nal.count)
        append(UInt8(truncatingIfNeeded: n >> 24))
        append(UInt8(truncatingIfNeeded: n >> 16))
        append(UInt8(truncatingIfNeeded: n >> 8))
        append(UInt8(truncatingIfNeeded: n))
        append(nal)
    }

    /// 拆 Annex-B（00 00 01 / 00 00 00 01）成裸 NAL 数组。
    /// SDP 里的参数集偶尔会带起始码。
    var annexBNALUnits: [Data] {
        let bytes = [UInt8](self)
        guard !bytes.isEmpty else { return [] }

        /// 返回 i 处起始码的长度，不是起始码则为 0。
        func startCodeLength(at i: Int) -> Int {
            if i + 3 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0,
               bytes[i + 2] == 0, bytes[i + 3] == 1 { return 4 }
            if i + 2 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0,
               bytes[i + 2] == 1 { return 3 }
            return 0
        }

        // nalStart 从 0 起，不是 nil：缓冲区不以起始码开头时，第一段
        // （0 到首个起始码之间）也是一个完整的 NAL，之前那份写法会把它整段丢掉。
        // 关键帧被拼成「裸 SPS + 00 00 00 01 + PPS + ...」的固件正好是这个形状，
        // 丢掉的恰好是唯一有用的那个参数集。
        var result: [Data] = []
        var nalStart = 0
        var i = 0
        while i < bytes.count {
            let code = startCodeLength(at: i)
            if code > 0 {
                // i == nalStart 说明两个起始码贴在一起，中间没有内容可取。
                if i > nalStart { result.append(Data(bytes[nalStart..<i])) }
                i += code
                nalStart = i
                continue
            }
            i += 1
        }
        // 没有任何起始码时 nalStart 还是 0，整块就是一个裸 NAL。
        if nalStart < bytes.count { result.append(Data(bytes[nalStart...])) }
        // 走到这里还是空的，说明整块除了起始码没别的东西，没有 NAL 可交。
        return result
    }

    /// 里面有没有 Annex-B 起始码（只看 00 00 01，四字节版本以它结尾）。
    ///
    /// 用来判断一个「NAL」其实是不是几个 NAL 拼起来的。排除码
    /// （emulation prevention）保证符合规范的 NAL 内部不会出现裸的
    /// 00 00 01，所以扫到就一定是拼接的边界，不会误伤正常负载。
    var containsAnnexBStartCode: Bool {
        withUnsafeBytes { raw in
            guard raw.count >= 3 else { return false }
            for i in 0...(raw.count - 3) {
                if raw[i] == 0, raw[i + 1] == 0, raw[i + 2] == 1 { return true }
            }
            return false
        }
    }

    /// 拆开拼在一起的 NAL；本来就只有一个就返回 nil，省一次拷贝。
    var splitIfEmbeddedAnnexB: [Data]? {
        guard count > 3, containsAnnexBStartCode else { return nil }
        let parts = annexBNALUnits
        return parts.isEmpty ? nil : parts
    }
}
