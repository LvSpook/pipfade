# DESIGN.md

The visual system for pipfade's own surfaces: the settings panel, the hover bar,
and the repository's docs. The app UI is drawn in GDI+ inside `pipfade.ps1`; the
docs are static HTML/SVG. Both use the same tokens, so the screenshots in the
README and the page that hosts them never disagree.

## World

One idea, applied everywhere: **a frame that dissolves towards its right edge.**
It is what the app does to your mini player, drawn as a shape. The icon, the
panel header mark, the hover bar's rail, and the banner are all renditions of
that single form at different sizes — see `Mark.PaintFrame` in `pipfade.ps1`.

Restraint is the point. The product sits on top of video someone is watching, so
its own interface never competes: no hue, no glow, no ornament beyond one soft
light source. Emphasis comes from brightness and weight only.

## Tokens

| Token | Value | Used for |
| --- | --- | --- |
| `Bg` | `#0C0C0D` | Panel background, page background (dark) |
| `Surface` | `#171718` | Wells, readout boxes, card fill |
| `Line` | `#2A2A2C` | 1px borders, the panel's outer stroke |
| `Track` | `#333336` | Slider rail, switch track (off) |
| `Text` | `#F5F5F6` | Primary labels, values |
| `Muted` | `#ABABAF` | Secondary text, preset summaries |
| `Accent` | `#F0F0F2` | Switch on, knob, active tab underline |
| `Hint` | `#8E8E93` | Secondary text, units, disabled menu items |

Light taskbar / light theme inverse: `#FAFAFA` background, `#0D0D0F` text,
`#6B6B70` secondary, `rgba(0,0,0,.12)` lines.

## Type

Segoe UI throughout, because it is the Windows system face and the app already
inherits it at every size.

| Role | Size / weight |
| --- | --- |
| Wordmark | 76–84px, 700, `letter-spacing: -2` |
| Section heading | 15px, 600 |
| Control label | 9pt, 400 |
| Value readout | 15pt, 600 |
| Unit / hint | 8.5pt, 400 |

## Geometry

- Corner radius 12 on the panel (matching DWM's own rounding), 8 on wells, 3 on
  the slider knob.
- Panel is 360×470, fixed: one size holds every row and a tab strip, so there
  are no drag edges to find and no size to remember. A field that still clips
  says the rest of itself in a dark tip after half a second of hover.
- The hover bar is 240–386 wide and 34 tall, always 10px inside the player's top
  edge. Inside the panel the content column is 324px wide, and both the Keys and
  Presets tabs split it between a measured label/name column and a binding box
  wide enough for a four-modifier combination.
- The bar sits in the same topmost band as the player, so it re-asserts its place
  after anything raises the player above it. That is a z-order rule, not a visual
  one, but it is what makes the bar's targets feel like targets.
- Every pixel of the bar answers the mouse. A per-pixel layered window passes
  clicks through whatever it leaves transparent, so the bar paints a one-alpha
  plate under its controls; the gaps between them are targets, not holes onto
  the video.
- No polling for the pointer. The resident loop sleeps on the message queue, and
  a native watch reports the pointer arriving on a player and leaving it, so a
  still pointer costs nothing and an arriving one is seen within 25ms.
- 18px page margin, 8px vertical rhythm between switch rows (28px rows).
- One-pixel strokes, never two: a doubled edge reads as a seam.

## Motion

Two durations only. `120ms` for a hover or press acknowledgment, `260ms` for the
bar fading in and out. No easing curves beyond ease-out; nothing bounces, because
a control surface over video should feel like a pane of glass, not a toy.

## Bans

- No accent colour. A single hue anywhere in this UI would pull the eye off the
  video, which is the one thing the app exists to disappear behind.
- No drop shadows on flat surfaces. Depth is a border and a fill step.
- No icon style other than the outlined frame and the four filled glyph buttons.
- No stock photography, screenshots-as-decoration, or gradient meshes in docs.
