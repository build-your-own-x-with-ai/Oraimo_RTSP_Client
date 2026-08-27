//
//  RTSPURL.swift
//  RTSPClient
//
//  rtsp:// 地址解析。摄像机地址里的密码常含未转义字符，
//  URLComponents 遇到就直接返回 nil，所以这里自己切分。
//

import Foundation

nonisolated struct RTSPURL: Equatable, Hashable, Sendable {
    static let defaultPort = 554
    static let defaultTLSPort = 322

    var scheme: String
    var host: String
    var port: Int
    var pathAndQuery: String
    var username: String?
    var password: String?
    /// 原串是否显式写了端口，决定 Request-URI 是否回填端口。
    var hasExplicitPort: Bool

    var usesTLS: Bool { scheme == "rtsps" }
    var schemeDefaultPort: Int { usesTLS ? Self.defaultTLSPort : Self.defaultPort }

    init?(string raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var parsedScheme = "rtsp"
        if let sep = text.range(of: "://") {
            let s = String(text[text.startIndex..<sep.lowerBound]).lowercased()
            guard s == "rtsp" || s == "rtsps" else { return nil }
            parsedScheme = s
            text = String(text[sep.upperBound...])
        }
        guard !text.isEmpty else { return nil }

        let authority: String
        var tail = "/"
        if let slash = text.firstIndex(of: "/") {
            authority = String(text[text.startIndex..<slash])
            tail = String(text[slash...])
        } else {
            authority = text
        }
        guard !authority.isEmpty else { return nil }

        // userinfo 用最后一个 @ 切分：密码里出现 @ 时才不会截错。
        var hostPort = authority
        var user: String?
        var pass: String?
        if let at = authority.lastIndex(of: "@") {
            let info = String(authority[authority.startIndex..<at])
            hostPort = String(authority[authority.index(after: at)...])
            if let colon = info.firstIndex(of: ":") {
                user = String(info[info.startIndex..<colon]).removingRTSPPercentEncoding
                pass = String(info[info.index(after: colon)...]).removingRTSPPercentEncoding
            } else {
                user = info.removingRTSPPercentEncoding
            }
        }

        var parsedHost = hostPort
        var parsedPort: Int?
        if hostPort.hasPrefix("[") {                       // IPv6 字面量
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            parsedHost = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let rest = String(hostPort[hostPort.index(after: close)...])
            if rest.hasPrefix(":") {
                guard let p = Int(rest.dropFirst()), (1...65535).contains(p) else { return nil }
                parsedPort = p
            }
        } else if let colon = hostPort.lastIndex(of: ":") {
            let text = String(hostPort[hostPort.index(after: colon)...])
            guard let p = Int(text), (1...65535).contains(p) else { return nil }
            parsedHost = String(hostPort[hostPort.startIndex..<colon])
            parsedPort = p
        }

        guard !parsedHost.isEmpty, !parsedHost.contains(" ") else { return nil }

        self.scheme = parsedScheme
        self.host = parsedHost
        self.hasExplicitPort = parsedPort != nil
        self.port = parsedPort ?? (parsedScheme == "rtsps" ? Self.defaultTLSPort : Self.defaultPort)
        self.pathAndQuery = tail.isEmpty ? "/" : tail
        self.username = user
        self.password = pass
    }

    /// 发给服务器的 Request-URI，绝不带凭据。
    var requestURI: String {
        "\(scheme)://\(hostForURI)\(portSuffix)\(pathAndQuery)"
    }

    /// 展示与保存用；同样不含密码。
    var displayString: String { requestURI }

    /// 历史去重的键：host 大小写不敏感，路径保持原样。
    var identity: String {
        "\(scheme)://\(hostForURI.lowercased())\(portSuffix)\(pathAndQuery)"
    }

    private var hostForURI: String { host.contains(":") ? "[\(host)]" : host }

    private var portSuffix: String {
        (hasExplicitPort || port != schemeDefaultPort) ? ":\(port)" : ""
    }

    /// 追加子路径，用于 SETUP 时拼接 SDP 里的相对 control 值。
    func appendingControl(_ control: String) -> String {
        if control.isEmpty || control == "*" { return requestURI }
        if control.lowercased().hasPrefix("rtsp://") || control.lowercased().hasPrefix("rtsps://") {
            return control
        }
        var base = requestURI
        if base.hasSuffix("/") { base.removeLast() }
        return control.hasPrefix("/") ? base + control : base + "/" + control
    }
}

nonisolated extension String {
    /// 凭据里的 %XX 需要还原，但非法转义时保留原文而不是丢掉整串。
    var removingRTSPPercentEncoding: String {
        contains("%") ? (removingPercentEncoding ?? self) : self
    }
}
