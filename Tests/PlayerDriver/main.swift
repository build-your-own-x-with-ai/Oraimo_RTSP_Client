//
//  播放器层端到端测试：验证 UDP 收不到数据时自动换 TCP 交织重来。
//
//  会话层的驱动只能看到 error=udpNoData 就结束了；把那个错误变成
//  「换交织重连、真的出画面」的逻辑在 RTSPPlayer.applyFailure 里，
//  只有从播放器这一层驱动才能覆盖到。
//

import Foundation
import CoreMedia
import Observation

let address = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "rtsp://127.0.0.1:8554/livestream/1/"
let runSeconds = CommandLine.arguments.contains("--long") ? 14.0 : 9.0

// 用独立的 suite，别碰用户真实的历史记录。
let suiteName = "rtsptest.player.\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: suiteName) else {
    print("无法创建 UserDefaults suite")
    exit(2)
}
let history = StreamHistoryStore(defaults: defaults)
let player = RTSPPlayer(history: history)

/// 记录状态变化的轨迹，用来分辨走的是哪条恢复路径。
final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private var attempts: [Int] = []
    private var failure = "-"

    func note(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        if seen.last != s { seen.append(s) }
    }
    /// 退避重连的次数要按出现顺序记全，不能只看最后一眼的值。
    /// 重连成功后 reconnectAttempt 会归零，跑完再读就什么都看不到了。
    func noteAttempt(_ n: Int) {
        lock.lock(); defer { lock.unlock() }
        if n > 0, !attempts.contains(n) { attempts.append(n) }
    }
    /// 失败信息也要当场抓：stop() 之后状态被清成 idle，就没了。
    func noteFailure(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        if failure == "-" { failure = message }
    }
    var path: String {
        lock.lock(); defer { lock.unlock() }
        return seen.joined(separator: ">")
    }
    var attemptList: String {
        lock.lock(); defer { lock.unlock() }
        return attempts.isEmpty ? "-" : attempts.map(String.init).joined(separator: ",")
    }
    var failureMessage: String {
        lock.lock(); defer { lock.unlock() }
        return failure
    }
}
let trace = Trace()

func label(_ state: RTSPPlayer.State) -> String {
    switch state {
    case .idle:       return "idle"
    case .connecting: return "connecting"
    case .buffering:  return "buffering"
    case .playing:    return "playing"
    case .paused:     return "paused"
    case .failed:     return "failed"
    }
}

DispatchQueue.main.async {
    player.play(address: address)
}

// 状态轨迹用「观察 + 轮询」两条路一起记。
//
// 光靠轮询不行：换交织那次重连里 connecting → buffering 在本机只要两三毫秒，
// 10ms 采样也会漏（实测漏过一次，路径看起来就像没重连过）。
// 光靠观察也不稳：@Observable 的 onChange 在写入前触发，得延一拍才读到新值，
// 同一轮里连续两次变更仍可能只看到最后一个。
// 两条路并用，谁先看到算谁的 —— Trace 自己去重。
func armObservation() {
    withObservationTracking {
        _ = player.state
    } onChange: {
        // onChange 是写入前回调，延一拍才读得到新值。
        DispatchQueue.main.async {
            trace.note(label(player.state))
            armObservation()
        }
    }
}
armObservation()

let poll = DispatchSource.makeTimerSource(queue: .main)
poll.schedule(deadline: .now() + 0.002, repeating: 0.002)
poll.setEventHandler {
    trace.note(label(player.state))
    trace.noteAttempt(player.reconnectAttempt)
    if case .failed(let message) = player.state { trace.noteFailure(message) }
}
poll.resume()

DispatchQueue.main.asyncAfter(deadline: .now() + runSeconds) {
    poll.cancel()
    let stats = player.statistics
    print("state_path=\(trace.path)")
    print("final_state=\(label(player.state))")
    print("video_frames=\(stats?.videoFrames ?? 0)")
    print("bytes=\(stats?.bytesReceived ?? 0)")
    print("dropped=\(stats?.droppedPackets ?? 0)")
    print("reconnect_attempt=\(player.reconnectAttempt)")
    // 两条恢复路径要能分开看：
    // reconnect_attempts 有值 = 走了退避重连（连接真的断了）；
    // 全程为 - 而 state_path 里出现第二段 connecting = 走的是换传输重来。
    print("reconnect_attempts=\(trace.attemptList)")
    print("status_text=\(player.statusText)")
    if let info = player.mediaInfo {
        print("codec=\(info.videoCodec ?? "-")")
        print("dimensions=\(info.width)x\(info.height)")
    }
    print("needs_credentials=\(player.needsCredentials)")
    print("history_entries=\(history.entries.count)")
    print("history_playcount=\(history.entries.first?.playCount ?? 0)")
    print("failure_message=\(trace.failureMessage)")
    if case .failed(let message) = player.state { print("error=\(message)") }
    player.stop()
    defaults.removePersistentDomain(forName: suiteName)
    exit(0)
}

RunLoop.main.run()
