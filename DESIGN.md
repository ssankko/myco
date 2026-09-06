# Mixanimo

A macOS menu bar app that plays one audio stream to many output devices at the same time, each with its own volume, delay, buffer size and EQ, and that mixes many microphones into one input device. Built for gaming under CrossOver (Wine), where the game must never see a device change.

## Why not an aggregate device

An aggregate device is a thin wrapper over real hardware. Its sample rate follows the clock master, every subdevice must run at that rate, and when a Bluetooth subdevice drops the aggregate is rebuilt. Wine's CoreAudio backend holds the device it opened, so a rebuild leaves the game talking to a dead stream. That is the crackle, the silent headphones after reconnect, and the sample rate reset that PolySound shows.

Mixanimo instead publishes two virtual devices through its own HAL driver. They never disappear while the app runs and their rate never changes under a client. Hot swap of physical devices happens inside the app's engine, where the game cannot see it.

## Components

### Driver (C, `Sources/MixanimoDriver`)

An AudioServerPlugIn loaded by coreaudiod from `/Library/Audio/Plug-Ins/HAL/Mixanimo.driver`. Pure C, written from scratch against `CoreAudio/AudioServerPlugIn.h`. MIT.

Publishes two devices:

- `Mixanimo` output, stereo, float32. Nominal rate selectable from 44100, 48000, 88200, 96000, 176400, 192000. Exposes a volume control on the output scope so the Mac's volume keys, menu bar slider and HUD act on it.
- `Mixanimo Mic` input, mono, float32, fixed 48000.

Each device is a loopback ring buffer. For the output device, clients write into the ring and the app reads it back as the device's input stream, one IO cycle of latency. For the mic device the app writes and clients read. The driver's clock is the host clock (`mach_absolute_time`).

Both devices report `kAudioDevicePropertyIsHidden = true` until a client whose bundle ID is the Mixanimo app attaches (`AddDeviceClient`). They hide again when that client detaches (`RemoveDeviceClient`). A crash of the app detaches it, so the devices are never visible without the app.

The plugin object exposes a custom property with the driver version so the app can detect a stale driver.

Realtime rules inside the driver: no allocation, no locks, no unchecked indexing in `DoIOOperation`. Property access uses a single mutex outside the IO path.

### Engine (Swift, `Sources/Mixanimo/Engine`)

Runs in the app process.

Output path:

1. One IO callback on the `Mixanimo` device reads the mixed feed. Its buffer size is the smallest
   enabled output's buffer size converted to the virtual rate, so a 32-frame wired output is not
   held to the process default of about 512 frames.
2. Each enabled physical output has its own IO callback at its own buffer size (`kAudioDevicePropertyBufferFrameSize`, clamped to the device's reported range). Defaults: 256 frames for Bluetooth transport, 128 otherwise.
3. Per output, in order: ring buffer from the feed, resampler from the virtual rate to the device's current nominal rate (the device's rate is never changed by Mixanimo), drift correction by nudging the resample ratio from the ring fill level, optional mic monitor summed in, ten-band EQ (biquads via Accelerate `vDSP_biquad`, RBJ coefficients, filter types matching Apple's EQ unit), delay line, per-output gain, master gain.
4. Master gain mirrors the driver's volume control both ways.

Input path:

1. Each enabled physical input has its own IO callback. Per input: gain, mute.
2. All enabled inputs are resampled to 48000 and summed into the mic mix.
3. The mix is written into `Mixanimo Mic` for other apps.
4. Outputs with monitor on read the same mix through a direct ring at their own buffer size, not through the driver, so the wired path stays at a few milliseconds.

Hot swap: the engine listens for `kAudioHardwarePropertyDevices`. A device whose UID has saved settings resumes with them. A device seen for the first time is listed off. Built-in speakers are never enabled automatically.

Pinning: while running and with the toggle on, the engine listens for default output and default input changes and sets them back to the virtual devices.

Sync: a global toggle. Off means every output delay is 0. On means each output delay is the largest reported output latency (`kAudioDevicePropertyLatency` + `kAudioDevicePropertySafetyOffset` + stream latency + buffer size + what its feed ring holds) among enabled outputs minus its own, plus a per-output manual trim in milliseconds.

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
