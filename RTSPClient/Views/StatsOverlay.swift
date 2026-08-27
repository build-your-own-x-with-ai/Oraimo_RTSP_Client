//
//  StatsOverlay.swift
//  RTSPClient
//
//  码率 / 帧率 / 丢包的实时显示。
//

import SwiftUI

struct StatsOverlay: View {
    let statistics: RTSPSession.Statistics
    let formatText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let formatText {
                Text(formatText)
                    .font(.caption.weight(.medium))
            }
            row("码率", String(format: "%.0f kbps", statistics.bitrateKbps))
            row("帧率", String(format: "%.1f fps", statistics.fps))
            row("已收", byteText(statistics.bytesReceived))
            if statistics.droppedPackets > 0 {
                row("丢包", "\(statistics.droppedPackets)")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.white.opacity(0.7))
            Text(value)
        }
    }

    private func byteText(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}
