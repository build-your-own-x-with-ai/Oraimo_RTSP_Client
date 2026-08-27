//
//  RTSPAuth.swift
//  RTSPClient
//
//  Basic / Digest 认证。摄像机基本都用 Digest MD5。
//

import Foundation
import CryptoKit

nonisolated struct RTSPAuthChallenge: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case basic, digest }

    var kind: Kind
    var realm: String = ""
    var nonce: String = ""
    var opaque: String?
    var algorithm: String?
    var qop: [String] = []
    var stale = false

    /// 从若干个 WWW-Authenticate 头里挑最强的一个（Digest 优先）。
    static func best(from headerValues: [String]) -> RTSPAuthChallenge? {
        let parsed = headerValues.compactMap(RTSPAuthChallenge.init(header:))
        return parsed.first { $0.kind == .digest } ?? parsed.first
    }

    init?(header raw: String) {
        let text = raw.trimmed
        guard let space = text.firstIndex(of: " ") else {
            // 少数设备只回 "Basic"，没有任何参数。
            guard text.caseInsensitiveCompare("Basic") == .orderedSame else { return nil }
            self.kind = .basic
            return
        }
        switch String(text[text.startIndex..<space]).lowercased() {
        case "digest": self.kind = .digest
        case "basic":  self.kind = .basic
        default:       return nil
        }
        let params = RTSPAuthChallenge.parameters(String(text[text.index(after: space)...]))
        self.realm = params["realm"] ?? ""
        self.nonce = params["nonce"] ?? ""
        self.opaque = params["opaque"]
        self.algorithm = params["algorithm"]
        self.qop = (params["qop"] ?? "").split(separator: ",")
            .map { $0.trimmed.lowercased() }.filter { !$0.isEmpty }
        self.stale = (params["stale"] ?? "").caseInsensitiveCompare("true") == .orderedSame
    }

    /// 切分 `k=v, k="v,v"` 形式的参数；引号内的逗号不算分隔符。
    static func parameters(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var current = ""
        var inQuotes = false
        var pieces: [String] = []
        for ch in raw {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == ",", !inQuotes { pieces.append(current); current = ""; continue }
            current.append(ch)
        }
        if !current.trimmed.isEmpty { pieces.append(current) }
        for piece in pieces {
            guard let (k, v) = piece.splitOnce("=") else { continue }
            result[k.trimmed.lowercased()] = v.unquoted
        }
        return result
    }
}

/// 按挑战生成 Authorization 头，并维护 Digest 的 nonce 计数。
nonisolated final class RTSPAuthenticator {
    private let username: String
    private let password: String
    private var challenge: RTSPAuthChallenge?
    private var nonceCount = 0
    private let cnonce: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        self.cnonce = bytes.map { String(format: "%02x", $0) }.joined()
    }

    var hasChallenge: Bool { challenge != nil }

    /// 收到 401 时更新挑战；nonce 未变化说明凭据本身不对。
    /// 返回 true 表示值得用新挑战重试。
    func update(with challenge: RTSPAuthChallenge) -> Bool {
        defer { self.challenge = challenge }
        guard let old = self.challenge else { return true }
        if challenge.stale { nonceCount = 0; return true }
        return old.nonce != challenge.nonce
    }

    func authorization(method: String, uri: String) -> String? {
        guard let challenge else { return nil }
        switch challenge.kind {
        case .basic:
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            return "Basic \(token)"
        case .digest:
            return digest(challenge, method: method, uri: uri)
        }
    }

    private func digest(_ c: RTSPAuthChallenge, method: String, uri: String) -> String {
        let algorithm = (c.algorithm ?? "MD5").uppercased()
        let isSession = algorithm.hasSuffix("-SESS")
        var ha1 = Self.md5("\(username):\(c.realm):\(password)")
        if isSession { ha1 = Self.md5("\(ha1):\(c.nonce):\(cnonce)") }
        let ha2 = Self.md5("\(method):\(uri)")

        var fields = [
            "username=\"\(username)\"", "realm=\"\(c.realm)\"",
            "nonce=\"\(c.nonce)\"", "uri=\"\(uri)\"",
        ]
        let useQop = c.qop.contains("auth")
        let response: String
        if useQop {
            nonceCount += 1
            let nc = String(format: "%08x", nonceCount)
            response = Self.md5("\(ha1):\(c.nonce):\(nc):\(cnonce):auth:\(ha2)")
            fields += ["qop=auth", "nc=\(nc)", "cnonce=\"\(cnonce)\""]
        } else {
            response = Self.md5("\(ha1):\(c.nonce):\(ha2)")
        }
        fields.append("response=\"\(response)\"")
        if let opaque = c.opaque { fields.append("opaque=\"\(opaque)\"") }
        if c.algorithm != nil { fields.append("algorithm=\(algorithm)") }
        return "Digest " + fields.joined(separator: ", ")
    }

    /// RFC 2069/2617 指定 MD5；这里只用于认证摘要，不作通用哈希。
    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
