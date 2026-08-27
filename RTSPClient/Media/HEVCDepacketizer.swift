//
//  HEVCDepacketizer.swift
//  RTSPClient
//
//  RFC 7798：单 NAL、AP（聚合）、FU（分片）。
//  H.265 的 NAL 头是 2 字节，类型在高位 6 bit。
//

import Foundation
import CoreMedia

nonisolated struct HEVCDepacketizer {
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var cachedFormat: CMFormatDescription?
    private var paramsChanged = false

    private var accumulator = Data()
    private var currentTimestamp: UInt32?
    /// 同 H.264：等不到 IRAP 也要能起播。
    private var startGate = VideoStartGate()
    private var hasSlice = false

    private var fuBuffer = Data()
    private var fuActive = false
    private var fuTimestamp: UInt32 = 0

    var formatDescription: CMFormatDescription? { cachedFormat }
    var isReady: Bool { cachedFormat != nil }

    mutating func applySDP(_ media: SDPMedia) {
        for key in ["sprop-vps", "sprop-sps", "sprop-pps"] {
            guard let value = media.fmtp[key] else { continue }
            for piece in value.split(separator: ",") {
                guard let decoded = Data(base64Encoded: piece.trimmed) else { continue }
                for nal in decoded.annexBNALUnits { ingestParameterSet(nal) }
            }
        }
        rebuildFormatIfNeeded()
        // 同上：预置阶段不算格式变化。
        paramsChanged = false
    }

    mutating func reset() {
        accumulator.removeAll()
        currentTimestamp = nil
        startGate.reset()
        hasSlice = false
        fuBuffer.removeAll()
        fuActive = false
    }
    mutating func process(_ packet: RTPPacket) -> [VideoAccessUnit] {
        let bytes = [UInt8](packet.payload)
        guard bytes.count >= 2 else { return [] }
        var output: [VideoAccessUnit] = []

        if let ts = currentTimestamp, ts != packet.timestamp {
            if let unit = flush() { output.append(unit) }
        }
        currentTimestamp = packet.timestamp

        let type = (bytes[0] >> 1) & 0x3F
        switch type {
        case 48: appendAP(bytes)                       // 聚合包
        case 49: appendFU(packet, bytes)               // 分片
        case 0...47: append(nal: packet.payload)       // 单 NAL
        default: break
        }

        if packet.marker, let unit = flush() { output.append(unit) }
        return output
    }

    // MARK: - 组装

    /// 同 H.264：有固件把整个访问单元拼成一个 NAL 发，需要先按起始码拆开。
    private mutating func append(nal: Data) {
        guard let parts = nal.splitIfEmbeddedAnnexB else {
            appendSingle(nal: nal)
            return
        }
        for part in parts { appendSingle(nal: part) }
    }

    private mutating func appendSingle(nal: Data) {
        guard nal.count >= 2, let first = nal.first else { return }
        let type = (first >> 1) & 0x3F
        switch type {
        case 32, 33, 34:                               // VPS / SPS / PPS
            ingestParameterSet(nal)
            rebuildFormatIfNeeded()
        case 16...21:                                  // IRAP：BLA / IDR / CRA
            hasSlice = true
            accumulator.appendAVCC(nal)
        case 0...9:                                    // 非 IRAP 图像分片
            hasSlice = true
            accumulator.appendAVCC(nal)
        default:
            accumulator.appendAVCC(nal)
        }
    }

    private mutating func appendAP(_ bytes: [UInt8]) {
        // AP：2 字节 PayloadHdr + N 组（2 字节长度 + NAL）
        var offset = 2
        while offset + 2 <= bytes.count {
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard length > 0, offset + length <= bytes.count else { return }
            append(nal: Data(bytes[offset..<offset + length]))
            offset += length
        }
    }

    private mutating func appendFU(_ packet: RTPPacket, _ bytes: [UInt8]) {
        // FU：2 字节 PayloadHdr + 1 字节 FU header + 负载
        guard bytes.count >= 3 else { return }
        let fuHeader = bytes[2]
        let isStart = fuHeader & 0x80 != 0
        let isEnd = fuHeader & 0x40 != 0
        let type = fuHeader & 0x3F

        if isStart {
            // 还原原始 2 字节头：把 FU 的类型写回 PayloadHdr。
            let b0 = (bytes[0] & 0x81) | (type << 1)
            fuBuffer = Data([b0, bytes[1]])
            fuActive = true
            fuTimestamp = packet.timestamp
        } else if !fuActive || packet.timestamp != fuTimestamp {
            fuActive = false
            fuBuffer.removeAll()
            return
        }

        fuBuffer.append(contentsOf: bytes[3...])

        if isEnd, fuActive {
            let nal = fuBuffer
            fuActive = false
            fuBuffer.removeAll()
            append(nal: nal)
        }
    }

    private mutating func flush() -> VideoAccessUnit? {
        // 参数集没齐的阶段不消耗等待预算，理由同 H.264。
        guard hasSlice, !accumulator.isEmpty, isReady else {
            accumulator.removeAll()
            hasSlice = false
            currentTimestamp = nil
            return nil
        }
        let unit = accumulator
        let timestamp = currentTimestamp ?? 0
        accumulator.removeAll()
        hasSlice = false
        currentTimestamp = nil

        let isKey = unit.avccContainsIRAP
        // H.265 的 CRA 本身就是入点，不再另看 SEI。
        guard startGate.allows(isKeyframe: isKey, isRecoveryPoint: false,
                               timestamp: timestamp) else { return nil }
        let changed = paramsChanged
        paramsChanged = false
        return VideoAccessUnit(data: unit, rtpTimestamp: timestamp,
                               isKeyframe: isKey, formatDidChange: changed)
    }

    // MARK: - 参数集

    private mutating func ingestParameterSet(_ nal: Data) {
        guard let first = nal.first else { return }
        switch (first >> 1) & 0x3F {
        case 32: if vps != nal { vps = nal; paramsChanged = true }
        case 33: if sps != nal { sps = nal; paramsChanged = true }
        case 34: if pps != nal { pps = nal; paramsChanged = true }
        default: break
        }
    }

    private mutating func rebuildFormatIfNeeded() {
        guard paramsChanged || cachedFormat == nil,
              let vps, let sps, let pps else { return }
        if let format = CMFormatDescription.hevc(vps: vps, sps: sps, pps: pps) {
            cachedFormat = format
        }
    }
}

nonisolated extension Data {
    /// 扫 AVCC 里有没有 IRAP 分片（NAL 类型 16...21）。
    var avccContainsIRAP: Bool {
        let bytes = [UInt8](self)
        var offset = 0
        while offset + 4 < bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { return false }
            let type = (bytes[offset] >> 1) & 0x3F
            if (16...21).contains(type) { return true }
            offset += length
        }
        return false
    }
}
