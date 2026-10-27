# Looks

A look is the appearance of Vizpr's overlay: the pane that shows the transcript while you dictate, and the small pill that shows in inviz mode. This folder holds the whole looks engine (the model, the file loader, and the drawing code) and the three looks that ship with the app. This guide is written for a Claude working in a user's checkout of Vizpr. Follow the recipe below to make a new look by editing parameters; you do not need to change any Swift.

## What a look is

A look is one JSON file. The app loads every `.json` file in the Looks folder at launch and again when the user presses Reload Looks in Settings, Appearance.

| Built-in look | File | What it shows |
|---|---|---|
| Glass | `BuiltIn/glass.json` | Every parameter at its default: system glass with a light purple tint at 0.13 strength. The other looks differ from it. |
| Slab | `BuiltIn/slab.json` | A dark animated nine-color mesh instead of glass, light text, a soft top-edge light, a bevel, fine grain and a drop shadow. |
| Liquid Glass | `BuiltIn/liquid-glass.json` | The clear glass variant with no frost, a dim backdrop behind it so text stays legible, and light text. |

The built-in files are reference copies to start a new look from. The app draws the built-ins from constants in `OverlayLook.swift` and never reads these files, so editing one changes nothing in the app and fails the test that checks each file against its constant. A custom look cannot reuse a built-in `id`; the app skips such a file.

## Where custom looks go

`~/Library/Application Support/Vizpr/Looks/`. The app is not sandboxed, so this is the same path for a build from source and a packaged build. Settings, Appearance has an Open Looks Folder button that creates the folder and opens it. A git pull cannot touch this folder.

Files load in file-name order, compared character by character, so capital letters sort before lowercase; use lowercase file names to keep the order alphabetical. At most 12 custom looks load. A file past the twelfth is reported as over the limit and ignored until another is removed.

## Recipe for a new look

1. Copy `Vizpr/Looks/BuiltIn/glass.json` (or the built-in closest to what the user wants) into the Looks folder under a new name, for example `sunset.json`.
2. Replace `id` with a new UUID from `uuidgen`. Every look needs its own; two files with the same `id` load only the first.
3. Replace `name`. It is the label in the Appearance list and the menu bar, truncated to 40 characters.
4. Change parameters from the table below. A file may also be partial: it needs only `id`, `name` and the fields that differ, and every missing field takes its default. When the look is next edited in the Appearance pane, the app writes every field in full, with any out-of-range value replaced by its clamped value.
5. Save the file in the Looks folder and press Reload Looks (or relaunch), then pick the look in Settings, Appearance.

A hand-edited file needs Reload Looks before the next edit in the Appearance pane. The app holds each look in memory, and an edit in the pane rewrites the active look's file from that copy, so a hand edit that was never reloaded is overwritten.

## How a bad file is handled

| Problem in the file | What happens |
|---|---|
| A number outside its range | The value is clamped to the nearest end of the range. |
| A color that is not six hex digits | The field takes its default. A leading `#` and surrounding spaces are accepted. |
| An unknown enum value (`"surface": "metal"`), a wrong-typed field, invalid JSON, or a missing `id` or `name` | That one file is skipped. Settings, Appearance shows how many files could not be read and a Reveal button that selects them in Finder; the reason is written only to the dev log of a Debug build. To find the problem, check that the file is valid JSON and that every enum value and type matches the table below. Other files and all other settings are unaffected. |
| A key the app does not know | It has no effect, and the app removes it the next time it saves the look from the Appearance pane. |

## Parameters

Colors are six-digit hex strings such as `"A16FDF"`. All ranges are enforced by the app. Fields are nested exactly as in `BuiltIn/glass.json`: `style.light.sheen` is the `sheen` key inside `light` inside `style`.

### Identity and body

| Field | Type, range, default | Visible effect |
|---|---|---|
| `id` | UUID string, required. | Identity for selection. Must be unique and must not be a built-in id (`6B1E5A4C-0D2F-4C8E-9A57-3F1B7D20A001` to `...A003`). |
| `name` | String, required, up to 40 characters. | The label in the Appearance list and in the menu-bar item "Look: name". |
| `surface` | `glass`, `slab` or `solid`; default `glass`. | The body of the pane: system glass, the animated nine-color mesh, or a flat fill. |
| `cornerRadius` | 8 to 40; default 22. | Rounds every layer: surface, backdrop, light, border, glow, shadow and the text clip. |
| `tintHex` | Hex; default `A16FDF`. | Tints glass at `tintStrength`. Also colors the recording dot when `style.dot.colorHex` is absent, the three inviz dots, and the swatch in the Appearance list, on every surface. |
| `tintStrength` | 0 to 0.5; default 0.13. | Opacity of the tint over the glass. Glass only. |
| `textBaseHex` | Hex or absent; default absent. | Settled text color. Absent means the system label colors, which follow light and dark mode. Set it when the pane is dark in light mode. |
| `colorsLinked` | `true` or `false`; default `false`. | When `true` the text color is the tint and `textBaseHex` is ignored. |
| `fontDesign` | `rounded`, `standard`, `serif` or `monospaced`; default `rounded`. | The system font design. Ignored when `style.text.fontFamily` names an installed family. |
| `fontSize` | 12 to 28; default 16. | Transcript font size. Also sets the pane height. |
| `wordAppearance` | `instant`, `fade` or `blurIn`; default `instant`. | None. Reserved for a later release. |

