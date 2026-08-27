//
//  VideoLayerView.swift
//  RTSPClient
//
//  把 AVSampleBufferDisplayLayer 桥到 SwiftUI。
//

import SwiftUI
import AVFoundation

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// 承载显示层的原生视图，负责让 layer 跟随尺寸变化。
final class VideoHostView: PlatformView {
    let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = .black
        layer?.addSublayer(displayLayer)
        #else
        backgroundColor = .black
        layer.addSublayer(displayLayer)
        #endif
        displayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 storyboard") }

    #if os(macOS)
    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
    #endif
}

#if os(macOS)
typealias PlatformView = NSView
#else
typealias PlatformView = UIView
#endif

struct VideoLayerView: PlatformViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    #if os(macOS)
    func makeNSView(context: Context) -> VideoHostView {
        VideoHostView(displayLayer: displayLayer)
    }
    func updateNSView(_ view: VideoHostView, context: Context) {}
    #else
    func makeUIView(context: Context) -> VideoHostView {
        VideoHostView(displayLayer: displayLayer)
    }
    func updateUIView(_ view: VideoHostView, context: Context) {}
    #endif
}
