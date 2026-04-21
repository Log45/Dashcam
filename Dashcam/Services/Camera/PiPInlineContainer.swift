import SwiftUI
import UIKit

/// Hosts `PictureInPictureBridge.sampleBufferDisplayLayer` in the view hierarchy (required for PiP).
struct PiPInlineContainer: UIViewRepresentable {
    @ObservedObject var bridge: PictureInPictureBridge

    func makeUIView(context: Context) -> PiPHostUIView {
        let view = PiPHostUIView()
        view.attach(bridge: bridge)
        return view
    }

    func updateUIView(_ uiView: PiPHostUIView, context: Context) {
        uiView.attach(bridge: bridge)
        uiView.notifyInlineHostChanged()
    }
}

final class PiPHostUIView: UIView {
    private weak var boundBridge: PictureInPictureBridge?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = true
    }

    func attach(bridge: PictureInPictureBridge) {
        if boundBridge !== bridge {
            boundBridge?.sampleBufferDisplayLayer.removeFromSuperlayer()
            boundBridge = bridge
            layer.addSublayer(bridge.sampleBufferDisplayLayer)
        }
        notifyInlineHostChanged()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        notifyInlineHostChanged()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        notifyInlineHostChanged()
    }

    /// Main-thread layout / window hooks so PiP prepares only when the display layer is actually on-screen.
    func notifyInlineHostChanged() {
        boundBridge?.inlineHostUpdated(bounds: bounds, isInWindow: window != nil)
    }
}