### Glass (`style.glass`, `style.fill`)

| Field | Type, range, default | Visible effect |
|---|---|---|
| `style.glass.variant` | `regular` or `clear`; default `regular`. | Glass surface only. `regular` is the standard system glass. `clear` is the more transparent system variant, which needs a dim `style.backdrop` behind it to keep text legible. Below macOS 26 the value is ignored. With Reduce Transparency on, `clear` draws as `regular`. |
| `style.fill.frost` | 0 to 1; default 0. | Glass: how much `fill.colorHex` covers the material (0 is bare glass, 1 is opaque). Solid: the fill opacity, with a floor of 0.05. Slab: unused. |
| `style.fill.colorHex` | Hex; default `1C1828`. | The frost color for glass and the fill color for solid. |

### Slab mesh (`slab`)

| Field | Type, range, default | Visible effect |
|---|---|---|
| `slab.meshColorsHex` | Array of exactly nine hex colors, row by row; default nine dark purples. | Colors of the 3 by 3 mesh. Any other count, or an invalid entry that brings the count below nine, resets all nine to the default. |
| `slab.meshDrift` | 0 to 0.5; default 0.06. | How far the interior mesh points wander, as a fraction of a cell. |
| `slab.meshLoopSeconds` | 2 to 60; default 40. | Seconds per drift loop. |

### Backdrop (`style.backdrop`)

| Field | Type, range, default | Visible effect |
|---|---|---|
| `enabled` | `true` or `false`; default `false`. | Turns on a dimming layer drawn behind the surface. |
| `colorHex` | Hex; default `000000`. | Color of the dimming layer. |
| `strength` | 0 to 0.9; default 0.45. | Opacity of the layer inside the pane. |
| `feather` | 0 to 60 points; default 16. | Distance past the pane edge over which the layer fades out. When the backdrop is on, it also sets the panel margin, at 1.1 times the feather. |

### Light (`style.light`)

| Field | Type, range, default | Visible effect |
|---|---|---|
| `edgeLight` | 0 to 1; default 0. | Soft white light falling from the top edge. |
| `bevel` | 0 to 1; default 0. | A lighter top edge and a darker bottom edge inside the border. |
| `gloss` | 0 to 1; default 0. | A still elliptical highlight across the top third. |
| `sheen` | 0 to 1; default 0. | Opacity of a diagonal band that sweeps across the pane and then rests. |
| `sheenSweepSeconds` | 1 to 30; default 6. | Seconds per sheen cycle. |
| `grain` | 0 to 0.2; default 0. | Film grain, re-rolled 24 times a second. |

### Border, glow and shadow

| Field | Type, range, default | Visible effect |
|---|---|---|
| `style.border.enabled` | `true` or `false`; default `false`. | Draws a stroke inside the pane edge. |
| `style.border.width` | 0.5 to 6; default 1. | Stroke width in points. |
| `style.border.colorHex` | Hex; default `FFFFFF`. | Stroke color. |
| `style.border.opacity` | 0 to 1; default 0.25. | Stroke opacity. |
| `style.outerGlow.enabled` | `true` or `false`; default `false`. | Draws a blurred halo outside the pane only. |
| `style.outerGlow.colorHex` | Hex; default `A16FDF`. | Halo color. It does not follow `tintHex`. |
| `style.outerGlow.radius` | 1 to 60; default 12. | Blur radius. Also sets the panel margin, at twice the radius. |
| `style.outerGlow.strength` | 0 to 1; default 0.5. | Halo opacity. |
| `style.dropShadow.enabled` | `true` or `false`; default `false`. | Draws a blurred, offset shadow outside the pane only. |
| `style.dropShadow.colorHex` | Hex; default `000000`. | Shadow color. |
| `style.dropShadow.radius` | 0 to 60; default 8. | Blur radius. Also adds to the panel margin. |
| `style.dropShadow.x`, `style.dropShadow.y` | -40 to 40; defaults 0 and 3. | Shadow offset. The larger absolute offset adds to the panel margin. |
| `style.dropShadow.opacity` | 0 to 1; default 0.25. | Shadow opacity. |

