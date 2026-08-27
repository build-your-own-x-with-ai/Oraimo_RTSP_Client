//
//  PlayerSurface.swift
//  RTSPClient
//
//  视频显示区：画面层 + 状态提示 + 统计浮层。
//

import SwiftUI

struct PlayerSurface: View {
    let player: RTSPPlayer
    @Binding var showsStats: Bool

    var body: some View {
        ZStack {
            Color.black
            VideoLayerView(displayLayer: player.renderer.displayLayer)
                .opacity(hasPicture ? 1 : 0)

            if !hasPicture {
                placeholder
            }

            if showsStats, let statistics = player.statistics {
                StatsOverlay(statistics: statistics, formatText: player.formatText)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
                    .allowsHitTesting(false)
            }

            if player.state == .paused {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) { statsToggle }
        #if os(macOS)
        .onTapGesture(count: 2) { player.togglePause() }
        #endif
    }

    /// 只有真正出过画面才显示视频层，否则黑屏上盖提示。
    private var hasPicture: Bool {
        player.state == .playing || player.state == .paused
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            if player.state.showsSpinner {
                ProgressView()
                    .controlSize(.large)
                    #if os(macOS)
                    .colorScheme(.dark)
                    #endif
            } else if case .failed = player.state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "video.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Text(player.statusText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if case .failed = player.state, player.currentAddress != nil {
                Button("重试", systemImage: "arrow.clockwise") { player.reload() }
                    .buttonStyle(.bordered)
                    #if os(macOS)
                    .colorScheme(.dark)
                    #endif
            }
        }
    }

    private var statsToggle: some View {
        Button {
            showsStats.toggle()
        } label: {
            Image(systemName: showsStats ? "chart.bar.fill" : "chart.bar")
                .padding(8)
                .background(.black.opacity(0.45), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(10)
        .opacity(player.state.isActive ? 1 : 0)
        .help("统计信息")
    }
}
