import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DashcamViewModel()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    if let session = viewModel.camera.captureSession {
                        PreviewView(
                            session: session,
                            mirrored: viewModel.camera.previewMirrored,
                            onPreviewLayerBound: { viewModel.camera.updatePreviewVideoLayer($0) }
                        )
                        .id(ObjectIdentifier(session))
                        .ignoresSafeArea()
                    } else {
                        ContentUnavailableView(
                            "No camera",
                            systemImage: "video.slash",
                            description: Text(viewModel.camera.lastError ?? "Configure access in Settings.")
                        )
                    }
                }

                VStack(spacing: 12) {
                    if viewModel.isRecording {
                        Label("Buffering", systemImage: "dot.radiowaves.left.and.right")
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    if viewModel.isExporting {
                        ProgressView(value: Double(viewModel.exportProgress), total: 1.0) {
                            Text("Exporting clip…")
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }

                    HStack(spacing: 16) {
                        Button {
                            viewModel.toggleRecording()
                        } label: {
                            Text(viewModel.isRecording ? "Stop" : "Record")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(viewModel.isRecording ? .red : .green)
                        .disabled(viewModel.camera.captureSession == nil || viewModel.isExporting)

                        Button("Save") {
                            viewModel.saveTapped()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.isRecording || viewModel.isExporting)
                    }
                    .padding(.horizontal)

                    if viewModel.camera.captureSession != nil {
                        HStack(alignment: .center, spacing: 12) {
                            PiPInlineContainer(bridge: viewModel.pipBridge)
                                .frame(width: 132, height: 74)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                                )

                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    viewModel.pipBridge.startPictureInPictureFromMain()
                                } label: {
                                    Label("Float over Maps", systemImage: "pip.enter")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!viewModel.pipBridge.isPictureInPicturePossible)

                                Text(
                                    viewModel.pipBridge.isPictureInPictureSupported
                                        ? "Uses Picture in Picture so the camera can stay active while you use other apps. If PiP is not available, return here first."
                                        : "Picture in Picture is not supported on this device."
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal)
                    }

                    #if DEBUG
                    Button("Simulate collision (debug)") {
                        viewModel.debugSimulateCollision()
                    }
                    .font(.footnote)
                    .disabled(!viewModel.isRecording || viewModel.isExporting)
                    #endif
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Dashcam")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView(viewModel: viewModel)
                }
            }
            .alert(
                viewModel.bannerIsError ? "Something went wrong" : "Dashcam",
                isPresented: Binding(
                    get: { viewModel.bannerMessage != nil },
                    set: { newValue in
                        if !newValue { viewModel.dismissBanner() }
                    }
                ),
                actions: {
                    Button("OK", role: .cancel) {
                        viewModel.dismissBanner()
                    }
                },
                message: {
                    Text(viewModel.bannerMessage ?? "")
                }
            )
            .onAppear {
                viewModel.onAppear()
            }
            .onChange(of: viewModel.settings.cameraMode) { _, _ in
                guard !viewModel.isRecording else { return }
                viewModel.applyCameraConfiguration(startSession: true)
            }
        }
    }
}

#Preview {
    ContentView()
}
