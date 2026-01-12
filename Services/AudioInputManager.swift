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

    private var cachedDevices: [AudioInputDevice]?
    private var cacheTime: Date?
    private let cacheExpirationInterval: TimeInterval = 30  // 30 seconds cache

    private init() {}

    /// Get list of available audio input devices (cached)
    func availableInputDevices() -> [AudioInputDevice] {
        // Return cached devices if available and not expired
        if let cached = cachedDevices,
           let time = cacheTime,
           Date().timeIntervalSince(time) < cacheExpirationInterval {
            return cached
        }

        let devices = fetchDevicesFromSystem()
        cachedDevices = devices
        cacheTime = Date()
        return devices
    }

    /// Clear the device cache (call when devices might have changed)
    func clearCache() {
        cachedDevices = nil
        cacheTime = nil
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

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPointer.deallocate() }

        let getStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)

        guard getStatus == noErr else { return false }

        let bufferList = bufferListPointer.pointee
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
