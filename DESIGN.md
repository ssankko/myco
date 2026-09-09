# Myco design guide

How the app looks and behaves on screen. `ARCHITECTURE.md` covers what is under it.

## Brand

- Pale mint `#C5F4D4` on deep forest `#173B30`. `Theme.brandMint` and `Theme.brandForest` carry them in code.
- The mark is the glyph in `Sources/Myco/Myco.svg`: fused sound bars, one shape. The app icon puts it in mint on a forest tile that fills 80% of the canvas. The menu bar and the popover header draw it as a template image, so it takes the colour of the text around it.

## Colour

Every colour has a light and a dark value and lives in `Sources/Myco/Theme.swift`. Views never name a colour of their own.

| Name | Meaning | Light | Dark |
|---|---|---|---|
| `signal` | Audio flows here. The one accent; every control that carries audio uses it. The accent chosen in System Settings, or with Multicolor the brand green: the forest hue at the saturation of the system accents, a step lighter by night. | `(0.16, 0.47, 0.37)` | `(0.20, 0.60, 0.48)` |
| `onSignal` | Text and glyphs on top of `signal`. | white | white |
| `caution` | Works, but look: underruns, an old driver. | `(0.72, 0.47, 0.06)` | `(0.95, 0.70, 0.25)` |
| `stopped` | Nothing flows: no driver, a dead device. | `(0.76, 0.25, 0.24)` | `(1.00, 0.45, 0.42)` |
| `danger` | A control that takes something away. Same red as `stopped`. | | |

Everything else is `primary` at an opacity: `track` 0.11 for dividers, `border` 0.22 around a small button, `rowFillHover` 0.06 under the pointer. A device that carries audio sits on `signal` at 0.08, lifted to 0.15 under the pointer.

## Type

The system font only. Sizes in points:

| Size | Use |
|---|---|
| 17 medium | The master readout |
| 13 semibold | The popover title |
| 12 | Section headings, the EQ window |
| 11 | Device names and controls |
| 10.5 | Captions, readouts, tooltips-in-place such as "Bluetooth" |
| 9 to 9.5 | Chips and tags |

Readouts are fixed width, fixed sign and fixed decimals, so a column of numbers scans without the digits jumping: `+0.0 dB`, `144.8 ms`, `88.2 kHz`. `Readout` in `Theme.swift` formats them.

## Layout

- The popover is 380 points wide, pinned to the top, and grows downward. Nothing animates when a row appears or changes size.
- A window the popover opens, the equaliser or the profiles, appears to the left of the popover with its top edge level, so the two never cover each other. The popover stays open while that window is used; a click in another app, or Escape, closes it.
- The profile chips sit right under the master, with no heading and no divider: the lit chip says which profile plays.
- Rows are 10 points apart, sections 14. A card has a radius of 8 and a padding of 8.
- A glyph button is 19 points high with a radius of 5, bordered in `border`, filled with `signal` and white on top while it is on. Under the pointer it takes `rowFillHover` and `borderHover`, or `signalHover` while on.
- The details of an output sit on one row: buffer picker, then sync trim and computed delay when outputs are aligned, then the latency and underrun readouts pushed right. They wrap under the controls only when they do not fit.

## Rules

- No explanatory text inside a row. A row is a name, its controls and its readouts. Anything that needs a sentence goes into a tooltip.
- A lit control means an active state, not an available one. EQ lights up only when its curve is not flat; the ear lights up only while a microphone is monitored.
- Controls that are set once and rarely, such as the fallback ring on an output, appear only under the pointer or while on.
- Clicking a device's name toggles it. Double-clicking a slider's readout resets it. Both are tooltips, not labels.
- The spinner in the header shows only while nodes really stop and start. A slider drag never shows it.
- Quit and Remove driver live in the status item's right-click menu, not in the popover.
- Numbers the user cannot act on stay out. Underruns show only when they are above zero.
