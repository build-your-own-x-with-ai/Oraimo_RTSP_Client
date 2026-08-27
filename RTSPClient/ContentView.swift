//
//  ContentView.swift
//  RTSPClient
//
//  主界面：地址栏 + 画面 + 播放记录。
//

import SwiftUI

struct ContentView: View {
    @State private var history = StreamHistoryStore()
    @State private var player: RTSPPlayer?
    @State private var address = RTSPPlayer.defaultAddress
    @State private var showsStats = false
    @State private var showsHistory = false

    var body: some View {
        // player 依赖 history，用 task 在首次出现时建好。
        Group {
            if let player {
                content(player: player)
            } else {
                Color.black
            }
        }
        .task {
            if player == nil { player = RTSPPlayer(history: history) }
        }
    }

    private func content(player: RTSPPlayer) -> some View {
        VStack(spacing: 10) {
            AddressBar(address: $address,
                       history: history,
                       player: player,
                       onPlay: { start(player: player) },
                       onSelectHistory: { entry in
                           address = entry.address
                           player.play(entry: entry)
                       },
                       onShowHistory: { showsHistory = true })

            PlayerSurface(player: player, showsStats: $showsStats)
                .frame(minHeight: 240)

            statusBar(player: player)
        }
        .padding(12)
        .rtspWindowMinSize(width: 480, height: 380)
        .sheet(isPresented: $showsHistory) {
            NavigationStack {
                HistoryListView(history: history) { entry in
                    address = entry.address
                    showsHistory = false
                    player.play(entry: entry)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showsHistory = false }
                    }
                }
            }
            .rtspWindowMinSize(width: 420, height: 420)
        }
        .sheet(isPresented: Binding(
            get: { player.needsCredentials },
            set: { if !$0 { player.needsCredentials = false } })) {
            CredentialsSheet(
                address: player.currentAddress ?? address,
                initialUsername: RTSPURL(string: address)?.username ?? "",
                onSubmit: { user, password in
                    player.retryWithCredentials(username: user, password: password)
                },
                onCancel: { player.needsCredentials = false })
        }
    }

    private func statusBar(player: RTSPPlayer) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor(player.state))
                .frame(width: 8, height: 8)
            Text(player.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let formatText = player.formatText {
                Text(formatText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusColor(_ state: RTSPPlayer.State) -> Color {
        switch state {
        case .playing:              return .green
        case .connecting, .buffering: return .orange
        case .paused:               return .yellow
        case .failed:               return .red
        case .idle:                 return .secondary
        }
    }

    private func start(player: RTSPPlayer) {
        let text = address.trimmed
        guard !text.isEmpty else { return }
        address = text
        player.play(address: text)
    }
}

#Preview {
    ContentView()
}
