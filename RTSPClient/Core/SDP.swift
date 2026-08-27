//
//  SDP.swift
//  RTSPClient
//
//  DESCRIBE 返回的 SDP 解析（RFC 4566），只取播放需要的字段。
//

import Foundation

nonisolated struct SDPMedia: Sendable, Equatable {
    enum Kind: String, Sendable { case video, audio, application, text, other }

    var kind: Kind
    var payloadType: Int
    var encodingName: String = ""
    var clockRate: Int = 0
    var channels: Int?
    var control: String = ""
    var fmtp: [String: String] = [:]
    /// fmtp 里逗号分隔的裸值（H265 的 sprop 之类不走 key=value）。
    var fmtpFlags: [String] = []

    var isVideo: Bool { kind == .video }
    var isAudio: Bool { kind == .audio }

    /// 归一化后的编码名，便于分支判断。
    var codec: String { encodingName.uppercased() }
}

nonisolated struct SDPSession: Sendable, Equatable {
    var sessionName: String = ""
    var control: String?
    var media: [SDPMedia] = []

    var video: SDPMedia? { media.first { $0.isVideo && $0.clockRate > 0 } }

    /// 任意一条音频轨，不管编码是什么。
    ///
    /// 音频不播，这个只用来取负载类型，把混进视频通道的音频包挡掉。
    /// 所以不能按「我们能解的编码」筛：遇到不认识的音频编码时，
    /// 那一路照样得挡，否则它的包会被当成视频解。
    var anyAudio: SDPMedia? { media.first { $0.isAudio && $0.payloadType >= 0 } }

    static func parse(_ data: Data) throws -> SDPSession {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { throw RTSPError.sdpParseFailed("内容为空") }

        var session = SDPSession()
        var current: SDPMedia?
        // 静态 payload type 的默认参数，设备省略 rtpmap 时用得上。
        let staticMap: [Int: (String, Int, Int)] = [
            0: ("PCMU", 8000, 1), 8: ("PCMA", 8000, 1),
            10: ("L16", 44100, 2), 11: ("L16", 44100, 1),
            14: ("MPA", 90000, 1), 26: ("JPEG", 90000, 1),
            32: ("MPV", 90000, 1), 33: ("MP2T", 90000, 1),
        ]

        func flush() {
            if let media = current { session.media.append(media) }
            current = nil
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n "))
            guard line.count >= 2, let (key, value) = line.splitOnce("=") else { continue }

            switch key {
            case "s":
                if current == nil { session.sessionName = value.trimmed }
            case "m":
                flush()
                let fields = value.split(separator: " ").map(String.init)
                guard fields.count >= 4 else { continue }
                let kind = SDPMedia.Kind(rawValue: fields[0].lowercased()) ?? .other
                // 一条 m= 行可以列多个 pt，取第一个作为首选。
                let pt = Int(fields[3]) ?? -1
                var media = SDPMedia(kind: kind, payloadType: pt)
                if let fallback = staticMap[pt] {
                    media.encodingName = fallback.0
                    media.clockRate = fallback.1
                    media.channels = fallback.2
                }
                current = media
            case "a":
                Self.applyAttribute(value, to: &current, session: &session)
            default:
                continue
            }
        }
        flush()

        guard !session.media.isEmpty else { throw RTSPError.sdpParseFailed("没有 m= 媒体行") }
        return session
    }

    private static func applyAttribute(_ value: String,
                                       to media: inout SDPMedia?,
                                       session: inout SDPSession) {
        let (name, rest) = value.splitOnce(":") ?? (value, "")
        switch name.lowercased() {
        case "control":
            if media != nil { media!.control = rest.trimmed } else { session.control = rest.trimmed }
        case "rtpmap":
            // rtpmap:96 H264/90000[/channels]
            guard var m = media, let (ptText, spec) = rest.trimmed.splitOnce(" ") else { return }
            guard Int(ptText.trimmed) == m.payloadType || m.payloadType < 0 else { return }
            if m.payloadType < 0 { m.payloadType = Int(ptText.trimmed) ?? -1 }
            let fields = spec.trimmed.split(separator: "/").map(String.init)
            if let first = fields.first { m.encodingName = first }
            if fields.count > 1, let rate = Int(fields[1]) { m.clockRate = rate }
            if fields.count > 2, let ch = Int(fields[2]) { m.channels = ch }
            media = m
        case "fmtp":
            guard var m = media, let (_, params) = rest.trimmed.splitOnce(" ") else { return }
            for piece in params.split(separator: ";") {
                let entry = String(piece).trimmed
                guard !entry.isEmpty else { continue }
                if let (k, v) = entry.splitOnce("=") {
                    m.fmtp[k.trimmed.lowercased()] = v.trimmed
                } else {
                    m.fmtpFlags.append(entry)
                }
            }
            media = m
        default:
            return
        }
    }
}
