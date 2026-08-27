//
//  RTSPConnection.swift
//  RTSPClient
//
//  信令和 RTP 数据共用这一条 TCP 连接（interleaved 模式）。
//  所有可变状态只在 queue 上访问，对外回调也都在 queue 上。
//

import Foundation
import Network

nonisolated final class RTSPConnection: @unchecked Sendable {
    enum Event: Sendable {
        /// interleaved 数据，channel 区分 RTP / RTCP。
        case interleaved(channel: Int, payload: Data)
        /// 服务器主动发来的请求，不回应会被判定掉线。
        case serverRequest(method: String, uri: String, cseq: Int?)
        case failed(RTSPError)
    }

    typealias ResponseHandler = (Result<RTSPResponse, RTSPError>) -> Void

    private struct Pending {
        let cseq: Int
        let method: String
        let handler: ResponseHandler
        let timeout: DispatchWorkItem
    }

    let queue = DispatchQueue(label: "com.iosdevlog.rtsp.connection")

    private let host: String
    private let port: Int
    private let usesTLS: Bool
    private var connection: NWConnection?
    private var buffer = RTSPByteBuffer()
    private var pending: [Pending] = []
    private var nextCSeq = 1
    private var isClosed = false
    private var events: ((Event) -> Void)?

    /// 解析跑偏时不要无限攒数据。
    private static let maxMessageSize = 2 * 1024 * 1024

    init(host: String, port: Int, usesTLS: Bool) {
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
    }
    // MARK: - 连接

    func start(events: @escaping (Event) -> Void, ready: @escaping (RTSPError?) -> Void) {
        queue.async {
            self.events = events

            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true                    // 信令是小包，等 Nagle 会拖慢握手
            tcp.connectionTimeout = 10
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30

            let tls: NWProtocolTLS.Options? = self.usesTLS ? NWProtocolTLS.Options() : nil
            let parameters = NWParameters(tls: tls, tcp: tcp)
            let endpoint = NWEndpoint.Host(self.host)
            guard let port = NWEndpoint.Port(rawValue: UInt16(self.port)) else {
                ready(.connectionFailed("端口无效：\(self.port)"))
                return
            }

            let connection = NWConnection(host: endpoint, port: port, using: parameters)
            self.connection = connection

            var didSignal = false
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !didSignal else { return }
                    didSignal = true
                    self.receiveLoop()
                    ready(nil)
                case .failed(let error):
                    if !didSignal {
                        didSignal = true
                        ready(.connectionFailed(error.localizedDescription))
                    } else {
                        self.fail(.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if !didSignal { didSignal = true; ready(.cancelled) }
                case .waiting(let error):
                    // 地址不可达时 NWConnection 会一直等，这里直接判失败更符合预期。
                    if !didSignal {
                        didSignal = true
                        ready(.connectionFailed(error.localizedDescription))
                    }
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    func close() {
        queue.async {
            guard !self.isClosed else { return }
            self.isClosed = true
            for item in self.pending {
                item.timeout.cancel()
                item.handler(.failure(.cancelled))
            }
            self.pending.removeAll()
            self.events = nil
            self.buffer.removeAll()
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    // MARK: - 收发

    /// 必须在 queue 上调用。
    private func fail(_ error: RTSPError) {
        guard !isClosed else { return }
        isClosed = true
        let handlers = pending
        pending.removeAll()
        for item in handlers {
            item.timeout.cancel()
            item.handler(.failure(error))
        }
        let sink = events
        events = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        sink?(.failed(error))
    }

    func send(_ request: RTSPRequest,
              timeout: TimeInterval = 10,
              completion: @escaping ResponseHandler) {
        queue.async {
            guard !self.isClosed, let connection = self.connection else {
                completion(.failure(.connectionClosed))
                return
            }
            let cseq = self.nextCSeq
            self.nextCSeq += 1

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard let i = self.pending.firstIndex(where: { $0.cseq == cseq }) else { return }
                let item = self.pending.remove(at: i)
                item.handler(.failure(.timeout(method: item.method)))
            }
            self.pending.append(Pending(cseq: cseq, method: request.method.rawValue,
                                        handler: completion, timeout: work))
            self.queue.asyncAfter(deadline: .now() + timeout, execute: work)

            connection.send(content: request.serialized(cseq: cseq),
                            completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                self.fail(.connectionFailed(error.localizedDescription))
            })
        }
    }

    /// 回应服务器主动发来的请求，保持会话活着。
    func sendRawResponse(cseq: Int?, session: String?) {
        queue.async {
            guard !self.isClosed, let connection = self.connection else { return }
            var text = "RTSP/1.0 200 OK\r\n"
            if let cseq { text += "CSeq: \(cseq)\r\n" }
            if let session { text += "Session: \(session)\r\n" }
            text += "\r\n"
            connection.send(content: Data(text.utf8), completion: .idempotent)
        }
    }

    private func receiveLoop() {
        guard !isClosed, let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.fail(.connectionFailed(error.localizedDescription))
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if isComplete {
                self.fail(.connectionClosed)
                return
            }
            guard !self.isClosed else { return }
            self.receiveLoop()
        }
    }

    /// 逐条消费缓冲：`$` 开头是 interleaved 帧，否则按文本消息解析。
    private func drain() {
        while !isClosed {
            guard let first = buffer.peek(0) else { return }

            if first == 0x24 {                                  // '$'
                guard let channel = buffer.peek(1),
                      let length = buffer.peekUInt16BE(2) else { return }
                guard buffer.count >= 4 + length else { return }
                buffer.skip(4)
                guard let payload = buffer.take(length) else { return }
                events?(.interleaved(channel: Int(channel), payload: payload))
                continue
            }

            let snapshot = buffer.remaining
            guard let parsed = RTSPHead.parse(snapshot) else {
                // 头还没齐。始终没有 CRLFCRLF 说明流已经错位。
                if buffer.count > Self.maxMessageSize {
                    fail(.malformedResponse("消息过长，数据流可能已错位"))
                }
                return
            }
            let total = parsed.headLength + parsed.contentLength
            guard snapshot.count >= total else { return }        // 等 body
            let body = parsed.contentLength > 0
                ? snapshot.subdata(in: parsed.headLength..<total)
                : Data()
            buffer.skip(total)
            dispatch(parsed.message, body: body)
        }
    }

    private func dispatch(_ message: RTSPIncoming, body: Data) {
        switch message {
        case .request(let method, let uri, let cseq):
            events?(.serverRequest(method: method, uri: uri, cseq: cseq))
        case .response(var response):
            response.body = body
            // 有设备不回 CSeq，退化成按发送顺序配对。
            let index = response.cseq.flatMap { c in pending.firstIndex { $0.cseq == c } }
                ?? (pending.isEmpty ? nil : 0)
            guard let index else { return }
            let item = pending.remove(at: index)
            item.timeout.cancel()
            item.handler(.success(response))
        }
    }
}
