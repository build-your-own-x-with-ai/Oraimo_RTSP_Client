//
//  H264Depacketizer.swift
//  RTSPClient
//
//  RFC 6184：单 NAL、STAP-A、FU-A 三种打包方式。
//  MTAP / FU-B 基本没有摄像机在用，遇到就跳过而不是崩掉。
//

import Foundation
import CoreMedia

nonisolated struct H264Depacketizer {
    private var sps: Data?
    private var pps: Data?
    private var cachedFormat: CMFormatDescription?
    private var paramsChanged = false

    private var accumulator = Data()
    private var currentTimestamp: UInt32?
    /// 决定从哪一帧起播；等不到 IDR 也不会一直卡着。
    private var startGate = VideoStartGate()
    /// 当前 AU 里是否出现过真正的图像分片，避免只有 SPS/PPS 也当成一帧发下去。
    private var hasSlice = false

    private var fuBuffer = Data()
    private var fuActive = false
    private var fuTimestamp: UInt32 = 0

    var formatDescription: CMFormatDescription? { cachedFormat }
    /// 参数集齐了才能开始解码。
    var isReady: Bool { cachedFormat != nil }

    /// 用 SDP 的 sprop-parameter-sets 预置参数集，能少等一个 I 帧。
    mutating func applySDP(_ media: SDPMedia) {
        guard let value = media.fmtp["sprop-parameter-sets"] else { return }
        for piece in value.split(separator: ",") {
            let text = piece.trimmed
            guard !text.isEmpty, let decoded = Data(base64Encoded: text) else { continue }
            for nal in decoded.annexBNALUnits { ingestParameterSet(nal) }
        }
        rebuildFormatIfNeeded()
        // 此刻还没有任何待输出的帧，清掉标记，免得首帧误报格式变化。
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
        guard let first = packet.payload.first else { return [] }
        var output: [VideoAccessUnit] = []

        // 时间戳变化说明上一帧结束了（marker 丢失时的兜底）。
        if let ts = currentTimestamp, ts != packet.timestamp {
            if let unit = flush() { output.append(unit) }
        }
        currentTimestamp = packet.timestamp

        switch first & 0x1F {
        case 1...23:
            append(nal: packet.payload)
        case 24:
            appendSTAPA(packet.payload)
        case 28:
            appendFUA(packet)
        default:
            break                                   // 25/26/27/29：不支持的打包方式
        }

        if packet.marker, let unit = flush() { output.append(unit) }
        return output
    }
    // MARK: - 组装

    /// 有固件把一整个访问单元塞进一个 NAL 里发：FU-A 重组出来标着 type 7，
    /// 里面其实是 SPS + 00 00 00 01 + PPS + SEI + IDR 拼在一起。
    /// 照 NAL 头当成 SPS 收下的话，参数集会被整帧覆盖成垃圾，
    /// 而且 hasSlice 永远不置位 —— 一帧都出不来。先按起始码拆开再分派。
    private mutating func append(nal: Data) {
        guard let parts = nal.splitIfEmbeddedAnnexB else {
            appendSingle(nal: nal)
            return
        }
        for part in parts { appendSingle(nal: part) }
    }

    /// 单个裸 NAL 的分派。不再拆分，避免和 append(nal:) 相互递归。
    private mutating func appendSingle(nal: Data) {
        guard let header = nal.first else { return }
        let type = header & 0x1F
        switch type {
        case 7, 8:
            ingestParameterSet(nal)
            rebuildFormatIfNeeded()
        case 5:
            hasSlice = true
            accumulator.appendAVCC(nal)
        case 1...4:
            hasSlice = true
            accumulator.appendAVCC(nal)
        default:
            // SEI / AUD 等留在流里，解码器自己会忽略。
            accumulator.appendAVCC(nal)
        }
    }

    private mutating func appendSTAPA(_ payload: Data) {
        // STAP-A：1 字节头 + N 组（2 字节长度 + NAL）
        var offset = 1
        let bytes = [UInt8](payload)
        while offset + 2 <= bytes.count {
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard length > 0, offset + length <= bytes.count else { return }
            append(nal: Data(bytes[offset..<offset + length]))
            offset += length
        }
    }

    private mutating func appendFUA(_ packet: RTPPacket) {
        let bytes = [UInt8](packet.payload)
        guard bytes.count >= 2 else { return }
        let indicator = bytes[0]
        let header = bytes[1]
        let isStart = header & 0x80 != 0
        let isEnd = header & 0x40 != 0
        let type = header & 0x1F

        if isStart {
            // 重建原始 NAL 头：F/NRI 取自 indicator，type 取自 FU header。
            fuBuffer = Data([(indicator & 0xE0) | type])
            fuActive = true
            fuTimestamp = packet.timestamp
        } else if !fuActive || packet.timestamp != fuTimestamp {
            fuActive = false                       // 中途丢包，整帧作废
            fuBuffer.removeAll()
            return
        }

        fuBuffer.append(contentsOf: bytes[2...])

        if isEnd, fuActive {
            let nal = fuBuffer
            fuActive = false
            fuBuffer.removeAll()
            append(nal: nal)
        }
    }

    private mutating func flush() -> VideoAccessUnit? {
        // 参数集还没齐时先返回，不要动 startGate 的等待预算 ——
        // 那段时间的帧本来就没法解，不该算作「等不到关键帧」。
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

        let isKey = unit.avccContainsIDR
        // 首帧要能随机访问：IDR 最好，SEI recovery point 也算入点。
        guard startGate.allows(isKeyframe: isKey,
                               isRecoveryPoint: unit.avccContainsH264RecoveryPoint,
                               timestamp: timestamp) else { return nil }
        let changed = paramsChanged
        paramsChanged = false
        return VideoAccessUnit(data: unit, rtpTimestamp: timestamp,
                               isKeyframe: isKey, formatDidChange: changed)
    }

    // MARK: - 参数集

    private mutating func ingestParameterSet(_ nal: Data) {
        guard let header = nal.first else { return }
        switch header & 0x1F {
        case 7: if sps != nal { sps = nal; paramsChanged = true }
        case 8: if pps != nal { pps = nal; paramsChanged = true }
        default: break
        }
    }

    private mutating func rebuildFormatIfNeeded() {
        guard paramsChanged || cachedFormat == nil,
              let sps, let pps else { return }
        if let format = CMFormatDescription.h264(sps: sps, pps: pps) {
            cachedFormat = format
        }
    }
}

nonisolated extension Data {
    /// 扫 AVCC 里有没有 IDR 分片，用来标记关键帧。
    var avccContainsIDR: Bool {
        let bytes = [UInt8](self)
        var offset = 0
        while offset + 4 < bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { return false }
            if bytes[offset] & 0x1F == 5 { return true }
            offset += length
        }
        return false
    }
}
