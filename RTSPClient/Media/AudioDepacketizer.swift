//
//  AudioDepacketizer.swift
//  RTSPClient
//
//  AAC 走 RFC 3640（AU-headers-length + 每帧 AU-header），
//  G.711 / L16 直接就是裸样本。
//

import Foundation
import CoreMedia

nonisolated struct AudioFrame: Sendable {
    var data: Data
    var rtpTimestamp: UInt32
    /// 同一个 RTP 包里的第 n 帧，用来在包内推进时间戳。
    var frameOffset: Int
    var framesPerPacket: Int
}

nonisolated struct AudioDepacketizer {
    private(set) var formatDescription: CMFormatDescription?
    private(set) var clockRate: Int
    private(set) var samplesPerFrame: Int = 1024
    /// AAC 这类压缩格式一帧就是一个 sample；PCM 家族要按字节数换算。
    private(set) var isCompressed = false
    private(set) var bytesPerSample = 1
    private let codec: String

    /// AAC 的 AU-header 位宽，来自 fmtp。
    private var sizeLength = 13
    private var indexLength = 3
    private var indexDeltaLength = 3

    var isReady: Bool { formatDescription != nil }

    init?(media: SDPMedia) {
        self.codec = media.codec
        self.clockRate = media.clockRate > 0 ? media.clockRate : 8000
        let channels = UInt32(media.channels ?? 1)

        switch codec {
        case "MPEG4-GENERIC":
            // 只处理 AAC；同名 payload 也可能是别的 MPEG-4 流。
            let mode = (media.fmtp["mode"] ?? "").lowercased()
            guard mode.isEmpty || mode.contains("aac") else { return nil }
            if let text = media.fmtp["sizelength"], let v = Int(text) { sizeLength = v }
            if let text = media.fmtp["indexlength"], let v = Int(text) { indexLength = v }
            if let text = media.fmtp["indexdeltalength"], let v = Int(text) {
                indexDeltaLength = v
            }
            let config = Data(hexEncoded: media.fmtp["config"] ?? "") ?? Data()
            guard !config.isEmpty,
                  let format = CMFormatDescription.aac(config: config,
                                                       sampleRate: Double(clockRate),
                                                       channels: channels) else { return nil }
            formatDescription = format
            samplesPerFrame = AudioSpecificConfig(config)?.framesPerPacket ?? 1024
            // AAC 的 RTP 时钟就是采样率，用 config 里的值更可靠。
            if let parsed = AudioSpecificConfig(config) { clockRate = Int(parsed.sampleRate) }
            isCompressed = true

        case "PCMU", "PCMA", "L16":
            guard let format = CMFormatDescription.simpleAudio(
                codec: codec, sampleRate: Double(clockRate),
                channels: channels) else { return nil }
            formatDescription = format
            samplesPerFrame = 1
            isCompressed = false
            bytesPerSample = codec == "L16" ? 2 * Int(channels) : Int(channels)

        default:
            return nil
        }
    }
    func process(_ packet: RTPPacket) -> [AudioFrame] {
        guard !packet.payload.isEmpty else { return [] }
        switch codec {
        case "MPEG4-GENERIC": return parseAAC(packet)
        default:
            return [AudioFrame(data: packet.payload, rtpTimestamp: packet.timestamp,
                               frameOffset: 0, framesPerPacket: 1)]
        }
    }

    /// RFC 3640 的 AU 分组：2 字节头区位长 + N 个 AU-header + 各帧数据。
    private func parseAAC(_ packet: RTPPacket) -> [AudioFrame] {
        let bytes = [UInt8](packet.payload)
        guard bytes.count > 2 else { return [] }

        let headersBits = Int(bytes[0]) << 8 | Int(bytes[1])
        // 头区为 0 时退化成整包一帧（有设备这么发）。
        guard headersBits > 0 else {
            return [AudioFrame(data: Data(bytes[2...]), rtpTimestamp: packet.timestamp,
                               frameOffset: 0, framesPerPacket: 1)]
        }

        let headersBytes = (headersBits + 7) / 8
        let dataStart = 2 + headersBytes
        guard dataStart <= bytes.count, sizeLength > 0 else { return [] }

        // 先读出每帧长度。首个 AU-header 用 indexLength，后续用 indexDeltaLength。
        var reader = BitReader(Array(bytes[2..<dataStart]))
        var sizes: [Int] = []
        var consumedBits = 0
        while true {
            let indexBits = sizes.isEmpty ? indexLength : indexDeltaLength
            guard consumedBits + sizeLength + indexBits <= headersBits else { break }
            let size = reader.read(sizeLength)
            _ = reader.read(indexBits)
            consumedBits += sizeLength + indexBits
            guard size > 0 else { break }
            sizes.append(size)
        }
        guard !sizes.isEmpty else { return [] }

        var frames: [AudioFrame] = []
        var offset = dataStart
        for (i, size) in sizes.enumerated() {
            guard offset + size <= bytes.count else { break }
            frames.append(AudioFrame(data: Data(bytes[offset..<offset + size]),
                                     rtpTimestamp: packet.timestamp,
                                     frameOffset: i,
                                     framesPerPacket: sizes.count))
            offset += size
        }
        return frames
    }
}

nonisolated extension Data {
    /// SDP 的 AAC config 是十六进制串。
    init?(hexEncoded text: String) {
        let clean = text.trimmed
        guard !clean.isEmpty, clean.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
