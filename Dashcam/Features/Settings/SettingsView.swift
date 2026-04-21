import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: DashcamViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Picture in Picture") {
                Toggle("Auto-start PiP when recording", isOn: $viewModel.settings.autoStartPiPWhenRecording)
                    .disabled(viewModel.isRecording)

                Text(
                    "When on, Dashcam starts Float over Maps as soon as iOS says PiP is ready after you tap Record—needed for continuous capture while you use other apps."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Camera") {
                Picker("Camera", selection: $viewModel.settings.cameraMode) {
                    ForEach(CameraMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(viewModel.isRecording)

                if viewModel.settings.cameraMode == .both, !viewModel.camera.multiCamSupported {
                    Text("Both cameras are not supported on this device. Preview and recording use the back camera.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Rolling buffer") {
                Stepper(value: $viewModel.settings.bufferSeconds, in: 15...180, step: 15) {
                    Text("Keep last \(Int(viewModel.settings.bufferSecondsClamped)) seconds")
                }
                .disabled(viewModel.isRecording)

                Text("Older segments are deleted automatically. Save or a collision exports the last window to Documents/Events.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Collision detection") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Acceleration threshold: \(viewModel.settings.collisionThresholdClamped, format: .number.precision(.fractionLength(1))) g")
                    Slider(
                        value: $viewModel.settings.collisionThresholdG,
                        in: 1.2...6,
                        step: 0.1
                    )
                    .disabled(viewModel.isRecording)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Cooldown: \(Int(viewModel.settings.collisionCooldownClamped)) s")
                    Slider(
                        value: $viewModel.settings.collisionCooldownSeconds,
                        in: 3...30,
                        step: 1
                    )
                    .disabled(viewModel.isRecording)
                }

                Text("Uses Core Motion user acceleration (heuristic, not crash certified). Works best on a real device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Debug") {
                Toggle("Log acceleration to file", isOn: $viewModel.settings.debugAccelerationLogging)

                Text(
                    "While recording, appends about 50 samples per second with ISO timestamps under On My iPhone → Dashcam → Documents → DebugLogs (tab-separated: time, ax, ay, az, magnitude_g, threshold_g). A new file starts each time logging begins."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if !viewModel.isRecording {
                        viewModel.applyCameraConfiguration(startSession: true)
                    }
                    dismiss()
                }
            }
        }
    }
}
