//
//  VideoDepacketizer.swift
//  RTSPClient
//
//  按 SDP 编码名选 H.264 或 H.265 解包器，对外统一接口。
//

import Foundation
import CoreMedia

nonisolated struct VideoDepacketizer {
    private enum Backend {
        case h264(H264Depacketizer)
        case hevc(HEVCDepacketizer)
    }

    private var backend: Backend
    let codecName: String

    init?(media: SDPMedia) {
        switch media.codec {
        case "H264":
            var d = H264Depacketizer()
            d.applySDP(media)
            backend = .h264(d)
            codecName = "H.264"
        case "H265", "HEVC":
            var d = HEVCDepacketizer()
            d.applySDP(media)
            backend = .hevc(d)
            codecName = "H.265"
        default:
            return nil
        }
    }

    var formatDescription: CMFormatDescription? {
        switch backend {
        case .h264(let d): return d.formatDescription
        case .hevc(let d): return d.formatDescription
        }
    }

    var isReady: Bool { formatDescription != nil }

    mutating func process(_ packet: RTPPacket) -> [VideoAccessUnit] {
        switch backend {
        case .h264(var d):
            let units = d.process(packet)
            backend = .h264(d)
            return units
        case .hevc(var d):
            let units = d.process(packet)
            backend = .hevc(d)
            return units
        }
    }

    mutating func reset() {
        switch backend {
        case .h264(var d): d.reset(); backend = .h264(d)
        case .hevc(var d): d.reset(); backend = .hevc(d)
        }
    }
}
