//
//  RTSPSession+Receive.swift
//  RTSPClient
//
//  interleaved 数据 -> RTP -> 解包 -> CMSampleBuffer，
//  另外负责保活和码率统计。
//

import Foundation
import CoreMedia

nonisolated extension RTSPSession {
    func handle(_ event: RTSPConnection.Event) {
        switch event {
        case .failed(let error):
            finish(with: error)

        case .serverRequest(_, _, let cseq):
            // 设备主动发 OPTIONS / GET_PARAMETER 探活，回 200 就行。
            connection.sendRawResponse(cseq: cseq, session: sessionID)

        case .interleaved(let channel, let payload):
            statsWindowBytes += payload.count
            stats.bytesReceived += payload.count
            noteMediaArrived()
            // 只认 SETUP 协商下来的通道号。"偶数 RTP、奇数 RTCP" 只是惯例，
            // 摄像机把视频分到奇数通道时，按奇偶过滤会把整路视频丢掉。
            // 各轨的 RTCP 固定在 RTP 通道 +1，暂不解析。
            if channel == videoChannel {
                guard let packet = RTPPacket(payload) else { return }
                // 有固件把音频也发到视频通道上。按负载类型挡掉，否则 PCMA
                // 数据会被当成 H.264 NAL 解，凭空造出一堆假帧
                //（实测 150 帧的流能多出 32 帧）。
                guard !isForeignPayload(packet.payloadType, expected: videoPayloadType,
                                        other: audioPayloadType) else { return }
                handleVideo(packet)
            }
        }
    }

    /// UDP 上收到的一个数据报。负载类型的过滤照旧留着 ——
    /// 有固件会把音频也往这个端口发。
    func handleUDP(_ datagram: Data) {
        guard !isStopped else { return }
        statsWindowBytes += datagram.count
        stats.bytesReceived += datagram.count
        noteMediaArrived()

        guard let packet = RTPPacket(datagram) else { return }
        guard !isForeignPayload(packet.payloadType, expected: videoPayloadType,
                                other: audioPayloadType) else { return }
        handleVideo(packet)
    }

    /// 媒体数据到了，撤掉起播看门狗。
    func noteMediaArrived() {
        guard !didReceiveMedia else { return }
        didReceiveMedia = true
        firstMediaWatchdog?.cancel()
        firstMediaWatchdog = nil
    }

    /// PLAY 成功之后守着第一个包。
    ///
    /// 只在 UDP 上守：交织的数据和信令同一条 TCP，PLAY 都回来了就说明链路是通的，
    /// 没来数据是别的原因，交给上层的首帧超时去说明。UDP 不一样 —— 端口被防火墙
    /// 挡掉、或者服务器压根不往我们报的端口发，握手全绿也一个字节都不会来。
    /// 那种情况下 3 秒就够判死，然后换交织重来，不用让用户等满 12 秒。
    func startFirstMediaWatchdog() {
        guard transportMode == .udp, !didReceiveMedia else { return }
        firstMediaWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: connection.queue)
        timer.schedule(deadline: .now() + Self.udpFirstMediaTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopped, !self.didReceiveMedia else { return }
            self.firstMediaWatchdog = nil
            self.finish(with: .udpNoData)
        }
        timer.resume()
        firstMediaWatchdog = timer
    }

    /// 这个包是不是另一条轨串过来的。
    ///
    /// 只在「明确认得出是对面那条轨」时才丢：有摄像机发的负载类型和 SDP
    /// 声明的并不一致，一律按 SDP 严格比对会把整路正常数据丢光。
    private func isForeignPayload(_ actual: Int, expected: Int, other: Int) -> Bool {
        guard other >= 0, other != expected else { return false }
        return actual != expected && actual == other
    }

    // MARK: - 视频

    private func handleVideo(_ packet: RTPPacket) {
        // 按「应收 - 实收」估丢包，乱序（B 帧、网络抖动）不会算歪。
        videoLoss.note(packet.sequenceNumber)
        stats.droppedPackets = videoLoss.lost

        guard var depacketizer = videoDepacketizer, let clock else { return }
        let units = depacketizer.process(packet)
        videoDepacketizer = depacketizer
        guard !units.isEmpty else { return }

        for unit in units {
            if unit.formatDidChange, let format = depacketizer.formatDescription {
                videoFormat = format
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                if dimensions.width != info.width || dimensions.height != info.height {
                    info.width = dimensions.width
                    info.height = dimensions.height
                    events(.info(info))
                }
                events(.formatChanged)
            }
            guard let format = videoFormat ?? depacketizer.formatDescription else { continue }
            videoFormat = format

            let pts = clock.videoTime(unit.rtpTimestamp)
            // 直播不知道下一帧何时到，用上一帧间隔当时长估计。
            if let last = lastVideoPTS {
                let delta = CMTimeSubtract(pts, last)
                if delta.isValid, delta.seconds > 0, delta.seconds < 1 {
                    lastFrameDuration = delta
                }
            }
            lastVideoPTS = pts

            guard let buffer = SampleBufferFactory.video(unit, format: format, pts: pts,
                                                         duration: lastFrameDuration)
            else { continue }
            stats.videoFrames += 1
            statsWindowFrames += 1
            events(.video(SampleBox(buffer)))
        }
    }

    // MARK: - 保活

    func startKeepAlive() {
        keepAlive?.cancel()
        // 留一半余量，别卡在 timeout 边缘上。
        let interval = max(10, Double(sessionTimeout) / 2)
        let timer = DispatchSource.makeTimerSource(queue: connection.queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopped, let sessionID = self.sessionID else { return }
            // 优先 GET_PARAMETER，设备不支持就退回 OPTIONS。
            let method: RTSPMethod = self.supportsGetParameter ? .getParameter : .options
            var request = RTSPRequest(method: method, uri: self.url.requestURI)
            request.set("Session", sessionID)
            self.authorize(&request)
            self.connection.send(request, timeout: 15) { [weak self] result in
                guard let self else { return }
                // 保活失败说明链路已断，交给上层重连。
                if case .failure(let error) = result, error != .cancelled {
                    self.finish(with: error)
                }
            }
        }
        timer.resume()
        keepAlive = timer
    }

    // MARK: - 统计

    func startStatistics() {
        statsTimer?.cancel()
        statsWindowStart = CFAbsoluteTimeGetCurrent()
        statsWindowBytes = 0
        statsWindowFrames = 0
        let timer = DispatchSource.makeTimerSource(queue: connection.queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopped else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = max(0.001, now - self.statsWindowStart)
            self.stats.bitrateKbps = Double(self.statsWindowBytes) * 8 / elapsed / 1000
            self.stats.fps = Double(self.statsWindowFrames) / elapsed
            self.statsWindowBytes = 0
            self.statsWindowFrames = 0
            self.statsWindowStart = now
            self.events(.statistics(self.stats))
        }
        timer.resume()
        statsTimer = timer
    }
}
