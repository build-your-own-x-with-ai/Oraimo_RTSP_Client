//
//  FormatDescription+Codecs.swift
//  RTSPClient
//
//  参数集 -> CMFormatDescription。
//

import Foundation
import CoreMedia

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
}
