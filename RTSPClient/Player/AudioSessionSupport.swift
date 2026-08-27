//
//  AudioSessionSupport.swift
//  RTSPClient
//
//  iOS / visionOS 上不配置 AVAudioSession，AVSampleBufferAudioRenderer
//  是没有声音的（静音开关也会把它压掉）。macOS 没有这套机制。
//

import Foundation
#if canImport(UIKit)
import AVFoundation

nonisolated enum AudioSessionSupport {
    private static let lock = NSLock()
    private static var isConfigured = false

    /// 首次播放前调用一次即可。
    static func activate() {
        lock.lock()
        let needsSetup = !isConfigured
        isConfigured = true
        lock.unlock()

        let session = AVAudioSession.sharedInstance()
        do {
            if needsSetup {
                // .playback 让静音开关不影响播放，符合看监控的预期。
                try session.setCategory(.playback, mode: .moviePlayback)
            }
            try session.setActive(true)
        } catch {
            // 拿不到音频会话不该影响看画面，静默降级。
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // 同上，失败无需打扰用户。
        }
    }
}
#else
nonisolated enum AudioSessionSupport {
    static func activate() {}
    static func deactivate() {}
}
#endif
