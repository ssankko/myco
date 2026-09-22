import CoreAudio
import Foundation

/// The processes coreaudiod serves, as the HAL lists them on the system object.
enum AudioProcesses {
    private static let list = AudioObjectPropertyAddress(kAudioHardwarePropertyProcessObjectList)
    private static let isRunningInput = AudioObjectPropertyAddress(kAudioProcessPropertyIsRunningInput)
    private static let pid = AudioObjectPropertyAddress(kAudioProcessPropertyPID)

    /// How many processes other than this one run input on some device, or nil when the HAL
    /// could not answer for one of them.
    static var othersRunningInput: Int? {
        guard let processes = try? AudioObjectID.system.array(list) as [AudioObjectID] else { return nil }
        let me = getpid()
        var count = 0
        for process in processes {
            guard let pid = try? process.value(pid) as pid_t,
                let running = try? process.value(isRunningInput) as UInt32
            else { return nil }
            if pid != me, running != 0 { count += 1 }
        }
        return count
    }
}
