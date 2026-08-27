//
//  ViewHelpers.swift
//  RTSPClient
//
//  跨平台的小差异收在这里。
//

import SwiftUI

/// 控件尺寸。iOS 按 HIG 给 44pt 的最小触摸目标；macOS 有鼠标，收紧一些。
enum RTSPMetrics {
    #if os(macOS)
    static let controlSide: CGFloat = 24
    #else
    static let controlSide: CGFloat = 44
    #endif
}

extension View {
    /// 地址输入框：不要自动大写和纠错，否则地址会被改坏。
    func rtspAddressFieldStyle() -> some View {
        #if os(macOS)
        return autocorrectionDisabled()
        #else
        return autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
        #endif
    }

    /// 图标按钮的点击区域。
    ///
    /// 只放一个 Image 当 label 时，可点区域就只有字形那么大（约 17pt），
    /// 手指很容易点空；旁边又挨着 Menu，触摸会被它的长按识别器抢走，
    /// 于是日志里冒出 UIContextMenuInteraction 和手势超时。
    /// 撑到 44pt（HIG 的最小值）并给出明确的 contentShape 就能各点各的。
    ///
    /// `width` 用来给胶囊内部的小按钮放宽限制：它不挨着 Menu，不需要占满
    /// 44pt 宽，省下来的横向空间留给地址输入框。高度仍然是满的。
    func rtspIconHitTarget(width: CGFloat? = nil) -> some View {
        let side = RTSPMetrics.controlSide
        return frame(minWidth: min(width ?? side, side), minHeight: side)
            .contentShape(Rectangle())
    }

    /// 窗口的最小尺寸，只在 macOS 生效。
    ///
    /// iPhone 竖屏只有 390~440pt 宽，套上为桌面窗口准备的 minWidth 之后，
    /// 布局会按那个宽度排版再居中，两边各溢出一截 —— 地址栏最右的播放按钮
    /// 就这么被裁掉看不见了，左边的图标也跟着缺一块。
    func rtspWindowMinSize(width: CGFloat, height: CGFloat? = nil) -> some View {
        #if os(macOS)
        return frame(minWidth: width, minHeight: height)
        #else
        return self
        #endif
    }
}

extension RTSPPlayer.State {
    var showsSpinner: Bool {
        switch self {
        case .connecting, .buffering: return true
        default:                      return false
        }
    }
}

/// 相对时间展示，历史列表里用。
func relativeTimeText(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}
