# Myco architecture

A macOS menu bar app that plays one audio stream to many output devices at the same time, each with its own volume, delay, buffer size and EQ, and that mixes many microphones into one input device. Built for gaming under CrossOver (Wine), where the game must never see a device change.

## Why not an aggregate device

An aggregate device is a thin wrapper over real hardware. Its sample rate follows the clock master, every subdevice must run at that rate, and when a Bluetooth subdevice drops the aggregate is rebuilt. Wine's CoreAudio backend holds the device it opened, so a rebuild leaves the game talking to a dead stream. That is the crackle, the silent headphones after reconnect, and the sample rate reset that PolySound shows.

Myco instead publishes two virtual devices through its own HAL driver. They never disappear while the app runs and their rate never changes under a client. Hot swap of physical devices happens inside the app's engine, where the game cannot see it.

## Components

### Driver (C, `Sources/MycoDriver`)

An AudioServerPlugIn loaded by coreaudiod from `/Library/Audio/Plug-Ins/HAL/Myco.driver`. Pure C, written from scratch against `CoreAudio/AudioServerPlugIn.h`. MIT.

Publishes two devices:

- `Myco` output only, stereo, float32. Nominal rate selectable from 44100, 48000, 88200, 96000, 176400, 192000. Exposes a volume control on the output scope so the Mac's volume keys, menu bar slider and HUD act on it.
- `Myco Mic` input, mono, float32, fixed 48000.

`Myco` publishes its ring in a POSIX shared memory object, `/myco-feed`, mode 0644 with the driver as the only writer. A page of header (magic `MXFD`, layout version, channels, ring frames, sample rate, a generation raised at every load, the write position and the last IO block size) is followed by 131072 interleaved stereo float frames. Clients write into the ring; the first writer of a span overwrites it and clears the gap the last one left, later writers in the same span add, so several games mix. The write position is published with a release store, which is the whole handshake with the app. The app maps the object read only and every physical output reads it directly, so nothing captures an input stream and macOS shows no microphone indicator.

`Myco Mic` stays a loopback ring inside the driver: the app writes it through an IO proc whose input stream usage is off, so the HAL runs no input operation for it, and clients read it back through its input stream. The driver's clock is the host clock (`mach_absolute_time`).

`Myco Mic` carries a custom property, `'mxci'`, a CFString with the number of processes other than the app that read it within the last half second. The host calls `StartIO` and `StopIO` for the device as a whole, not per client, and reads the ring once per cycle, so the driver takes the per-client `ProcessInput` operation, does nothing to the samples, and stamps a slot per client with the host time of that cycle. A timer on the driver's own queue compares the count every quarter second with the last one it posted and posts a change when it moved, because the HAL hands a process the value it last read until the driver posts a change. `StartIO` and `StopIO` stamp and clear the client they name and post at once, so a reader on an idle device is seen without waiting for the timer. The app listens for the change and opens or closes the physical microphones.

Both devices report `kAudioDevicePropertyIsHidden = true` until a client whose bundle ID is the Myco app attaches (`AddDeviceClient`). The host attaches every process that holds a connection to CoreAudio, so the app's property listeners are enough and it needs no IO proc for this. They hide again when that client detaches (`RemoveDeviceClient`). A crash of the app detaches it, so the devices are never visible without the app.

The plugin object exposes a custom property with the driver version so the app can detect a stale driver.

Realtime rules inside the driver: no allocation, no locks, no unchecked indexing in `DoIOOperation`. Property access uses a single mutex outside the IO path.

### Engine (Swift, `Sources/MycoEngine`)

Runs in the app process on its own actor, so a device that takes its time to start or stop never holds the popover; the model carries a flag while nodes are stopped and started, and a change
that only moves a parameter never raises it.

The sample maths it calls, and the two atomic handoff types the IO threads read parameters through, live in `Sources/MycoDSP`. That target imports no CoreAudio and no UI, so its tests run on any machine with no device attached.

Only the outputs whose device, sample rate or buffer size changed are stopped and built again, and a change to the virtual rate replaces every one of them, because each output's resampler is built against that rate. A change to the inputs, or to a monitor toggle, stops no output; the inputs are rebuilt under the running outputs, as they also are whenever the set of outputs changes, because every output carries a monitor tap with a fixed set of rings that the inputs are pointed at, and the monitor gain ramps between zero and the set level. Before any node stops, its gain ramps to zero and the engine waits for the ramp to play out; every new node starts silent and ramps in.

Output path:

