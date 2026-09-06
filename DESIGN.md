# Mixanimo

A macOS menu bar app that plays one audio stream to many output devices at the same time, each with its own volume, delay, buffer size and EQ, and that mixes many microphones into one input device. Built for gaming under CrossOver (Wine), where the game must never see a device change.

## Why not an aggregate device

An aggregate device is a thin wrapper over real hardware. Its sample rate follows the clock master, every subdevice must run at that rate, and when a Bluetooth subdevice drops the aggregate is rebuilt. Wine's CoreAudio backend holds the device it opened, so a rebuild leaves the game talking to a dead stream. That is the crackle, the silent headphones after reconnect, and the sample rate reset that PolySound shows.

Mixanimo instead publishes two virtual devices through its own HAL driver. They never disappear while the app runs and their rate never changes under a client. Hot swap of physical devices happens inside the app's engine, where the game cannot see it.

## Components

### Driver (C, `Sources/MixanimoDriver`)

An AudioServerPlugIn loaded by coreaudiod from `/Library/Audio/Plug-Ins/HAL/Mixanimo.driver`. Pure C, written from scratch against `CoreAudio/AudioServerPlugIn.h`. MIT.

Publishes two devices:

- `Mixanimo` output only, stereo, float32. Nominal rate selectable from 44100, 48000, 88200, 96000, 176400, 192000. Exposes a volume control on the output scope so the Mac's volume keys, menu bar slider and HUD act on it.
- `Mixanimo Mic` input, mono, float32, fixed 48000.

`Mixanimo` publishes its ring in a POSIX shared memory object, `/mixanimo-feed`, mode 0644 with the driver as the only writer. A page of header (magic `MXFD`, layout version, channels, ring frames, sample rate, a generation raised at every load, the write position and the last IO block size) is followed by 131072 interleaved stereo float frames. Clients write into the ring; the first writer of a span overwrites it and clears the gap the last one left, later writers in the same span add, so several games mix. The write position is published with a release store, which is the whole handshake with the app. The app maps the object read only and every physical output reads it directly, so nothing captures an input stream and macOS shows no microphone indicator.

`Mixanimo Mic` stays a loopback ring inside the driver: the app writes it and clients read it back through its input stream. The driver's clock is the host clock (`mach_absolute_time`).

Both devices report `kAudioDevicePropertyIsHidden = true` until a client whose bundle ID is the Mixanimo app attaches (`AddDeviceClient`). The host attaches every process that holds a connection to CoreAudio, so the app's property listeners are enough and it needs no IO proc for this. They hide again when that client detaches (`RemoveDeviceClient`). A crash of the app detaches it, so the devices are never visible without the app.

The plugin object exposes a custom property with the driver version so the app can detect a stale driver.

Realtime rules inside the driver: no allocation, no locks, no unchecked indexing in `DoIOOperation`. Property access uses a single mutex outside the IO path.

### Engine (Swift, `Sources/Mixanimo/Engine`)

Runs in the app process.

Output path:

1. `SharedFeed` maps `/mixanimo-feed` read only once and checks the magic and the layout version. An object that is missing, or one this build cannot read, is reported as an outdated driver and no output starts. There is no IO callback on the `Mixanimo` device at all.
2. Each enabled physical output has its own IO callback at its own buffer size (`kAudioDevicePropertyBufferFrameSize`, clamped to the device's reported range). Defaults: 256 frames for Bluetooth transport, 128 otherwise.
3. Per output, in order: its own reading position in the shared ring, held the driver's last IO block plus two of its own pulls behind the driver's write position, resampler from the virtual rate to the device's current nominal rate (the device's rate is never changed by Mixanimo), drift correction by nudging the resample ratio from the distance to the write position, optional mic monitor summed in, ten-band EQ (biquads via Accelerate `vDSP_biquad`, RBJ coefficients, filter types matching Apple's EQ unit), delay line, per-output gain, master gain.
4. Master gain mirrors the driver's volume control both ways.

An output whose read position catches up with the driver's plays silence, freezes its drift correction and waits; when the write position moves again it takes a fresh position behind it. A changed generation, which is what a coreaudiod restart leaves behind, does the same. A header sample rate that no longer matches rebuilds the graph, as a virtual rate change already does.

Input path:

1. Each enabled physical input has its own IO callback. Per input: gain, mute.
2. All enabled inputs are resampled to 48000 and summed into the mic mix.
3. The mix is written into `Mixanimo Mic` for other apps.
4. Outputs with monitor on read the same mix through a direct ring at their own buffer size, not through the driver, so the wired path stays at a few milliseconds.

Hot swap: the engine listens for `kAudioHardwarePropertyDevices`. A device whose UID has saved settings resumes with them. A device seen for the first time is listed off. Built-in speakers are never enabled automatically.

Pinning: while running and with the toggle on, the engine listens for default output and default input changes and sets them back to the virtual devices.

Sync: a global toggle. Off means every output delay is 0. On means each output delay is the largest reported output latency (`kAudioDevicePropertyLatency` + `kAudioDevicePropertySafetyOffset` + stream latency + buffer size + the target fill it holds in the shared ring) among enabled outputs minus its own, plus a per-output manual trim in milliseconds.

Lifecycle: on launch, remember the current default output and input, then pin to the virtual devices. On quit, restore them. On launch after a crash, the same logic applies because the driver already hid the devices when the app died.

### App (SwiftUI, `Sources/Mixanimo/UI`)

Menu bar item with a popover. Popover contents: master slider, output list (row: enable toggle, name, transport icon, volume, buffer size, monitor toggle and gain, sync trim when sync is on, EQ button), input list (row: enable toggle, name, gain, mute), virtual rate picker, sync toggle, driver status with install/uninstall, settings (pin defaults, launch at login). EQ opens in its own window per output. Visual design follows the frontend-design skill.

Settings persist in `UserDefaults`, keyed by device UID.

### Build

Swift package, three targets: `MixanimoDriver` (C, dynamic library), `Mixanimo` (Swift executable), `MixanimoTests`. `scripts/bundle.sh` builds and assembles `Mixanimo.app` with `Mixanimo.driver` inside `Contents/Resources`. `Makefile` verbs: `build`, `install`, `uninstall`, `run`.

Install copies the driver to `/Library/Audio/Plug-Ins/HAL` and restarts coreaudiod, through one admin prompt (`osascript` with administrator privileges). Uninstall reverses it. The app offers both from the menu and also checks the driver version on launch.

Ad-hoc code signing only. Releases on GitHub are unsigned; the README states the `xattr -dr com.apple.quarantine` step.

Deployment target macOS 14. Swift 6. No third-party packages.

## Non-goals

- Per-listener keyboard hotkeys.
- A monitor matrix (which mic goes to which output). Monitor is on or off per output and carries the whole mic mix.
- Intercepting media keys.
- Notarisation.
