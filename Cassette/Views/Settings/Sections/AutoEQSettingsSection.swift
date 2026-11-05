// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct AutoEQSettingsSection: View {
    @Environment(\.appContainer) private var container
    @State private var showImporter = false
    @State private var importError: String?
    @State private var profiles: [AutoEQProfile] = []

    private var settings: AutoEQSettings? { container?.autoEQSettings }
    private var outputDeviceState: OutputDeviceState? { container?.outputDeviceState }

    var body: some View {
        Section {
            if profiles.isEmpty {
                HStack {
                    Label {
                        Text("No profiles imported")
                            .foregroundStyle(.secondary)
                    } icon: {
                        SettingsIcon(systemImage: "headphones", color: .purple)
                    }
                    Spacer()
                    importButton
                }
            } else {
                Toggle(isOn: Binding(
                    get: { settings?.isEnabled ?? false },
                    set: { newValue in
                        settings?.isEnabled = newValue
                        applyChange()
                    }
                )) {
                    Label {
                        Text("Enabled")
                    } icon: {
                        SettingsIcon(systemImage: "headphones", color: .purple)
                    }
                }

                if settings?.isEnabled == true {
                    ForEach(profiles) { profile in
                        profileRow(profile)
                    }

                    importButton

                    deviceSpecificSection
                }
            }

            if let error = importError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }
        } header: {
            Text("AutoEQ")
        } footer: {
            Text("Find your headphones on [autoeq.app](https://autoeq.app), select \"Custom Parametric Eq\" as the equalizer app, and tap the download button. Then import the ParametricEQ.txt file here.")
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result: result)
        }
        .task { await refreshProfiles() }
    }

    // MARK: - Subviews

    private func profileRow(_ profile: AutoEQProfile) -> some View {
        let isSelected = settings?.selectedProfileID == profile.id
        return HStack {
            Label {
                Text(profile.name)
            } icon: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.purple : Color.secondary)
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
            }
            Spacer()
            Button(role: .destructive) {
                deleteProfile(profile)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            settings?.selectedProfileID = profile.id
            applyChange()
        }
    }

    private var importButton: some View {
        Button {
            importError = nil
            showImporter = true
        } label: {
            Label("Import Profile…", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.purple)
    }

    // MARK: - Actions

    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // Strip the standard AutoEQ suffix from the filename to get the headphone name.
            let name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: " ParametricEQ", with: "", options: .caseInsensitive)
            Task {
                do {
                    guard let service = container?.autoEQService else { return }
                    let profile = try await service.importProfile(from: url, name: name)
                    await refreshProfiles()
                    // Auto-select the newly imported profile.
                    settings?.selectedProfileID = profile.id
                    applyChange()
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
    }

    private func deleteProfile(_ profile: AutoEQProfile) {
        Task {
            do {
                try await container?.autoEQService.deleteProfile(id: profile.id)
                if settings?.selectedProfileID == profile.id {
                    settings?.selectedProfileID = nil
                    applyChange()
                }
                await refreshProfiles()
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var deviceSpecificSection: some View {
        let devices = outputDeviceState?.availableOutputDevices ?? []
        Toggle(isOn: Binding(
            get: { settings?.deviceSpecificEnabled ?? false },
            set: { newValue in
                settings?.deviceSpecificEnabled = newValue
                applyChange()
            }
        )) {
            Label("Only for this device", systemImage: "hifispeaker")
        }

        if settings?.deviceSpecificEnabled == true {
            Picker("Output device", selection: Binding(
                get: { settings?.targetDeviceUID ?? "" },
                set: { uid in
                    settings?.targetDeviceUID = uid.isEmpty ? nil : uid
                    settings?.targetDeviceName = devices.first(where: { $0.uid == uid })?.name
                    applyChange()
                }
            )) {
                Text("Select a device…").tag("")
                ForEach(devices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
        }
    }

    private func applyChange() {
        let uid = outputDeviceState?.currentDeviceUID
        Task { await container?.playerService.autoEQSettingsDidChange(currentDeviceUID: uid) }
    }

    private func refreshProfiles() async {
        profiles = await container?.autoEQService.profiles ?? []
    }
}
#endif