1. `SharedFeed` maps `/myco-feed` read only once and checks the magic and the layout version. An object that is missing, or one this build cannot read, is reported as an outdated driver and no output starts. There is no IO callback on the `Myco` device at all.
2. Each enabled physical output has its own IO callback at its own buffer size (`kAudioDevicePropertyBufferFrameSize`, clamped to the device's reported range). Defaults: 256 frames for Bluetooth transport, 128 otherwise.
3. Per output, in order: its own reading position in the shared ring, held the driver's last IO block plus two of its own pulls behind the driver's write position, eight more pulls on a Bluetooth output, resampler from the virtual rate to the device's current nominal rate (the device's rate is never changed by Myco), drift correction by nudging the resample ratio from the distance to the write position, optional mic monitor summed in, ten-band EQ (biquads via Accelerate `vDSP_biquad`, RBJ coefficients, filter types matching Apple's EQ unit), delay line, per-output gain, master gain.
4. Master gain mirrors the driver's volume control both ways. An output whose device has a volume control of its own carries the master on that control and applies no master gain in software, and the engine listens to the control, so a level changed on the device itself, as a swipe on an AirPods stem does, becomes the master and reaches every other output. A device without a control gets the master as software gain.

An output whose read position catches up with the driver's plays silence, freezes its drift correction and waits; when the write position moves again it takes a fresh position behind it. Every underrun also widens the position it takes by one of its own pulls, up to eight, so a client whose write time jitters more than two pulls, as one with a large IO buffer does, earns the margin it needs once instead of clicking on. A Bluetooth output starts with all eight: its link already holds a hundred milliseconds or more, so the margin is not heard, and the clicks that would earn it are. A changed generation, which is what a coreaudiod restart leaves behind, does the same. A header sample rate that no longer matches rebuilds the graph, as a virtual rate change already does.

Input path:

1. Each enabled physical input has its own IO callback, open only while something listens: another process reads `Myco Mic`, or a monitor is on for an enabled output. Idle, the microphones stay closed and macOS shows no microphone indicator for Myco. A reader that starts finds silence until the inputs are up, then each fades in from silence. Per input: gain, mute.
2. All enabled inputs are resampled to 48000 and summed into the mic mix.
3. The mix is written into `Myco Mic` for other apps.
4. Every output reads the same mix through a direct ring at its own buffer size, not through the driver, so the wired path stays at a few milliseconds; with monitor off the ring is drained and dropped. The monitor plays whether or not anything plays into the virtual device.

Hot swap: the engine listens for `kAudioHardwarePropertyDevices`. A device whose UID has saved settings resumes with them. A device seen for the first time is listed off. Built-in speakers are never enabled automatically.

Pinning: while running and with the toggle on, the engine listens for default output and default input changes and sets them back to the virtual devices.

Sync: a global toggle. Off means every output delay is 0. On means each output delay is the largest reported output latency (`kAudioDevicePropertyLatency` + `kAudioDevicePropertySafetyOffset` + stream latency + buffer size + the target fill it holds in the shared ring) among enabled outputs minus its own, plus a per-output manual trim in milliseconds.

Lifecycle: on launch, remember the current default output and input, then pin to the virtual devices. On quit, restore them. On launch after a crash, the same logic applies because the driver already hid the devices when the app died.

### App (SwiftUI, `Sources/Myco`)

Menu bar item with a popover, both plain AppKit windows; the app opens no SwiftUI scene window, because a window left on another space makes activation switch to that space. Popover contents: master slider, output list (row: enable toggle, name, transport icon, volume, buffer size, monitor toggle and gain, sync trim when sync is on, EQ button), input list (row: enable toggle, name, gain, mute), virtual rate picker, sync toggle, driver status with install/uninstall, settings (pin defaults, launch at login). EQ opens in its own window per output. Visual design follows the frontend-design skill.

Settings persist in `UserDefaults`, keyed by device UID. The app also watches the launch at login setting and registers or unregisters `SMAppService.mainApp`, which only the shipped bundle ID does.

### Build

Swift package, eight targets: `MycoDriver` (C, dynamic library), `MycoAtomics` (C headers carrying the shared feed layout and the memory orderings both sides use), `MycoDSP` (the sample maths, no CoreAudio), `MycoEngine` (the CoreAudio wrappers, the graph, the model and the driver installer), `Myco` (the SwiftUI executable), and the tests `MycoDSPTests`, `MycoEngineTests` with the signal measurements both assert on in `MycoTestSupport`. `swift test --filter MycoDSPTests` needs no device and no microphone permission; the engine tests need both. `scripts/bundle.sh` builds and assembles `Myco.app` with `Myco.driver` inside `Contents/Resources`. `Makefile` verbs: `build`, `install`, `uninstall`, `run`.

Install copies the driver to `/Library/Audio/Plug-Ins/HAL` and restarts coreaudiod, through one admin prompt (`osascript` with administrator privileges). Uninstall reverses it. The app offers both from the menu and also checks the driver version on launch.

Ad-hoc code signing only. Releases on GitHub are unsigned; the README states the `xattr -dr com.apple.quarantine` step.

Deployment target macOS 14. Swift 6. No third-party packages.

## Non-goals

- Per-listener keyboard hotkeys.
- A monitor matrix (which mic goes to which output). Monitor is on or off per output and carries the whole mic mix.
- Intercepting media keys.
- Notarisation.
