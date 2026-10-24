import AVFoundation
import CoreAudio

/// Represents an audio input device
struct AudioInputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    static let systemDefault = AudioInputDevice(id: 0, name: "System Default", uid: "")
}

/// Manages audio input device selection
final class AudioInputManager {
    static let shared = AudioInputManager()

    // Cache state protected by `cacheLock`, mirroring AudioOutputManager —
    // callers are currently mostly MainActor UI code, but that is not
    // guaranteed, so all cache access must be serialized.
    private var cachedDevices: [AudioInputDevice]?
    private var cacheTime: Date?
    private let cacheLock = NSLock()
    private let cacheExpirationInterval: TimeInterval = 30  // 30 seconds cache

    private init() {}

    /// Get list of available audio input devices (cached)
    func availableInputDevices() -> [AudioInputDevice] {
        cacheLock.lock()
        if let cached = cachedDevices,
           let time = cacheTime,
           Date().timeIntervalSince(time) < cacheExpirationInterval {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Fetch outside the lock (Core Audio calls can be slow) then re-acquire
        // to publish the result.
        let devices = fetchDevicesFromSystem()
        cacheLock.lock()
        cachedDevices = devices
        cacheTime = Date()
        cacheLock.unlock()
        return devices
    }

    /// Clear the device cache (call when devices might have changed)
    func clearCache() {
        cacheLock.lock()
        cachedDevices = nil
        cacheTime = nil
        cacheLock.unlock()
    }

    /// Fetch devices from system (Core Audio)
    private func fetchDevicesFromSystem() -> [AudioInputDevice] {
        var devices: [AudioInputDevice] = [.systemDefault]

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return devices }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return devices }

        for deviceID in deviceIDs {
            if isInputDevice(deviceID), let device = getDeviceInfo(deviceID) {
                devices.append(device)
            }
        }

        return devices
    }

    /// Check if a device has input capabilities
    private func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)

        guard status == noErr, dataSize > 0 else { return false }

        // Allocate the size Core Audio actually reported, not one AudioBufferList.
        // A device with multiple streams (e.g. a multi-channel non-interleaved
        // interface) returns dataSize > MemoryLayout<AudioBufferList>.size because
        // the struct is variable-length (mBuffers is a trailing array), so a
        // fixed capacity:1 allocation would be overrun by AudioObjectGetPropertyData.
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let getStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, rawPointer)

        guard getStatus == noErr else { return false }

        let bufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self).pointee
        return bufferList.mNumberBuffers > 0
    }

    /// Get device name and UID
    private func getDeviceInfo(_ deviceID: AudioDeviceID) -> AudioInputDevice? {
        // Get device name
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var nameRef: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        var status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &nameRef)
        guard status == noErr, let name = nameRef?.takeRetainedValue() as String? else { return nil }

        // Get device UID
        propertyAddress.mSelector = kAudioDevicePropertyDeviceUID
        var uidRef: Unmanaged<CFString>?
        dataSize = UInt32(MemoryLayout<CFString?>.size)

        status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &uidRef)
        guard status == noErr, let uid = uidRef?.takeRetainedValue() as String? else { return nil }

        return AudioInputDevice(id: deviceID, name: name, uid: uid)
    }

    /// Set the input device for an AVAudioEngine
    /// Call this before starting the engine
    func setInputDevice(_ device: AudioInputDevice, for audioEngine: AVAudioEngine) throws {
        // If system default, don't set anything (use default behavior)
        guard device.id != 0 else { return }

        // On macOS 27, selecting the device that is already the default input
        // stops the engine's input tap from receiving buffers, so leave it as is.
        // The engine then follows the default input; a later change of the
        // default stops it (see AudioEngineConfigurationObserver).
        if #available(macOS 27, *), device.id == defaultInputDeviceID() { return }

        let audioUnit = audioEngine.inputNode.audioUnit
        guard let audioUnit = audioUnit else {
            throw AudioInputError.audioUnitNotFound
        }

        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw AudioInputError.failedToSetDevice(status)
        }
    }

    /// Current system default input device, or nil if it cannot be read
    private func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    /// Get device by UID
    func device(withUID uid: String) -> AudioInputDevice? {
        if uid.isEmpty { return .systemDefault }
        return availableInputDevices().first { $0.uid == uid }
    }
}

enum AudioInputError: LocalizedError {
    case audioUnitNotFound
    case failedToSetDevice(OSStatus)

    var errorDescription: String? {
        switch self {
        case .audioUnitNotFound:
            return "Audio unit not found"
        case .failedToSetDevice(let status):
            return "Failed to set audio device (error: \(status))"
        }
    }
}

/// Calls `handler` on the main actor when `engine` posts a configuration change,
/// such as the default input device switching while recording. The engine may
/// have stopped by then. The observation ends when this object is released.
final class AudioEngineConfigurationObserver {
    private let token: NSObjectProtocol

    init(engine: AVAudioEngine, handler: @escaping @MainActor @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