### Pane shape and text

| Field | Type, range, default | Visible effect |
|---|---|---|
| `style.pane.width` | 360 to 900; default 560. | Maximum reading width in points. Longer text wraps and the pane grows taller. |
| `style.pane.paddingHorizontal`, `style.pane.paddingVertical` | 4 to 48; defaults 18 and 12. | Space between the pane edge and the text. |
| `style.text.fontFamily` | String up to 100 characters, or absent; default absent. | A font family by name, from the system or the Fonts folder. See Fonts below. |
| `style.text.weight` | `light`, `regular`, `medium`, `semibold` or `bold`; default `regular`. | Font weight, on both the system font and a named family. |
| `style.text.lineSpacing` | 0 to 16; default 0. | Extra points between lines. |
| `style.text.glowEnabled` | `true` or `false`; default `false`. | Soft shadow behind the transcript text. |
| `style.text.glowColorHex` | Hex; default `FFFFFF`. | Color of that glow. |
| `style.text.glowRadius` | 0 to 20; default 4. | Blur radius of that glow. |

### Recording dot (`style.dot`)

| Field | Type, range, default | Visible effect |
|---|---|---|
| `colorHex` | Hex or absent; default absent. | Dot color. Absent uses `tintHex`. |
| `size` | 3 to 16; default 7. | Dot diameter in points. |
| `pulse` | `true` or `false`; default `false`. | A gentle opacity pulse, off under Reduce Motion. |

## Fonts

`style.text.fontFamily` takes a family name such as `"Avenir Next"`. It matches any installed font and any `.ttf`, `.otf` or `.ttc` file in `~/Library/Application Support/Vizpr/Fonts/` (Settings, Appearance, Open Fonts Folder, then Reload Fonts). A family that is not installed falls back to the system font with no message, so a look shared with someone who lacks the font still works but reads differently.

## What a file cannot do

| Limit | Detail |
|---|---|
| Add effects | The shader is compiled into the app. A file sets the six light inputs (`edgeLight`, `bevel`, `gloss`, `sheen`, `sheenSweepSeconds`, `grain`) and cannot add a new kind of light. A new effect is a change to `PaneLight.metal` and the Swift beside it. |
| Change the text-opacity ratio | Mutable (not yet settled) text is drawn at 0.55 of the settled text's opacity. This is the trust contract that keeps unsettled words visibly provisional, so a look can recolor the text and cannot flatten the difference. The constant is `OverlayLook.mutableOpacityRatio`. |
| Resize the inviz pill | In inviz mode the pill is 84 by 36 points and its three dots are 8 points, whatever the look says. |

## What inviz does with a look

Inviz shows a small pill in place of the transcript. It draws the look's surface, backdrop, light, border, glow and shadow on that 84 by 36 point pill, and colors its three dots with `tintHex`. It ignores the text, recording-dot and pane fields. A look with a 40-point `outerGlow.radius` therefore makes the glow dominate the small pill, and a `cornerRadius` above 18 is more than the pill's height allows. The Appearance preview shows the transcript only, so check a look in inviz mode on screen.

## Inputs the folder takes from the app

The model and drawing code in this folder read two values that live outside it:

| Input | Value | What the folder uses it for |
|---|---|---|
| `OverlayLayout.restingSize` | 220 by 44 points. | The smallest pane. `paneWidth(fitting:)` never goes below its width, and a short utterance rests at this size. |
| `TargetAppMetrics.cornerOverhang` | 5 points. | The least margin around the pane, so the target-app icon that hangs off the corner is never clipped. |

`LookFiles.swift` also uses `StorageRoot.url` for the folder's location, `VizprSettings.maxLooks` for the cap of 12, `SettingsMerge.merged` to lay a partial file over the defaults, and the Debug dev logger.

## Sharing a look

The file is the look. Send the JSON file; the recipient puts it in their Looks folder and presses Reload Looks. Give a shared look a fresh `id` if the recipient might already have a look with the same one.

## Where the code lives

| File | Job |
|---|---|
| `OverlayLook.swift` | The look model, its ranges, the built-in constants, hex cleaning and the text-opacity ratio. |
| `LookStyle.swift`, `SlabStyle.swift` | The nested parameter groups and their clamping. |
| `LookFiles.swift` | Reading, writing and reporting look files. |
| `PaneSurface.swift`, `SlabSurface.swift` | The pane body for each surface. |
| `PaneEffects.swift`, `BackdropLayer.swift`, `LightLayer.swift`, `PaneLight.metal` | Border, glow, shadow, backdrop and the light shader. |
| `Color+Hex.swift` | Hex string to color and back. |
| `BuiltIn/` | The three built-in look files. Compiled constants in `OverlayLook.swift` are the source of truth, and a test checks each file against its constant. |
