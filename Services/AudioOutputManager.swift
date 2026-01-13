import AVFoundation
import CoreAudio

/// Represents an audio output device
struct AudioOutputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    static let systemDefault = AudioOutputDevice(id: 0, name: "System Default", uid: "")
}

/// Manages audio output device selection
final class AudioOutputManager {
    static let shared = AudioOutputManager()

    private var cachedDevices: [AudioOutputDevice]?
    private var cacheTime: Date?
    private let cacheExpirationInterval: TimeInterval = 30  // 30 seconds cache

    private init() {}

    /// Get list of available audio output devices (cached)
    func availableOutputDevices() -> [AudioOutputDevice] {
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
    private func fetchDevicesFromSystem() -> [AudioOutputDevice] {
        var devices: [AudioOutputDevice] = [.systemDefault]

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
            if isOutputDevice(deviceID), let device = getDeviceInfo(deviceID) {
                devices.append(device)
            }
        }

        return devices
    }

    /// Check if a device has output capabilities
    private func isOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
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
    private func getDeviceInfo(_ deviceID: AudioDeviceID) -> AudioOutputDevice? {
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

        return AudioOutputDevice(id: deviceID, name: name, uid: uid)
    }

    /// Get device by UID
    func device(withUID uid: String) -> AudioOutputDevice? {
        if uid.isEmpty { return .systemDefault }
        return availableOutputDevices().first { $0.uid == uid }
    }

    /// Get AudioDeviceID for the specified UID, or default output device if empty
    func deviceID(forUID uid: String) -> AudioDeviceID? {
        if uid.isEmpty {
            return getDefaultOutputDeviceID()
        }
        return device(withUID: uid)?.id
    }

    /// Get the system's default output device ID
    private func getDefaultOutputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        return status == noErr ? deviceID : nil
    }
}

enum AudioOutputError: LocalizedError {
    case deviceNotFound
    case failedToSetDevice(OSStatus)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "Audio output device not found"
        case .failedToSetDevice(let status):
            return "Failed to set audio output device (error: \(status))"
        }
    }
}
