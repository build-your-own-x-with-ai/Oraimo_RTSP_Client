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
    ///
    /// 只在没有 Content-Base 的设备上等价于正确答案。有那个头的时候必须用
    /// `resolveControl(_:base:)` —— 见它的注释。
    func appendingControl(_ control: String) -> String {
        Self.resolveControl(control, base: requestURI)
    }

    /// 把 SDP 里的 control 值解析成绝对 URI。
    ///
    /// base 是 DESCRIBE 应答定下的基址，不一定等于请求 URL。那台记录仪
    /// （LIVE555）用 `/xxx.mov` 收 DESCRIBE，却在 Content-Base 里给
    /// `rtsp://192.168.1.254/00000000/`，media 的 control 是相对的 `track1`。
    /// 按请求 URL 拼会得到 `/xxx.mov/track1`，SETUP 过不去。
    ///
    /// 拼接用的是「基址后面接一段」，不是 RFC 3986 那套「替换最后一段」。
    /// RTSP 服务器（含 LIVE555 自己）实际就是这么拼的，抓包里 VLC 发的也是
    /// 这个形态。按 3986 严格解析反而对不上。
    static func resolveControl(_ control: String, base: String) -> String {
        // `*` 是聚合控制，指基址本身。空值同样落回基址。
        if control.isEmpty || control == "*" { return base }
        if control.isAbsoluteRTSP { return control }
        var b = base
        if b.hasSuffix("/") { b.removeLast() }
        return control.hasPrefix("/") ? b + control : b + "/" + control
    }
}

nonisolated extension String {
    /// 是不是一个绝对的 rtsp / rtsps URI。
    var isAbsoluteRTSP: Bool {
        let s = lowercased()
        return s.hasPrefix("rtsp://") || s.hasPrefix("rtsps://")
    }

    /// 凭据里的 %XX 需要还原，但非法转义时保留原文而不是丢掉整串。
    var removingRTSPPercentEncoding: String {
        contains("%") ? (removingPercentEncoding ?? self) : self
    }
}
