// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI

struct SpectrumAnalyzerSettingsSection: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        let settings = container?.spectrumAnalyzerSettings

        Section {
            Toggle(isOn: Binding(
                get: { settings?.isEnabled ?? true },
                set: { newValue in
                    settings?.isEnabled = newValue
                    applyConfigChange()
                }
            )) {
                Label {
                    Text("Enabled")
                } icon: {
                    SettingsIcon(systemImage: "waveform.path.ecg", color: .indigo)
                }
            }

            if settings?.isEnabled == true {
                Picker(
                    selection: Binding(
                        get: { settings?.visualizerType ?? .lines },
                        set: { settings?.visualizerType = $0 }
                    )
                ) {
                    ForEach(SpectrumVisualizerType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                } label: {
                    Label {
                        Text("Type")
                    } icon: {
                        SettingsIcon(systemImage: "chart.xyaxis.line", color: .indigo)
                    }
                }
                .pickerStyle(.menu)

                Picker(
                    selection: Binding(
                        get: { settings?.binDetail ?? .medium },
                        set: { newValue in
                            settings?.binDetail = newValue
                            applyConfigChange()
                        }
                    )
                ) {
                    ForEach(SpectrumBinDetail.allCases) { detail in
                        Text(detail.label).tag(detail)
                    }
                } label: {
                    Label {
                        Text("Detail")
                    } icon: {
                        SettingsIcon(systemImage: "chart.bar", color: .indigo)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        HStack {
                            Text("Sensitivity")
                            Spacer()
                            Text(sensitivityLabel(settings?.sensitivity ?? -60))
                                .foregroundStyle(.secondary)
                                .font(.body.weight(.medium))
                                .monospacedDigit()
                        }
                    } icon: {
                        SettingsIcon(systemImage: "slider.horizontal.below.rectangle", color: .indigo)
                    }

                    Slider(
                        value: Binding(
                            get: { -(settings?.sensitivity ?? SpectrumAnalyzerSettings.defaultSensitivity) },
                            set: { newValue in
                                settings?.sensitivity = -newValue
                                applyConfigChange()
                            }
                        ),
                        in: -SpectrumAnalyzerSettings.maxSensitivity ... -SpectrumAnalyzerSettings.minSensitivity,
                        step: 5
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        HStack {
                            Text("Responsiveness")
                            Spacer()
                            Text(responsivenessLabel(settings?.responsiveness ?? 0.8))
                                .foregroundStyle(.secondary)
                                .font(.body.weight(.medium))
                        }
                    } icon: {
                        SettingsIcon(systemImage: "gauge.with.needle", color: .indigo)
                    }

                    Slider(
                        value: Binding(
                            get: { settings?.responsiveness ?? SpectrumAnalyzerSettings.defaultResponsiveness },
                            set: { newValue in
                                settings?.responsiveness = newValue
                                applyConfigChange()
                            }
                        ),
                        in: SpectrumAnalyzerSettings.minResponsiveness...SpectrumAnalyzerSettings.maxResponsiveness,
                        step: 0.1
                    )
                }

                if settings?.visualizerType != .spectrogram {
                    Toggle(isOn: Binding(
                        get: { settings?.showStereo ?? true },
                        set: { newValue in
                            settings?.showStereo = newValue
                            applyConfigChange()
                        }
                    )) {
                        Label {
                            Text("Show stereo channels")
                        } icon: {
                            SettingsIcon(systemImage: "speaker.wave.2", color: .indigo)
                        }
                    }
                }

                if settings?.visualizerType == .spectrogram {
                    Toggle(isOn: Binding(
                        get: { settings?.useReassignment ?? false },
                        set: { newValue in
                            settings?.useReassignment = newValue
                            applyConfigChange()
                        }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enhanced analysis")
                                Text("Works best with High detail and Reactive responsiveness")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            SettingsIcon(systemImage: "waveform.and.magnifyingglass", color: .indigo)
                        }
                    }
                }
            }
        } header: {
            Text("Spectrum Analyser")
        } footer: {
            Text("Displays a real-time frequency curve behind the full-screen player. Sensitivity sets the quiet floor; Responsiveness controls how quickly the curve reacts to changes.")
        }
    }

    // MARK: - Helpers

    private func applyConfigChange() {
        guard let settings = container?.spectrumAnalyzerSettings,
              let analyzer = container?.spectrumAnalyzer else { return }
        analyzer.updateConfig(settings.config)
    }

    private func sensitivityLabel(_ value: Double) -> String {
        "\(Int(value)) dB"
    }

    private func responsivenessLabel(_ value: Double) -> String {
        switch value {
        case ..<0.45: "Smooth"
        case 0.45..<0.75: "Balanced"
        default: "Reactive"
        }
    }
}
#endif
