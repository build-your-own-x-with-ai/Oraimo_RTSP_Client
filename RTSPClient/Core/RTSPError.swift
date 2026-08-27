//
//  RTSPError.swift
//  RTSPClient
//
//  RTSP 各阶段的错误定义。
//

import Foundation

nonisolated enum RTSPError: LocalizedError, Equatable {
    case invalidURL(String)
    case connectionFailed(String)
    case connectionClosed
    case timeout(method: String)
    case malformedResponse(String)
    case status(code: Int, reason: String, method: String)
    case authenticationRequired
    case authenticationFailed
    case unsupportedTransport
    /// UDP 通了 PLAY 但一个包都没来。内部信号：上层据此改走 TCP 交织重试。
    case udpNoData
    case noSupportedMedia
    case sdpParseFailed(String)
    case sessionMissing
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s):            return "地址无法解析：\(s)"
        case .connectionFailed(let s):      return "连接失败：\(s)"
        case .connectionClosed:             return "连接已被对方关闭"
        case .timeout(let m):               return "\(m) 请求超时"
        case .malformedResponse(let s):     return "响应格式错误：\(s)"
        case .status(let c, let r, let m):  return "\(m) 失败：\(c) \(r)"
        case .authenticationRequired:       return "需要用户名和密码"
        case .authenticationFailed:         return "用户名或密码错误"
        case .unsupportedTransport:         return "服务器既不接受 UDP 也不接受 TCP interleaved 传输"
        case .udpNoData:                    return "UDP 上没有收到媒体数据"
        case .noSupportedMedia:             return "SDP 中没有可播放的音视频轨道"
        case .sdpParseFailed(let s):        return "SDP 解析失败：\(s)"
        case .sessionMissing:               return "服务器未返回 Session"
        case .cancelled:                    return "已取消"
        }
    }

    /// 是否为凭据问题，UI 据此弹出账号密码输入。
    var isAuthError: Bool {
        switch self {
        case .authenticationRequired, .authenticationFailed: return true
        case .status(let c, _, _):                           return c == 401 || c == 403
        default:                                             return false
        }
    }
}
