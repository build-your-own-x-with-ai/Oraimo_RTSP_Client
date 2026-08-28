//
//  AddressBar.swift
//  RTSPClient
//
//  地址输入 + 历史快速选择 + 播放控制。
//

import SwiftUI

struct AddressBar: View {
    @Binding var address: String
    let history: StreamHistoryStore
    let player: RTSPPlayer
    let onPlay: () -> Void
    let onSelectHistory: (StreamHistoryEntry) -> Void
    let onShowHistory: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            addressField
            historyMenu
            playButton
            if player.state.isActive {
                Button { player.stop() } label: {
                    Image(systemName: "stop.fill")
                        .rtspIconHitTarget()
                }
                .buttonStyle(.plain)
                .help("停止")
            }
        }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            TextField("rtsp://…", text: $address)
                .textFieldStyle(.plain)
                .rtspAddressFieldStyle()
                .focused($isFocused)
                .onSubmit(onPlay)
            if !address.isEmpty {
                Button {
                    address = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        // 在胶囊里面，不跟 Menu 抢手势，横向可以窄一点，
                        // 省下的宽度留给地址本身。
                        .rtspIconHitTarget(width: 30)
                }
                .buttonStyle(.plain)
                .help("清空")
            }
        }
        // 图标不要贴着胶囊边缘。高度直接给足，不用 .vertical padding ——
        // 那样一来清空按钮在与不在会差出 14pt，输入时整行会跳一下。
        .padding(.horizontal, 10)
        .frame(minHeight: RTSPMetrics.controlSide)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private var historyMenu: some View {
        Menu {
            if history.entries.isEmpty {
                Text("暂无记录")
            } else {
                // 菜单里只放最近几条，完整列表另开页面。
                ForEach(history.sorted.prefix(8)) { entry in
                    Button {
                        onSelectHistory(entry)
                    } label: {
                        Label(entry.displayName,
                              systemImage: entry.isFavorite ? "star.fill" : "clock")
                    }
                }
                Divider()
                Button("全部记录…", systemImage: "list.bullet", action: onShowHistory)
            }
            Divider()
            // 实测过的设备各自的出厂地址。客户端不按型号分支，这里纯粹是
            // 省得手敲 —— 档案和特征在 RTSPClient/Devices/。
            ForEach(DeviceProfile.all) { device in
                Button {
                    address = device.address
                } label: {
                    Label(device.name, systemImage: "video")
                }
                .help(device.summary)
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .rtspIconHitTarget()
        }
        .menuIndicator(.hidden)
        .help("播放记录")
    }

    private var playButton: some View {
        Button {
            switch player.state {
            case .playing, .paused: player.togglePause()
            default:                onPlay()
            }
        } label: {
            Image(systemName: buttonIcon)
                .rtspIconHitTarget()
        }
        // 播放是主操作，给它比图标更大的落点，别让手指点空。
        .buttonStyle(.plain)
        // 回车已由输入框的 onSubmit 处理，这里不再抢快捷键，
        // 否则焦点在输入框时会触发两次播放。
        .disabled(address.trimmed.isEmpty)
        .help(buttonHelp)
    }

    private var buttonIcon: String {
        switch player.state {
        case .playing: return "pause.fill"
        case .paused:  return "play.fill"
        default:       return "play.fill"
        }
    }

    private var buttonHelp: String {
        switch player.state {
        case .playing: return "暂停"
        case .paused:  return "继续"
        default:       return "播放"
        }
    }
}
