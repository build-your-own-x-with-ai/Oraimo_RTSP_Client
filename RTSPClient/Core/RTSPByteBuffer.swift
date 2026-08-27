//
//  RTSPByteBuffer.swift
//  RTSPClient
//
//  带读游标的接收缓冲。TCP 上文本响应和 interleaved 二进制帧混在
//  同一条流里，需要能一边攒一边按帧取走。
//

import Foundation

nonisolated struct RTSPByteBuffer {
    private var storage: [UInt8] = []
    private var cursor = 0

    /// 已读部分累积到这个量就整理一次，避免无限增长。
    private static let compactThreshold = 64 * 1024

    var count: Int { storage.count - cursor }
    var isEmpty: Bool { count == 0 }

    mutating func append(_ data: Data) {
        storage.append(contentsOf: data)
    }

    func peek(_ offset: Int) -> UInt8? {
        let i = cursor + offset
        return i < storage.count ? storage[i] : nil
    }

    func peekUInt16BE(_ offset: Int) -> Int? {
        guard let hi = peek(offset), let lo = peek(offset + 1) else { return nil }
        return Int(hi) << 8 | Int(lo)
    }

    /// 取走前 n 字节；不够就返回 nil，不改变状态。
    mutating func take(_ n: Int) -> Data? {
        guard n >= 0, count >= n else { return nil }
        // 必须先取出数据再整理：compactIfNeeded 会搬动 storage 并重置
        // cursor，之后用旧下标切片就会越界。
        let slice = Data(storage[cursor..<cursor + n])
        cursor += n
        compactIfNeeded()
        return slice
    }

    mutating func skip(_ n: Int) {
        cursor = min(cursor + n, storage.count)
        compactIfNeeded()
    }

    /// 剩余字节的拷贝，交给文本解析器试着切一条完整消息。
    var remaining: Data { Data(storage[cursor...]) }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
        cursor = 0
    }

    private mutating func compactIfNeeded() {
        guard cursor >= Self.compactThreshold else { return }
        storage.removeFirst(cursor)
        cursor = 0
    }
}
