//
//  DeviceDashcam.swift
//  RTSPClient
//
//  行车记录仪。出处：Captures/Dashcam/RTSP.pcapng（VLC 抓的）。
//

nonisolated extension DeviceProfile {
    /// 行车记录仪，LIVE555 服务器。
    ///
    /// 这台逼出了 Content-Base 的处理。它用 `/xxx.mov` 收 DESCRIBE，
    /// 应答里的基址却是另一条路径 `rtsp://192.168.1.254/00000000/`，
    /// 而且**基址不带端口**（请求 URL 是带 `:554` 的）。按请求 URL 去拼
    /// control 会发出 `/xxx.mov/track1`，SETUP 直接失败。
    ///
    /// 见 `RTSPURL.resolveControl(_:base:)`。
    static let dashcam = DeviceProfile(
        id: "Dashcam",
        name: "行车记录仪",
        address: "rtsp://192.168.1.254/xxx.mov",
        summary: "LIVE555 v2013.07.03，H.264 High 5.1，无音频轨",
        traits: [
            "发 Content-Base，路径和请求 URL 不同，且不带端口",
            "media control 是单段相对路径 track1",
            "SETUP 应答带齐 destination/source/client_port/server_port",
            "Session 不带 timeout（LIVE555 默认 60 秒）",
            "H.264 High 5.1，无 B 帧（抓包 86 帧：I×6 + P×80）",
            "只有视频轨，b=AS:2000",
            "包到达抖动跨度 23.9ms，比 Oraimo 稳得多",
        ])
}
