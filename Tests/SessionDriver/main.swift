//
//  端到端测试：对测试服务器跑完整 RTSP 会话。
//
//  只收视频。音频相关的采集全部去掉了，但 audio_pt_blocked 这个指标要留着 ——
//  它统计的是「混进视频通道的音频包有没有被挡住」，那是画面正确性的指标。
//

import Foundation
import CoreMedia

let address = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "rtsp://127.0.0.1:8554/livestream/1/"
let runSeconds = CommandLine.arguments.contains("--long") ? 9.0 : 5.0
// 直接指定交织，跳过 UDP 探测。用来单独验交织通路。
let forceInterleaved = CommandLine.arguments.contains("--interleaved")

guard let url = RTSPURL(string: address) else {
    print("地址无法解析：\(address)")
    exit(2)
}

final class Collector: @unchecked Sendable {
    let lock = NSLock()
    var stages: [String] = []
    var videoSamples = 0
    var firstVideoPTS: CMTime?
    var lastVideoPTS: CMTime?
    var info: RTSPSession.MediaInfo?
    var stats: RTSPSession.Statistics?
    var error: RTSPError?
    var formatChanges = 0
    var nonMonotonicVideo = 0
    var keyframes = 0

    func note(_ block: (Collector) -> Void) {
        lock.lock(); block(self); lock.unlock()
    }
}

let collector = Collector()
let done = DispatchSemaphore(value: 0)

let session = RTSPSession(url: url,
                          transport: forceInterleaved ? .interleaved : .udp) { event in
    switch event {
    case .stage(let stage):
        collector.note { $0.stages.append("\(stage)") }
    case .info(let info):
        collector.note { $0.info = info }
    case .statistics(let stats):
        collector.note { $0.stats = stats }
    case .formatChanged:
        collector.note { $0.formatChanges += 1 }
    case .video(let box):
        let pts = CMSampleBufferGetPresentationTimeStamp(box.buffer)
        let isKey = box.buffer.isKeyframeSample
        collector.note {
            $0.videoSamples += 1
            if $0.firstVideoPTS == nil { $0.firstVideoPTS = pts }
            if let last = $0.lastVideoPTS, CMTimeCompare(pts, last) <= 0 {
                $0.nonMonotonicVideo += 1
            }
            $0.lastVideoPTS = pts
            if isKey { $0.keyframes += 1 }
        }
    case .failed(let error):
        collector.note { $0.error = error }
        done.signal()
    }
}

session.start()
_ = done.wait(timeout: .now() + runSeconds)
session.stop()
Thread.sleep(forTimeInterval: 0.4)

// 输出成 key=value，交给外层脚本断言。
collector.lock.lock()
print("stages=\(collector.stages.joined(separator: ">"))")
print("video_samples=\(collector.videoSamples)")
print("keyframes=\(collector.keyframes)")
print("format_changes=\(collector.formatChanges)")
print("non_monotonic_video=\(collector.nonMonotonicVideo)")
if let info = collector.info {
    print("video_codec=\(info.videoCodec ?? "-")")
    print("dimensions=\(info.width)x\(info.height)")
}
if let stats = collector.stats {
    print("bytes=\(stats.bytesReceived)")
    print("dropped=\(stats.droppedPackets)")
    print(String(format: "bitrate_kbps=%.0f", stats.bitrateKbps))
    print(String(format: "fps=%.1f", stats.fps))
}
if let first = collector.firstVideoPTS, let last = collector.lastVideoPTS {
    print(String(format: "video_pts_start=%.3f", first.seconds))
    print(String(format: "video_span=%.3f", CMTimeSubtract(last, first).seconds))
}
if let error = collector.error {
    print("error=\(error.localizedDescription)")
    print("is_auth_error=\(error.isAuthError)")
}
collector.lock.unlock()
