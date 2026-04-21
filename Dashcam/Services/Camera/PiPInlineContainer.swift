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
        bridge.sampleBufferDisplayLayer.frame = uiView.bounds
        bridge.preparePictureInPictureControllerIfNeeded()
        bridge.refreshPiPState()
    }
}

final class PiPHostUIView: UIView {
    private weak var boundBridge: PictureInPictureBridge?

    func attach(bridge: PictureInPictureBridge) {
        if boundBridge !== bridge {
            boundBridge?.sampleBufferDisplayLayer.removeFromSuperlayer()
            boundBridge = bridge
            layer.addSublayer(bridge.sampleBufferDisplayLayer)
        }
        bridge.sampleBufferDisplayLayer.frame = bounds
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        boundBridge?.sampleBufferDisplayLayer.frame = bounds
    }
}
