//
//  HistoryListView.swift
//  RTSPClient
//
//  播放过的地址列表：收藏、重命名、删除。
//

import SwiftUI

struct HistoryListView: View {
    let history: StreamHistoryStore
    let onSelect: (StreamHistoryEntry) -> Void

    @State private var renaming: StreamHistoryEntry?
    @State private var draftTitle = ""
    @State private var confirmClear = false

    var body: some View {
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView("暂无记录",
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text("播放过的地址会出现在这里"))
            } else {
                list
            }
        }
        .navigationTitle("播放记录")
        .toolbar {
            if !history.entries.isEmpty {
                Button("清空", systemImage: "trash") { confirmClear = true }
            }
        }
        .confirmationDialog("清空全部播放记录？", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("清空", role: .destructive) { history.removeAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("同时会删除保存的密码，此操作不可撤销。")
        }
        .alert("重命名", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } })) {
            TextField("备注名", text: $draftTitle)
            Button("保存") {
                if let entry = renaming { history.rename(entry, to: draftTitle) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        } message: {
            Text("留空则显示地址本身")
        }
    }

    private var list: some View {
        List {
            ForEach(history.sorted) { entry in
                Button {
                    onSelect(entry)
                } label: {
                    row(entry)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        history.remove(entry)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button(entry.isFavorite ? "取消收藏" : "收藏",
                           systemImage: entry.isFavorite ? "star.slash" : "star") {
                        history.toggleFavorite(entry)
                    }
                    .tint(.yellow)
                }
                .contextMenu {
                    Button(entry.isFavorite ? "取消收藏" : "收藏",
                           systemImage: entry.isFavorite ? "star.slash" : "star") {
                        history.toggleFavorite(entry)
                    }
                    Button("重命名", systemImage: "pencil") {
                        draftTitle = entry.title ?? ""
                        renaming = entry
                    }
                    Button("复制地址", systemImage: "doc.on.doc") {
                        copyToClipboard(entry.address)
                    }
                    Divider()
                    Button("删除", systemImage: "trash", role: .destructive) {
                        history.remove(entry)
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
    }

    private func row(_ entry: StreamHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isFavorite ? "star.fill" : "video")
                .foregroundStyle(entry.isFavorite ? .yellow : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 有备注名时把地址也带出来，否则不知道点的是哪一路。
                if entry.title != nil {
                    Text(entry.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(relativeTimeText(entry.lastPlayed))
                    if !entry.detailText.isEmpty {
                        Text(entry.detailText)
                    }
                    if entry.username != nil {
                        Image(systemName: "lock.fill")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
