import CoreAudio
import Foundation

/// The sound output selected in macOS. Read on demand (a few property reads per volume key
/// press); nothing is observed or polled.
public enum AudioOutput {
    public struct Current {
        public let name: String
        /// Audio sent over HDMI or DisplayPort, i.e. a monitor's speakers or headphone jack.
        public let isDisplayAudio: Bool
        /// Whether macOS can set the device's volume itself. It can't for most monitors, which
        /// is why their volume goes over DDC.
        public let hasSystemVolume: Bool
    }

    public static func current() -> Current? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }

        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameStatus = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        let deviceName = nameStatus == noErr ? (name?.takeRetainedValue() as String?) ?? "" : ""

        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)

        return Current(
            name: deviceName,
            isDisplayAudio: transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort,
            hasSystemVolume: hasSettableVolume(device, element: kAudioObjectPropertyElementMain) || hasSettableVolume(device, element: 1)
        )
    }

    private static func hasSettableVolume(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }
}
