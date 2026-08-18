// Sources/AiVoiceKit/macOS/AudioDeviceService.swift
// Ported from FluidVoice/Sources/Fluid/Services/AudioDeviceService.swift
// Changes: wrapped in #if os(macOS)
#if os(macOS)
import Combine
import CoreAudio
import Foundation

// MARK: - Audio Device Enumeration

enum AudioDevice {
    struct Device: Identifiable, Hashable {
        let id: AudioObjectID
        let uid: String
        let name: String
        let hasInput: Bool
        let hasOutput: Bool
    }

    static func listAllDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        status = deviceIDs.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, base)
        }
        guard status == noErr else { return [] }

        var devices: [Device] = []
        devices.reserveCapacity(deviceIDs.count)
        for devId in deviceIDs {
            let name = getStringProperty(devId, selector: kAudioObjectPropertyName,
                                         scope: kAudioObjectPropertyScopeGlobal) ?? "Unknown"
            let uid = getStringProperty(devId, selector: kAudioDevicePropertyDeviceUID,
                                        scope: kAudioObjectPropertyScopeGlobal) ?? ""
            let hasIn  = hasChannels(devId, scope: kAudioObjectPropertyScopeInput)
            let hasOut = hasChannels(devId, scope: kAudioObjectPropertyScopeOutput)
            devices.append(Device(id: devId, uid: uid, name: name, hasInput: hasIn, hasOutput: hasOut))
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func listInputDevices()  -> [Device] { listAllDevices().filter { $0.hasInput  } }
    static func listOutputDevices() -> [Device] { listAllDevices().filter { $0.hasOutput } }

    static func getDefaultInputDevice() -> Device? {
        guard let devId: AudioObjectID = getDefaultDeviceId(selector: kAudioHardwarePropertyDefaultInputDevice)
        else { return nil }
        return listAllDevices().first { $0.id == devId }
    }

    static func getDefaultOutputDevice() -> Device? {
        guard let devId: AudioObjectID = getDefaultDeviceId(selector: kAudioHardwarePropertyDefaultOutputDevice)
        else { return nil }
        return listAllDevices().first { $0.id == devId }
    }

    @discardableResult
    static func setDefaultInputDevice(uid: String) -> Bool {
        guard let device = listInputDevices().first(where: { $0.uid == uid }) else { return false }
        return setDefaultDeviceId(device.id, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    @discardableResult
    static func setDefaultOutputDevice(uid: String) -> Bool {
        guard let device = listOutputDevices().first(where: { $0.uid == uid }) else { return false }
        return setDefaultDeviceId(device.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func getInputDevice(byUID uid: String) -> Device? {
        listInputDevices().first { $0.uid == uid }
    }

    static func getOutputDevice(byUID uid: String) -> Device? {
        listOutputDevices().first { $0.uid == uid }
    }

    /// Returns the `AudioObjectID` for a given device UID without mutating system defaults.
    static func getDeviceId(forUID uid: String) -> AudioObjectID? {
        listAllDevices().first { $0.uid == uid }?.id
    }

    // MARK: - Private CoreAudio helpers

    private static func getDefaultDeviceId(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devId = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devId)
        return status == noErr ? devId : nil
    }

    private static func setDefaultDeviceId(_ devId: AudioObjectID,
                                           selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDevId = devId
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &mutableDevId)
        return status == noErr
    }

    private static func getStringProperty(_ devId: AudioObjectID,
                                          selector: AudioObjectPropertySelector,
                                          scope: AudioObjectPropertyScope) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(devId, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func hasChannels(_ devId: AudioObjectID,
                                    scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(devId, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }

        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPtr.deallocate() }

        status = AudioObjectGetPropertyData(devId, &address, 0, nil, &dataSize, rawPtr)
        guard status == noErr else { return false }

        let ablPtr = rawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }
}

// MARK: - Audio Hardware Observer

/// Publishes a monotonically increasing `changeTick` whenever CoreAudio reports
/// a device list or default-device change. Consumers can observe this to refresh
/// device menus without polling.
@MainActor
final class AudioHardwareObserver: ObservableObject {
    @Published private(set) var changeTick: UInt64 = 0

    private var installed = false
    // nonisolated(unsafe) so deinit (always nonisolated in Swift 6) can reach
    // these tokens to call AudioObjectRemovePropertyListenerBlock without crossing
    // the MainActor isolation boundary.
    nonisolated(unsafe) private var devicesListenerToken: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var defaultInputListenerToken: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var defaultOutputListenerToken: AudioObjectPropertyListenerBlock?

    init() {
        // Do NOT register here — see startObserving() for rationale.
    }

    /// Call this after the app has finished launching.
    /// Must NOT be called during `init` — CoreAudio registration races SwiftUI's
    /// AttributeGraph metadata pass and causes EXC_BAD_ACCESS.
    func startObserving() { register() }

    deinit { unregisterSync() }

    private func register() {
        guard !installed else { return }
        var addrDevices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var addrDefaultIn = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var addrDefaultOut = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let queue = DispatchQueue.main
        let sys = AudioObjectID(kAudioObjectSystemObject)

        let devToken: AudioObjectPropertyListenerBlock  = { [weak self] _, _ in MainActor.assumeIsolated { self?.changeTick &+= 1 } }
        let inToken:  AudioObjectPropertyListenerBlock  = { [weak self] _, _ in MainActor.assumeIsolated { self?.changeTick &+= 1 } }
        let outToken: AudioObjectPropertyListenerBlock  = { [weak self] _, _ in MainActor.assumeIsolated { self?.changeTick &+= 1 } }

        let s1 = AudioObjectAddPropertyListenerBlock(sys, &addrDevices,    queue, devToken)
        let s2 = AudioObjectAddPropertyListenerBlock(sys, &addrDefaultIn,  queue, inToken)
        let s3 = AudioObjectAddPropertyListenerBlock(sys, &addrDefaultOut, queue, outToken)

        guard s1 == noErr, s2 == noErr, s3 == noErr else {
            // Best-effort cleanup
            if s1 == noErr { _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDevices,    queue, devToken) }
            if s2 == noErr { _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultIn,  queue, inToken) }
            if s3 == noErr { _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultOut, queue, outToken) }
            installed = false
            return
        }

        devicesListenerToken = devToken
        defaultInputListenerToken = inToken
        defaultOutputListenerToken = outToken
        installed = true
    }

    /// Nonisolated so `deinit` (always nonisolated in Swift 6) can call this directly.
    /// Only touches `nonisolated(unsafe)` token storage and C CoreAudio API — no
    /// MainActor-isolated state is accessed here.
    nonisolated private func unregisterSync() {
        var addrDevices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var addrDefaultIn = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var addrDefaultOut = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let queue = DispatchQueue.main
        let sys = AudioObjectID(kAudioObjectSystemObject)

        if let token = devicesListenerToken       { _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDevices,    queue, token) }
        if let token = defaultInputListenerToken  { _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultIn,  queue, token) }
        if let token = defaultOutputListenerToken { _ = AudioObjectRemovePropertyListenerBlock(sys, &addrDefaultOut, queue, token) }

        devicesListenerToken = nil
        defaultInputListenerToken = nil
        defaultOutputListenerToken = nil
    }
}
#endif
