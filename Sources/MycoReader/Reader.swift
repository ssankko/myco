import CoreAudio
import Foundation

/// Reads the input stream of the device named by UID on the command line until stdin closes.
@main
struct Reader {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: MycoReader <device UID>\n".utf8))
            exit(64)
        }
        var uid = CommandLine.arguments[1] as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let found = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard found == noErr, device != AudioObjectID(kAudioObjectUnknown) else { exit(66) }
        var proc: AudioDeviceIOProcID?
        // Sendable, so the block is not main-actor isolated and may run on the HAL's IO thread.
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil, { @Sendable _, _, _, _, _ in }) == noErr,
            AudioDeviceStart(device, proc) == noErr
        else { exit(69) }
        // One line once the proc runs, so a parent knows when the reader counts.
        print("reading")
        fflush(stdout)
        while readLine() != nil {}
        AudioDeviceStop(device, proc)
    }
}
