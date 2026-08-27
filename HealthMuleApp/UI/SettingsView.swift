import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var isShowingResetConfirmation = false
    @State private var isShowingDisconnectConfirmation = false

    var body: some View {
        Form {
            overviewSection
            metricsSection
            diagnosticsSection
            googleSection
            resetSection
            OperationBanner(state: model.operationState)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .navigationTitle("Settings")
        .formStyle(.grouped)
        .listSectionSpacing(20)
        .contentMargins(.top, 12, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(HealthMuleStyle.canvas)
        .accessibilityIdentifier("settings-screen")
        .confirmationDialog(
            "Disconnect Google?",
            isPresented: $isShowingDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect Google", role: .destructive) {
                Task {
                    await model.disconnectGoogle()
                }
            }
        } message: {
            Text("Existing files in Google Drive will not be deleted.")
        }
        .confirmationDialog(
            "Reset local sync state?",
            isPresented: $isShowingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Local State", role: .destructive) {
                Task {
                    await model.resetLocalState()
                }
            }
        } message: {
            Text(
                "Local anchors, staged records, and retry state will be cleared. Saved day boundaries, stable Drive IDs, and existing files will be kept."
            )
        }
    }

    private var overviewSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                StatusGlyph(
                    systemImage: "slider.horizontal.3",
                    tone: .accent
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Export preferences")
                        .font(HealthMuleStyle.Text.cardTitle)
                    Text(
                        "\(model.enabledMetrics.count) of \(HealthMetric.allCases.count) health data types included"
                    )
                    .font(HealthMuleStyle.Text.cardBody)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(HealthMuleStyle.surface)
    }

    private var metricsSection: some View {
        Section {
            ForEach(HealthMetric.allCases) { metric in
                Toggle(isOn: Binding(
                    get: { model.enabledMetrics.contains(metric) },
                    set: { model.setMetric(metric, enabled: $0) }
                )) {
                    Label(metric.title, systemImage: metric.settingsSystemImage)
                }
                .disabled(model.operationState.isWorking)
            }
        } header: {
            Text("Included metrics")
        } footer: {
            Text(
                "Disabled metrics are not queried and are cleared from managed daily records. Enabling a new type may require reviewing read-only Apple Health access."
            )
        }
        .listRowBackground(HealthMuleStyle.surface)
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            Button {
                Task {
                    await model.prepareDiagnosticsExport()
                }
            } label: {
                Label("Prepare Diagnostics", systemImage: "doc.badge.gearshape")
            }
            .disabled(model.operationState.isWorking)

            if let diagnosticsURL = model.diagnosticsURL {
                ShareLink(item: diagnosticsURL) {
                    Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text(
                "The export contains lifecycle events, counts, durations, and error codes. It never contains health values, file contents, or OAuth tokens."
            )
        }
        .listRowBackground(HealthMuleStyle.surface)
    }

    @ViewBuilder
    private var googleSection: some View {
        if model.googleConnection.canDisconnect {
            Section {
                Button(role: .destructive) {
                    isShowingDisconnectConfirmation = true
                } label: {
                    Label("Disconnect Google", systemImage: "link")
                }
                .disabled(model.operationState.isWorking)
            } footer: {
                Text("Disconnecting revokes the app’s Google authorization.")
            }
            .listRowBackground(HealthMuleStyle.surface)
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                isShowingResetConfirmation = true
            } label: {
                Label("Reset Local Sync State", systemImage: "arrow.counterclockwise")
            }
            .disabled(model.operationState.isWorking)
        } footer: {
            Text(
                "Deleting Drive data is intentionally a separate action and is not available in this version."
            )
        }
        .listRowBackground(HealthMuleStyle.surface)
    }
}

private extension HealthMetric {
    var settingsSystemImage: String {
        switch self {
        case .bodyMass:
            "scalemass"
        case .stepCount:
            "figure.walk"
        case .activeEnergy:
            "flame"
        case .restingEnergy:
            "bolt.heart"
        case .restingHeartRate:
            "heart"
        case .hrvSDNN:
            "waveform.path.ecg"
        case .vo2Max:
            "lungs"
        case .sleep:
            "bed.double"
        case .workouts:
            "figure.run"
        }
    }
}
