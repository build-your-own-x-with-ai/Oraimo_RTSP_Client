//
//  RTPUDPTransport.swift
//  RTSPClient
//
//  RTP over UDP：一对连号端口，偶数收 RTP，奇数占住 RTCP。
//  回调都在传进来的 queue 上，和信令共用一条队列。
//

import Foundation
import Darwin

nonisolated final class RTPUDPTransport: @unchecked Sendable {
    /// 客户端 RTP 端口，SETUP 的 client_port 用它；RTCP 固定为它 +1。
    let rtpPort: Int
    var rtcpPort: Int { rtpPort + 1 }

    private let queue: DispatchQueue
    private var rtpFD: Int32
    private var rtcpFD: Int32
    private var rtpSource: DispatchSourceRead?
    private var rtcpSource: DispatchSourceRead?
    private var started = false
    private var closed = false

    /// 一次可读事件最多取多少个包。读源是电平触发的，没取完下一轮还会来，
    /// 加个上限只是防止对面猛灌时一直占着队列，把信令饿死。
    private static let maxPacketsPerDrain = 256
    /// 关键帧会一次性到三十多个包，收缓冲给足，别在内核里就丢了。
    private static let receiveBufferSize: Int32 = 512 * 1024

    /// 用 POSIX socket 而不是 NWConnection，两个原因都来自实测抓包：
    ///
    /// 1. SETUP 的应答里既没有 server_port 也没有 source，发送端口无从得知，
    ///    socket 必须保持未连接状态，谁发来都收。
    /// 2. 摄像机自己不听 RTCP，我们往它的 RTCP 端口发东西会换回 ICMP
    ///    port unreachable。在「已连接」的 UDP socket 上，那玩意儿会变成
    ///    ECONNREFUSED 报到读回调里，把一条本来好好的流判成断线。
    init?(queue: DispatchQueue) {
        guard let pair = Self.openPair() else { return nil }
        self.queue = queue
        self.rtpPort = pair.port
        self.rtpFD = pair.rtp
        self.rtcpFD = pair.rtcp
    }

    deinit {
        // 正常路径由会话显式 close()，这里只兜底。
        // source 建起来了就由它的 cancelHandler 关 fd，没建就直接关。
        guard !closed else { return }
        if let rtpSource { rtpSource.cancel() } else if rtpFD >= 0 { Darwin.close(rtpFD) }
        if let rtcpSource { rtcpSource.cancel() } else if rtcpFD >= 0 { Darwin.close(rtcpFD) }
    }

    // MARK: - 生命周期

    /// 开始收包。要在 SETUP 之前调用：有的固件收到 SETUP 应答的确认前就开始发，
    /// 端口没人听的话那几个包会换来一串 ICMP。
    func start(onRTP: @escaping (Data) -> Void) {
        guard !closed, !started else { return }
        started = true
        let rtp = makeSource(fd: rtpFD, handler: onRTP)
        // RTCP 端口只占位：我们不发 RR，但摄像机可能发 SR。
        // 不读的话内核缓冲会满，所以照样抽干，只是丢掉。
        let rtcp = makeSource(fd: rtcpFD, handler: { _ in })
        rtpSource = rtp
        rtcpSource = rtcp
        rtp.resume()
        rtcp.resume()
    }

    func close() {
        guard !closed else { return }
        closed = true
        if started {
            // fd 由 source 的 cancelHandler 负责关。
            rtpSource?.cancel()
            rtcpSource?.cancel()
        } else {
            // 挂起状态的 source cancel 不会触发 cancelHandler，
            // 所以没 start 过的情况只能自己关 —— 不然就是 fd 泄漏。
            if rtpFD >= 0 { Darwin.close(rtpFD) }
            if rtcpFD >= 0 { Darwin.close(rtcpFD) }
        }
        rtpSource = nil
        rtcpSource = nil
        rtpFD = -1
        rtcpFD = -1
    }

    // MARK: - 收包

    private func makeSource(fd: Int32, handler: @escaping (Data) -> Void) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain(fd: fd, handler: handler)
        }
        // fd 的所有权交给 source：只有 cancelHandler 里能关。
        // 提前关掉的话，同一个号可能被别的 socket 复用，
        // source 就会去读一个毫不相干的连接。
        source.setCancelHandler { Darwin.close(fd) }
        return source
    }

    /// 把内核缓冲里攒的包一次性取干净，直到 EAGAIN。
    private func drain(fd: Int32, handler: (Data) -> Void) {
        // UDP 数据报最大 65507 字节，给满。
        var bytes = [UInt8](repeating: 0, count: 64 * 1024 + 64)
        for _ in 0..<Self.maxPacketsPerDrain {
            let n = bytes.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            if n > 0 {
                handler(Data(bytes[0..<n]))
                continue
            }
            if n == 0 { continue }                  // 空数据报，不是流结束
            // EAGAIN / EWOULDBLOCK：取完了。EINTR：被信号打断，重试。
            if errno == EINTR { continue }
            return
        }
    }

    // MARK: - 端口

    private struct Pair {
        let port: Int
        let rtp: Int32
        let rtcp: Int32
    }

    /// 抢一对连号端口：偶数收 RTP，奇数留给 RTCP。
    ///
    /// 不能让内核分配（bind 到 0）—— 那样两个号未必连号，而 RFC 3550 的
    /// 「RTP 偶数、RTCP 紧跟」是固件普遍照着做的假设：不少设备根本不看
    /// 我们报的 RTCP 端口，直接往 client_port+1 发。
    ///
    /// 只开 IPv4。摄像机是局域网里的 v4 设备；万一碰上纯 IPv6 的服务器，
    /// 它会往一个没人听的地址发 RTP，然后由会话那边的首帧看门狗退回 TCP 交织。
    private static func openPair() -> Pair? {
        for _ in 0..<32 {
            let port = Int.random(in: 20_000...59_000) & ~1      // 抹掉低位取偶数
            guard let rtp = openSocket(port: port) else { continue }
            guard let rtcp = openSocket(port: port + 1) else {
                Darwin.close(rtp)
                continue
            }
            return Pair(port: port, rtp: rtp, rtcp: rtcp)
        }
        return nil
    }

    private static func openSocket(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }

        var size = receiveBufferSize
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: in_addr_t(0))         // INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            return nil
        }

        // 非阻塞：读回调里要一路 recv 到 EAGAIN 为止。
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }
}
