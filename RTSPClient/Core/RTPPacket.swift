//
//  RTPPacket.swift
//  RTSPClient
//
//  RTP 固定头解析（RFC 3550），含 CSRC / 扩展头 / 尾部填充处理。
//

import Foundation

nonisolated struct RTPPacket: Sendable {
    var payloadType: Int
    var sequenceNumber: UInt16
    var timestamp: UInt32
    var ssrc: UInt32
    var marker: Bool
    var payload: Data

    init?(_ data: Data) {
        // Data 可能是切片，startIndex 不一定是 0，统一按裸指针偏移读。
        let parsed: RTPPacket? = data.withUnsafeBytes { raw -> RTPPacket? in
            let total = raw.count
            guard total >= 12 else { return nil }
            let bytes = raw.bindMemory(to: UInt8.self)

            guard bytes[0] >> 6 == 2 else { return nil }        // 只认版本 2
            let hasPadding = bytes[0] & 0x20 != 0
            let hasExtension = bytes[0] & 0x10 != 0
            let csrcCount = Int(bytes[0] & 0x0F)

            func be16(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
            func be32(_ i: Int) -> UInt32 {
                UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16
                    | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
            }

            var offset = 12 + csrcCount * 4
            guard total >= offset else { return nil }

            if hasExtension {
                guard total >= offset + 4 else { return nil }
                let words = Int(be16(offset + 2))
                offset += 4 + words * 4
                guard total >= offset else { return nil }
            }

            var end = total
            if hasPadding {
                let padding = Int(bytes[total - 1])
                guard padding > 0, end - padding >= offset else { return nil }
                end -= padding
            }
            guard end >= offset else { return nil }

            let payload = offset == end
                ? Data()
                : Data(bytes: raw.baseAddress!.advanced(by: offset), count: end - offset)

            return RTPPacket(payloadType: Int(bytes[1] & 0x7F),
                             sequenceNumber: be16(2),
                             timestamp: be32(4),
                             ssrc: be32(8),
                             marker: bytes[1] & 0x80 != 0,
                             payload: payload)
        }
        guard let parsed else { return nil }
        self = parsed
    }

    private init(payloadType: Int, sequenceNumber: UInt16, timestamp: UInt32,
                 ssrc: UInt32, marker: Bool, payload: Data) {
        self.payloadType = payloadType
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.marker = marker
        self.payload = payload
    }
}
