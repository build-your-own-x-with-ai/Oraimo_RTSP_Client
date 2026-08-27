//
//  测量 preroll 带来的实际显示延迟，并检查 B 帧乱序是否还装得下。
//
//  原理：MediaRenderer 把时基设成「首帧 PTS - preroll」，所以任何一帧
//  在送进渲染器的那一刻，它的 PTS 都比当前播放时刻晚 preroll。
//  这个差值就是 preroll 摊到端到端延迟里的部分，可以直接量。
//
//  同时量 late 帧数（lag < 0）。这一项是给 H.265 用的：那条流有 B 帧，
//  解码顺序里 PTS 不单调，乱序幅度必须小于 preroll，否则帧送进渲染器时
//  PTS 已经过去了，会被立刻显示或丢掉 —— 缩小 preroll 就是在压这个余量。
//
//  用法：ltest [标签] [--h265]
//

import Foundation
import AVFoundation
import CoreMedia

let label = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "current"
let useH265 = CommandLine.arguments.contains("--h265")
let rtpFile = useH265 ? "video265.rtp" : "video.rtp"
let sdpFile = useH265 ? "video265.sdp" : "video.sdp"

func readFile(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

func loadPackets(_ path: String) -> [Data] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let bytes = [UInt8](data)
    var packets: [Data] = []
    var i = 0
    while i + 4 <= bytes.count {
        let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16
            | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        i += 4
        guard n > 0, i + n <= bytes.count else { break }
        packets.append(Data(bytes[i..<i + n]))
        i += n
    }
    return packets
}

guard let media = try? SDPSession.parse(Data(readFile(sdpFile).utf8)).video,
      var depacketizer = VideoDepacketizer(media: media) else {
    print("无法建解包器"); exit(2)
}

// 先把解包做完，别让解包耗时混进计时循环。
var units: [VideoAccessUnit] = []
for raw in loadPackets(rtpFile) {
    guard let packet = RTPPacket(raw) else { continue }
    units.append(contentsOf: depacketizer.process(packet))
}
guard let format = depacketizer.formatDescription, units.count > 40 else {
    print("解包结果不足：\(units.count)"); exit(3)
}

let clock = MediaClock(clockRate: media.clockRate)
clock.applyRTPInfo(units[0].rtpTimestamp)      // 首帧 PTS 归零

let renderer = MediaRenderer()
let frameDuration = CMTime(value: 1, timescale: 30)

var lags: [Double] = []
var late = 0
var enqueued = 0
// 乱序幅度：解码顺序里当前 PTS 比已见最大 PTS 落后多少。
var maxReorder = 0.0
var peakPTS = 0.0
let start = Date()

for (index, unit) in units.enumerated() {
    let pts = clock.videoTime(unit.rtpTimestamp)
    let seconds = pts.seconds
    if seconds > peakPTS { peakPTS = seconds }
    maxReorder = max(maxReorder, peakPTS - seconds)

    // 按「PTS 的运行最大值」控节奏，和 server.py 的排程键一致：
    // 有 B 帧时 PTS 本身不单调，直接按 PTS 睡会把节奏搞乱。
    let delay = peakPTS - Date().timeIntervalSince(start)
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }

    guard let buffer = SampleBufferFactory.video(unit, format: format,
                                                 pts: pts, duration: frameDuration)
    else { continue }

    // 必须在 enqueue 之前读：首帧的 enqueue 才会启动时基。
    let now = renderer.currentTime
    renderer.enqueueVideo(buffer)
    enqueued += 1

    // 前 15 帧跳过：时基是在渲染器队列上异步启动的，头几帧还没稳。
    if index >= 15, now.isValid {
        let lag = CMTimeSubtract(pts, now).seconds
        if lag.isFinite {
            lags.append(lag)
            if lag < 0 { late += 1 }
        }
    }
}

guard !lags.isEmpty else { print("没量到有效样本"); exit(4) }

let sorted = lags.sorted()
let mean = lags.reduce(0, +) / Double(lags.count)
let median = sorted[sorted.count / 2]
func ms(_ v: Double) -> String { String(format: "%.1f", v * 1000) }

print("label=\(label)")
print("codec=\(useH265 ? "h265" : "h264")")
print("frames_enqueued=\(enqueued)")
print("samples=\(lags.count)")
print("added_latency_mean_ms=\(ms(mean))")
print("added_latency_median_ms=\(ms(median))")
print("added_latency_min_ms=\(ms(sorted[0]))")
print("added_latency_max_ms=\(ms(sorted[sorted.count - 1]))")
print("max_reorder_ms=\(ms(maxReorder))")
// late > 0 表示有帧送进渲染器时 PTS 已经过去了 —— preroll 不够装乱序。
print("late_frames=\(late)")
renderer.stop()
