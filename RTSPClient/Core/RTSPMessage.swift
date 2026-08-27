//
//  RTSPMessage.swift
//  RTSPClient
//
//  RTSP 请求序列化与响应解析（RFC 2326 文本协议）。
//

import Foundation

nonisolated enum RTSPMethod: String, Sendable {
    case options = "OPTIONS"
    case describe = "DESCRIBE"
    case setup = "SETUP"
    case play = "PLAY"
    case pause = "PAUSE"
    case teardown = "TEARDOWN"
    case getParameter = "GET_PARAMETER"
    case setParameter = "SET_PARAMETER"
}

nonisolated struct RTSPRequest: Sendable {
    var method: RTSPMethod
    var uri: String
    var headers: [(name: String, value: String)] = []
    var body: Data?

    mutating func set(_ name: String, _ value: String) {
        if let i = headers.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            headers[i].value = value
        } else {
            headers.append((name, value))
        }
    }

    func serialized(cseq: Int) -> Data {
        var text = "\(method.rawValue) \(uri) RTSP/1.0\r\n"
        text += "CSeq: \(cseq)\r\n"
        for header in headers { text += "\(header.name): \(header.value)\r\n" }
        if let body, !body.isEmpty { text += "Content-Length: \(body.count)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        if let body { data.append(body) }
        return data
    }
}

nonisolated struct RTSPResponse: Sendable {
    var statusCode: Int
    var reasonPhrase: String
    var headers: [(name: String, value: String)]
    var body: Data = Data()

    var isSuccess: Bool { (200...299).contains(statusCode) }

    func value(_ name: String) -> String? {
        headers.first { $0.name.matches(name) }?.value.trimmed
    }

    /// 同名头可能出现多次，Digest + Basic 双挑战就是这种。
    func values(_ name: String) -> [String] {
        headers.filter { $0.name.matches(name) }.map { $0.value.trimmed }
    }

    var cseq: Int? { value("CSeq").flatMap { Int($0.trimmed) } }

    /// Session 头形如 "12345678;timeout=60"。
    var sessionID: String? {
        guard let raw = value("Session") else { return nil }
        return raw.split(separator: ";").first.map { String($0).trimmed }
    }

    var sessionTimeout: Int? {
        guard let raw = value("Session") else { return nil }
        for part in raw.split(separator: ";") {
            let piece = String(part).trimmed
            if piece.lowercased().hasPrefix("timeout") {
                return piece.splitOnce("=").flatMap { Int($0.1.trimmed) }
            }
        }
        return nil
    }

    var contentLength: Int { value("Content-Length").flatMap { Int($0) } ?? 0 }

    /// 头部齐了但 body 可能还没到，所以解析分两步走。
    static func parseHead(_ buffer: Data) -> (response: RTSPResponse, headLength: Int)? {
        guard let parsed = RTSPHead.parse(buffer),
              case .response(let response) = parsed.message else { return nil }
        return (response, parsed.headLength)
    }
}

/// 一条入站消息。多数是响应，少数设备会主动发 OPTIONS / ANNOUNCE 过来。
nonisolated enum RTSPIncoming: Sendable {
    case response(RTSPResponse)
    case request(method: String, uri: String, cseq: Int?)
}

nonisolated enum RTSPHead {
    /// 切出起始行与头字段。返回 nil 表示数据不足，继续收。
    static func split(_ buffer: Data)
    -> (startLine: String, headers: [(name: String, value: String)], length: Int)? {
        guard let range = buffer.rangeOfDoubleCRLF() else { return nil }
        // 头按 RFC 是 US-ASCII；设备塞非法字节时降级解释，不整条丢弃。
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
            .flatMap { $0.components(separatedBy: "\n") }
            .filter { !$0.isEmpty }
        guard let startLine = lines.first else { return nil }
        lines.removeFirst()

        var headers: [(name: String, value: String)] = []
        for line in lines {
            // 折行续接：以空白开头的行属于上一个头。
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !headers.isEmpty {
                headers[headers.count - 1].value += " " + line.trimmed
                continue
            }
            if let (name, value) = line.splitOnce(":") {
                headers.append((name.trimmed, value.trimmed))
            }
        }
        let length = buffer.distance(from: buffer.startIndex, to: range.upperBound)
        return (startLine, headers, length)
    }

    static func parse(_ buffer: Data)
    -> (message: RTSPIncoming, headLength: Int, contentLength: Int)? {
        guard let (startLine, headers, headLength) = split(buffer) else { return nil }
        let contentLength = headers.first { $0.name.matches("Content-Length") }
            .flatMap { Int($0.value.trimmed) } ?? 0
        let cseq = headers.first { $0.name.matches("CSeq") }.flatMap { Int($0.value.trimmed) }
        let parts = startLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        if parts[0].uppercased().hasPrefix("RTSP/") {
            guard let code = Int(parts[1]) else { return nil }
            let response = RTSPResponse(statusCode: code,
                                        reasonPhrase: parts.count > 2 ? parts[2].trimmed : "",
                                        headers: headers)
            return (.response(response), headLength, contentLength)
        }
        let request = RTSPIncoming.request(method: parts[0].uppercased(),
                                          uri: parts[1], cseq: cseq)
        return (request, headLength, contentLength)
    }
}

nonisolated extension Data {
    /// 找头体分隔位置，兼容只用 LF 的设备。
    func rangeOfDoubleCRLF() -> Range<Index>? {
        if let r = range(of: Data("\r\n\r\n".utf8)) {
            if let lf = range(of: Data("\n\n".utf8)), lf.lowerBound < r.lowerBound { return lf }
            return r
        }
        return range(of: Data("\n\n".utf8))
    }
}
