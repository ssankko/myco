<div align="center">

<img src="Sources/Myco/Myco.svg" width="144" height="144" alt="Myco">

# Myco

**One audio stream to every speaker, every microphone into one input**

[![CI](https://github.com/ssankko/myco/actions/workflows/ci.yml/badge.svg)](https://github.com/ssankko/myco/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/tag/ssankko/myco?label=release&color=c5f4d4)](https://github.com/ssankko/myco/releases)
[![License](https://img.shields.io/badge/license-MIT-173b30)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS-111?logo=apple&logoColor=white)

<p align="center">
  <img src="docs/popover.png" width="452" alt="The Myco popover: a master slider, an output card with volume, buffer, latency and EQ, and the list of microphones">
</p>

</div>

## What can it do?

Myco is a menu bar app that plays whatever macOS plays to several output devices at the same time, and mixes several microphones into one input device. Each output has its own volume, delay, buffer size and ten-band EQ.

I made it for gaming under CrossOver with AirPods and speakers on at once. Every app I tried did this with an aggregate device, and an aggregate device is rebuilt whenever a Bluetooth device drops, which leaves the game talking to a dead stream. Myco publishes two virtual devices through its own audio driver and does the routing itself, so the devices never disappear and the game never notices a change.

## Features

- **Many outputs at once.** Turn on any set of devices; each gets a volume, a delay, a buffer size and an EQ of its own.
- **Aligned outputs.** One switch delays every output to the slowest one, so speakers and headphones stay in time.
- **One microphone from many.** Turn on the microphones you want, set each gain, and every app sees one input device.
- **Monitoring.** Hear a microphone in any output, with its own level.
- **Nothing changes under the apps.** The virtual devices keep their rate and their identity while physical devices come and go.

## Install

Requires macOS 14 or later.

1. Download `Myco-x.y.z.zip` from [Releases](https://github.com/ssankko/myco/releases), unzip it and move `Myco.app` to `/Applications`.
2. The download is not notarized, so remove the quarantine flag once:
   ```
   xattr -dr com.apple.quarantine /Applications/Myco.app
   ```
3. Open Myco from the menu bar and click **Install**. macOS asks for an administrator password because the driver goes into `/Library/Audio/Plug-Ins/HAL`.
4. Turn on the outputs you want to hear.

**Remove driver** at the bottom of the popover takes the driver out again.

## Build

Requires Xcode 16 or later. There is no Xcode project.

```
make build          # dist/Myco.app with the driver inside
make install        # copies the driver into place (administrator prompt)
swift test --filter MycoDSPTests   # the sample maths, no hardware needed
make test-capture   # everything; needs the driver installed and a microphone
```

[ARCHITECTURE.md](ARCHITECTURE.md) explains the driver, the shared-memory feed and the engine. [DESIGN.md](DESIGN.md) is the visual design guide.

## License

[MIT](LICENSE)
