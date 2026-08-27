//
//  StreamHistoryStore.swift
//  RTSPClient
//
//  播放历史：UserDefaults 存 JSON，密码走钥匙串。
//  收藏的条目不参与条数上限淘汰。
//

import Foundation
import Observation

@Observable
final class StreamHistoryStore {
    /// 非收藏记录的保留上限。
    static let limit = 30
    private static let storageKey = "stream.history.v1"

    private(set) var entries: [StreamHistoryEntry] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// 收藏优先，其余按最近播放排序。
    var sorted: [StreamHistoryEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.lastPlayed > rhs.lastPlayed
        }
    }

    var favorites: [StreamHistoryEntry] { sorted.filter(\.isFavorite) }

    func entry(for identity: String) -> StreamHistoryEntry? {
        entries.first { $0.id == identity }
    }

    /// 开始播放时记一笔；已存在就更新时间和次数。
    func recordPlayback(url: RTSPURL) {
        let identity = url.identity
        if let index = entries.firstIndex(where: { $0.id == identity }) {
            entries[index].lastPlayed = Date()
            entries[index].playCount += 1
            entries[index].address = url.displayString
            if let user = url.username, !user.isEmpty { entries[index].username = user }
        } else {
            entries.append(StreamHistoryEntry(id: identity,
                                              address: url.displayString,
                                              username: url.username,
                                              lastPlayed: Date()))
        }
        if let user = url.username, let password = url.password, !password.isEmpty {
            KeychainStore.savePassword(password, identity: identity, username: user)
        }
        prune()
        persist()
    }

    /// 播放成功后补上探测到的规格。
    func updateMediaInfo(identity: String, codec: String?, width: Int, height: Int) {
        guard let index = entries.firstIndex(where: { $0.id == identity }) else { return }
        if let codec { entries[index].codec = codec }
        if width > 0, height > 0 {
            entries[index].width = width
            entries[index].height = height
        }
        persist()
    }

    func toggleFavorite(_ entry: StreamHistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isFavorite.toggle()
        persist()
    }

    func rename(_ entry: StreamHistoryEntry, to title: String) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let clean = title.trimmed
        entries[index].title = clean.isEmpty ? nil : clean
        persist()
    }

    func remove(_ entry: StreamHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        if let user = entry.username {
            KeychainStore.deletePassword(identity: entry.id, username: user)
        }
        persist()
    }

    func removeAll() {
        for entry in entries where entry.username != nil {
            KeychainStore.deletePassword(identity: entry.id, username: entry.username!)
        }
        entries.removeAll()
        persist()
    }

    /// 回填输入框时把保存过的凭据带上，省得每次重输。
    func resolvedAddress(for entry: StreamHistoryEntry) -> String {
        guard let user = entry.username, !user.isEmpty,
              let url = RTSPURL(string: entry.address) else { return entry.address }
        let password = KeychainStore.password(identity: entry.id, username: user) ?? ""
        let credentials = password.isEmpty
            ? user.rtspCredentialEncoded
            : "\(user.rtspCredentialEncoded):\(password.rtspCredentialEncoded)"
        let host = url.host.contains(":") ? "[\(url.host)]" : url.host
        let portText = url.port == url.schemeDefaultPort ? "" : ":\(url.port)"
        return "\(url.scheme)://\(credentials)@\(host)\(portText)\(url.pathAndQuery)"
    }

    // MARK: - 持久化

    private func prune() {
        let regular = entries.filter { !$0.isFavorite }
            .sorted { $0.lastPlayed > $1.lastPlayed }
        guard regular.count > Self.limit else { return }
        let stale = Set(regular.dropFirst(Self.limit).map(\.id))
        for entry in entries where stale.contains(entry.id) {
            if let user = entry.username {
                KeychainStore.deletePassword(identity: entry.id, username: user)
            }
        }
        entries.removeAll { stale.contains($0.id) }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            entries = []
            return
        }
        entries = (try? JSONDecoder().decode([StreamHistoryEntry].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

nonisolated extension String {
    /// userinfo 里的 @ : / 等字符必须转义，否则地址会被切错。
    var rtspCredentialEncoded: String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
