# Myco

<img src="Sources/Myco/Myco.svg" width="64" align="right" alt="">

A macOS menu bar app that plays one audio stream to many output devices at once and mixes many microphones into one input device.

Each output has its own volume, delay, buffer size and ten-band EQ. Outputs come and go without the playing app noticing, because the app publishes two virtual devices through its own audio driver and does the routing itself. It was built for gaming under CrossOver, where a device change under the game means crackle or silence, but it works with any app.

<p align="center"><img src="docs/popover.png" width="406" alt="The Myco popover, with one output card and the microphone list"></p>

## Install

Requires macOS 14 or later.

1. Download the latest `Myco-x.y.z.zip` from [Releases](https://github.com/ssankko/myco/releases), unzip it and move `Myco.app` to `/Applications`.
2. Open it. Myco lives in the menu bar; there is no Dock tile.
3. Click **Install** in the popover. macOS asks for an administrator password because the driver goes into `/Library/Audio/Plug-Ins/HAL`. The audio system restarts once.
4. Turn on the outputs you want to hear. Myco makes itself the system output and, if you turn on a microphone, the system input.

Remove the driver with **Remove driver** at the bottom of the popover, then delete the app.

If macOS says the app is damaged, the download was not notarized. Run this once:

```
xattr -dr com.apple.quarantine /Applications/Myco.app
```

## Build from source

Requires Xcode 16 or later. There is no Xcode project; the package builds from the command line.

```
make build     # dist/Myco.app with the driver inside
make install   # copies the driver into /Library/Audio/Plug-Ins/HAL (administrator prompt)
make run
make uninstall
```

A build from source is signed ad hoc, which runs on the machine that built it.

## Tests

```
swift test --filter MycoDSPTests   # the sample maths; needs no device
make test-capture                  # everything; needs the driver installed and a microphone
```

The engine tests play tones through the driver and read them back. They run in a Terminal.app window because that is where the microphone permission lives. Quit Myco before running them.

## How it works

[DESIGN.md](DESIGN.md) describes the driver, the shared-memory feed, the engine graph and the reasons behind them.

## Releasing

A tag `vX.Y.Z` builds, signs, notarizes and publishes `Myco-X.Y.Z.zip` through the release workflow. The repository needs five secrets:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12` | A "Developer ID Application" certificate with its private key, exported as `.p12` and base64 encoded |
| `DEVELOPER_ID_P12_PASSWORD` | The password of that export |
| `NOTARY_KEY_P8` | An App Store Connect API key (`.p8`), Developer role or higher |
| `NOTARY_KEY_ID` | Its key ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown next to the key |

## License

[MIT](LICENSE)
