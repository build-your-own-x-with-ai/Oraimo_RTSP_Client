//
//  DeviceOraimo.swift
//  RTSPClient
//
//  Oraimo 摄像机。出处：Captures/Oraimo/Oraimo.pcap（VLC 抓的）。
//

nonisolated extension DeviceProfile {
    /// Oraimo 摄像机，自研服务器。
    ///
    /// 这台是把「不显示画面」那个 bug 挖出来的设备。两处怪癖当时都踩到了：
    /// SETUP 应答不给 `server_port`/`source`（所以收包的 UDP socket 不能
    /// connect，只能收裸报文），FU-A 分片的载荷里还自带 Annex-B 起始码。
    static let oraimo = DeviceProfile(
        id: "Oraimo",
        name: "Oraimo 摄像机",
        address: "rtsp://192.168.0.1/livestream/1/",
        summary: "自研 RTSP 服务器，H.264 Baseline 3.0 + PCMA 音频轨",
        traits: [
            "不发 Content-Base，基址就是请求 URL",
            "media control 是两段相对路径 video/track0",
            "SETUP 应答不带 server_port 和 source",
            "Session 带 timeout",
            "H.264 Baseline 3.0，无 B 帧（抓包 91 帧：I×4 + P×87）",
            "SDP 的 o= 行写成 IPV4（规范是 IP4）",
            "音频 PCMA/16000 单声道，本 App 不播",
            "包到达抖动去趋势后跨度 93.8ms，最大包间隔 127.4ms",
        ])
}
