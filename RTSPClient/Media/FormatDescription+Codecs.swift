//
//  FormatDescription+Codecs.swift
//  RTSPClient
//
//  参数集 / SDP 字段 -> CMFormatDescription。
//

import Foundation
import CoreMedia
import AudioToolbox

nonisolated extension CMFormatDescription {
    static func h264(sps: Data, pps: Data) -> CMFormatDescription? {
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        var format: CMFormatDescription?
        let status = spsBytes.withUnsafeBufferPointer { s in
            ppsBytes.withUnsafeBufferPointer { p -> OSStatus in
                guard let sb = s.baseAddress, let pb = p.baseAddress else { return -1 }
                let pointers = [sb, pb]
                let sizes = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    static func hevc(vps: Data, sps: Data, pps: Data) -> CMFormatDescription? {
        let v = [UInt8](vps), s = [UInt8](sps), p = [UInt8](pps)
        var format: CMFormatDescription?
        let status = v.withUnsafeBufferPointer { vb in
            s.withUnsafeBufferPointer { sb in
                p.withUnsafeBufferPointer { pb -> OSStatus in
                    guard let v0 = vb.baseAddress, let s0 = sb.baseAddress,
                          let p0 = pb.baseAddress else { return -1 }
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: [v0, s0, p0],
                        parameterSetSizes: [vb.count, sb.count, pb.count],
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &format)
                }
            }
        }
        return status == noErr ? format : nil
    }
    /// AAC：magic cookie 用 SDP 的 config（AudioSpecificConfig）。
    static func aac(config: Data, sampleRate: Double, channels: UInt32) -> CMFormatDescription? {
        // config 里的采样率/声道更权威，优先用它覆盖 rtpmap 的值。
        let parsed = AudioSpecificConfig(config)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: parsed?.sampleRate ?? sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(parsed?.framesPerPacket ?? 1024),
            mBytesPerFrame: 0,
            mChannelsPerFrame: parsed?.channels ?? channels,
            mBitsPerChannel: 0,
            mReserved: 0)

        var format: CMFormatDescription?
        let bytes = [UInt8](config)
        let status = bytes.withUnsafeBufferPointer { cookie -> OSStatus in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0, layout: nil,
                magicCookieSize: cookie.count,
                magicCookie: cookie.isEmpty ? nil : cookie.baseAddress,
                extensions: nil,
                formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    /// G.711 与 L16，都是无需 cookie 的简单 PCM 家族。
    static func simpleAudio(codec: String, sampleRate: Double,
                            channels: UInt32) -> CMFormatDescription? {
        var formatID: AudioFormatID
        var bitsPerChannel: UInt32
        var flags: AudioFormatFlags = 0
        switch codec {
        case "PCMU": formatID = kAudioFormatULaw; bitsPerChannel = 8
        case "PCMA": formatID = kAudioFormatALaw; bitsPerChannel = 8
        case "L16":
            formatID = kAudioFormatLinearPCM
            bitsPerChannel = 16
            // RTP 的 L16 是大端有符号。
            flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian
                | kAudioFormatFlagIsPacked
        default: return nil
        }
        let bytesPerFrame = bitsPerChannel / 8 * channels
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: formatID,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0)
        var format: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }
}

/// AudioSpecificConfig 的最小解析（ISO/IEC 14496-3）。
nonisolated struct AudioSpecificConfig {
    static let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000,
                                        24000, 22050, 16000, 12000, 11025, 8000, 7350]

    var objectType: Int
    var sampleRate: Double
    var channels: UInt32
    var framesPerPacket: Int

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        var reader = BitReader(bytes)

        var objType = reader.read(5)
        if objType == 31 { objType = 32 + reader.read(6) }        // 扩展类型

        let rateIndex = reader.read(4)
        var rate: Double
        if rateIndex == 0x0F {
            rate = Double(reader.read(24))                        // 显式采样率
        } else {
            guard rateIndex < Self.sampleRates.count else { return nil }
            rate = Self.sampleRates[rateIndex]
        }
        let channelConfig = reader.read(4)

        // AAC-LD/ELD 一帧 512 或 480 样本，其余 1024。
        var frames = 1024
        if objType == 23 {                                        // ER AAC LD
            frames = 512
        } else if objType == 2 || objType == 5 || objType == 29 {
            // 读 GASpecificConfig 的 frameLengthFlag。
            if reader.read(1) == 1 { frames = 960 }
        }
        guard rate > 0 else { return nil }

        self.objectType = objType
        self.sampleRate = rate
        // channelConfig 0 表示配置在流内，退化成单声道避免建描述失败。
        self.channels = channelConfig == 0 ? 1
            : UInt32(channelConfig == 7 ? 8 : channelConfig)
        self.framesPerPacket = frames
    }
}

nonisolated struct BitReader {
    private let bytes: [UInt8]
    private var bitOffset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int {
        var result = 0
        for _ in 0..<count {
            let byteIndex = bitOffset >> 3
            guard byteIndex < bytes.count else { return result << 1 }
            let bit = (bytes[byteIndex] >> (7 - UInt8(bitOffset & 7))) & 1
            result = result << 1 | Int(bit)
            bitOffset += 1
        }
        return result
    }
}
