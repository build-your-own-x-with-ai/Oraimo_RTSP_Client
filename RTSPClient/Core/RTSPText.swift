//
//  RTSPText.swift
//  RTSPClient
//
//  协议解析用到的字符串小工具。
//

import Foundation

nonisolated extension StringProtocol {
    /// Substring 上也要能用：split 的结果直接接 .trimmed。
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

nonisolated extension String {
    /// 去掉两端成对的双引号，Digest 参数和 fmtp 值都可能带引号。
    var unquoted: String {
        let t = trimmed
        guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else { return t }
        return String(t.dropFirst().dropLast())
    }

    /// 按第一个分隔符切成两半，值里再出现分隔符也不会被切断。
    func splitOnce(_ separator: Character) -> (String, String)? {
        guard let i = firstIndex(of: separator) else { return nil }
        return (String(self[startIndex..<i]), String(self[index(after: i)...]))
    }

    /// 大小写不敏感比较，协议里的关键字判断都走这个。
    func matches(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }
}
