//
//  StreamHistoryEntry.swift
//  RTSPClient
//
//  一条播放记录。密码不进这里，只留用户名做提示。
//

import Foundation

struct StreamHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    /// 去重键：归一化后的地址。
    var id: String
    /// 不含凭据的完整地址，直接可回填到输入框。
    var address: String
    var username: String?
    /// 用户起的备注名，空则显示地址。
    var title: String?
    var isFavorite = false
    var lastPlayed: Date
    var playCount = 1
    /// 上次成功播放时探测到的规格，列表里直接给用户看。
    var codec: String?
    var width: Int = 0
    var height: Int = 0

    var displayName: String {
        if let title, !title.trimmed.isEmpty { return title }
        return address
    }

    var resolutionText: String? {
        guard width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    /// 列表里的副标题：编码、分辨率、播放次数。
    var detailText: String {
        var parts: [String] = []
        if let codec { parts.append(codec) }
        if let resolutionText { parts.append(resolutionText) }
        if playCount > 1 { parts.append("播放 \(playCount) 次") }
        return parts.joined(separator: " · ")
    }
}
