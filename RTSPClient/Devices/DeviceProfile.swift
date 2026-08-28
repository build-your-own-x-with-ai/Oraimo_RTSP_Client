//
//  DeviceProfile.swift
//  RTSPClient
//
//  设备档案：地址预设 + 抓包里量到的握手特征。
//

/// 一台实测过的设备。
///
/// 这不是「支持列表」，客户端不按型号分支 —— 收到什么头就按什么处理，
/// 认不出的设备一样能播。档案存在只为两件事：地址栏能一键填上，
/// 以及把抓包里量到的特征写进代码，改握手时知道会碰到谁。
///
/// `traits` 里每一条都能在 `Captures/<id>/` 的抓包里找到出处。不写推测。
nonisolated struct DeviceProfile: Identifiable, Sendable, Equatable {
    /// 稳定标识。抓包目录名和测试场景名用它，不显示给用户。
    let id: String
    /// 菜单里显示的名字。
    let name: String
    /// 地址栏预设。
    let address: String
    /// 一句话：这是什么设备。
    let summary: String
    /// 抓包里量到的握手特征。
    let traits: [String]
}

nonisolated extension DeviceProfile {
    /// 全部档案，按菜单顺序。
    static let all: [DeviceProfile] = [.oraimo, .dashcam]

    /// 默认档案。地址栏初始值和「恢复默认地址」都取它。
    /// 写成显式引用而不是 `all[0]`，改顺序不会连带改默认值。
    static let `default` = oraimo
}
