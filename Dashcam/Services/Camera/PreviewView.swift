import AVFoundation
import SwiftUI
import UIKit

/// Hosts an `AVCaptureVideoPreviewLayer` sized to bounds.
final class PreviewHostView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool = false

    final class Coordinator {
        /// Session we last attached; used to avoid redundant nil swaps on SwiftUI relayout / rotation.
        weak var boundSession: AVCaptureSession?
        var lastMirrored: Bool?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        let layer = view.previewLayer
        layer.session = session
        layer.videoGravity = .resizeAspectFill
        context.coordinator.boundSession = session
        context.coordinator.lastMirrored = nil
        applyMirroringIfNeeded(to: layer, mirrored: mirrored, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        let layer = uiView.previewLayer
        let coordinator = context.coordinator

        if coordinator.boundSession !== session {
            layer.session = nil
            layer.session = session
            coordinator.boundSession = session
            coordinator.lastMirrored = nil
        }

        applyMirroringIfNeeded(to: layer, mirrored: mirrored, coordinator: coordinator)
    }

    private func applyMirroringIfNeeded(
        to layer: AVCaptureVideoPreviewLayer,
        mirrored: Bool,
        coordinator: Coordinator
    ) {
        guard coordinator.lastMirrored != mirrored else { return }
        coordinator.lastMirrored = mirrored

        guard let connection = layer.connection else { return }
        guard connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}
