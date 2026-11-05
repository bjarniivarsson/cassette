// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import CoreAudio
import Observation

/// Observable state for the system default audio output device.
/// Updated via Core Audio property listener whenever the user switches devices.
@Observable
@MainActor
final class OutputDeviceState {
    var currentDeviceName: String?
    var currentDeviceUID: String?
    var currentSampleRate: Double?
    var currentBitDepth: UInt32?
    var currentIsFloat: Bool = false
    var currentChannels: UInt32?

    /// Available output devices as (name, uid) pairs for the device picker.
    var availableOutputDevices: [(name: String, uid: String)] = []

    /// Called whenever the default output device changes (after state is refreshed).
    var onDeviceChange: (() -> Void)?

    private nonisolated(unsafe) var listenerAdded = false
    private nonisolated(unsafe) var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        refreshAvailableDevices()
        startListening()
    }

    deinit {
        guard listenerAdded, var block = listenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }

    // MARK: - Refresh

    func refresh() {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else {
            currentDeviceName = nil
            currentDeviceUID = nil
            currentSampleRate = nil
            currentBitDepth = nil
            currentIsFloat = false
            currentChannels = nil
            return
        }
        currentDeviceName = deviceName(for: deviceID)
        currentDeviceUID  = deviceUID(for: deviceID)
        readPhysicalFormat(for: deviceID)
    }

    func refreshAvailableDevices() {
        availableOutputDevices = allOutputDevices()
    }

    // MARK: - Listener

    private func startListening() {
        guard !listenerAdded else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.refreshAvailableDevices()
                self?.onDeviceChange?()
            }
        }
        listenerBlock = block
        var addr = defaultDeviceAddress()
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        listenerAdded = true
    }

    private func stopListening() {
        guard listenerAdded, let block = listenerBlock else { return }
        var addr = defaultDeviceAddress()
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        listenerAdded = false
    }

    // MARK: - Core Audio helpers

    private func defaultDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func defaultOutputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = defaultDeviceAddress()
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr else { return AudioDeviceID(kAudioObjectUnknown) }
        return deviceID
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &nameRef) == noErr else { return nil }
        return nameRef?.takeRetainedValue() as String?
    }

    private func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uidRef) == noErr else { return nil }
        return uidRef?.takeRetainedValue() as String?
    }

    private func readPhysicalFormat(for deviceID: AudioDeviceID) {
        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &streamsSize) == noErr,
              streamsSize > 0 else { return }

        let count = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
        var streamIDs = [AudioStreamID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &streamsAddr, 0, nil, &streamsSize, &streamIDs) == noErr,
              let firstStream = streamIDs.first else { return }

        var physAddr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(firstStream, &physAddr, 0, nil, &size, &format) == noErr else { return }

        currentSampleRate = format.mSampleRate > 0 ? format.mSampleRate : nil
        currentBitDepth   = format.mBitsPerChannel > 0 ? format.mBitsPerChannel : nil
        currentIsFloat    = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        currentChannels   = format.mChannelsPerFrame > 0 ? format.mChannelsPerFrame : nil
    }

    private func allOutputDevices() -> [(name: String, uid: String)] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { id -> (name: String, uid: String)? in
            // Only include devices with output streams.
            var outStreamsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var outSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &outStreamsAddr, 0, nil, &outSize) == noErr,
                  outSize > 0 else { return nil }
            guard let name = deviceName(for: id), let uid = deviceUID(for: id) else { return nil }
            return (name: name, uid: uid)
        }
    }
}
#endif
