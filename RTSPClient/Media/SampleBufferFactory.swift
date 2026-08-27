//
//  SampleBufferFactory.swift
//  RTSPClient
//
//  AVCC 访问单元 / 音频帧 -> CMSampleBuffer。
//

import Foundation
import CoreMedia

/// CMSampleBuffer 不是 Sendable，但这里是单向移交：
/// 建好之后生产队列不再碰它，只有渲染队列读。
nonisolated struct SampleBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
    init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}

nonisolated enum SampleBufferFactory {
    /// 视频：一个访问单元一个 sample。
    static func video(_ unit: VideoAccessUnit,
                      format: CMFormatDescription,
                      pts: CMTime,
                      duration: CMTime) -> CMSampleBuffer? {
        guard let block = blockBuffer(unit.data) else { return nil }
        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var size = unit.data.count
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { return nil }
        if !unit.isKeyframe { markNotSync(buffer) }
        return buffer
    }

    /// 音频：AAC 一帧一个 sample；G.711 一个包含多个定长 sample。
    static func audio(_ data: Data,
                      format: CMFormatDescription,
                      pts: CMTime,
                      sampleCount: Int,
                      bytesPerSample: Int,
                      duration: CMTime) -> CMSampleBuffer? {
        guard sampleCount > 0, let block = blockBuffer(data) else { return nil }
        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var size = bytesPerSample
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &buffer)
        return status == noErr ? buffer : nil
    }

    private static func blockBuffer(_ data: Data) -> CMBlockBuffer? {
        var block: CMBlockBuffer?
        let length = data.count
        guard length > 0 else { return nil }
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block) == noErr, let block else { return nil }

        let copied = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                 offsetIntoDestination: 0,
                                                 dataLength: length)
        }
        return copied == noErr ? block : nil
    }

    /// 非关键帧要打标记，否则 seek / flush 后解码器可能误判。
    private static func markNotSync(_ buffer: CMSampleBuffer) {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(buffer,
                                                                 createIfNecessary: true),
              CFArrayGetCount(array) > 0 else { return }
        let raw = CFArrayGetValueAtIndex(array, 0)
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}
