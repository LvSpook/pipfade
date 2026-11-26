# PRODUCT.md

> Written for the docs/README work on this repository. Every statement below is
> inferred from the code in `pipfade.ps1` and from the existing `README.md`,
> not from an interview. Anything I could not verify is marked **assumption**.

## What it is

pipfade makes the picture-in-picture ("mini player") window of Brave, Chrome and
Edge translucent on Windows. It also remembers each player's size and position,
reapplies the saved opacity whenever a player opens, keeps the player above
fullscreen apps, and adds a hover control bar inside the player.

## Why it exists

The mini player is a native OS window (`Chrome_WidgetWin_1`), not a web page, so
no browser extension or userscript can restyle it — they only reach web content.
pipfade works from the Windows side instead: `WS_EX_LAYERED` plus
`SetLayeredWindowAttributes`, driven from a single PowerShell script.

## Who it is for

One person, realistically: someone who watches video in a floating window while
working, and finds a solid black rectangle in the corner of the screen
distracting. **Assumption:** the audience is Windows users who are comfortable
running a script, not a mass-market installer audience.

## Product truths (verified in code)

- Ships as plain PowerShell 5.1+ with no installer, no dependencies, no account.
- Single instance (global mutex); one tray icon; one settings file next to the
  script (`pipfade.config.json`).
- Detection is event-driven (`SetWinEventHook`), with a one-second sweep as a
  backstop. It never touches ordinary browser windows or its own windows.
- Defaults: opacity 205/255, remember geometry on, apply on open on, always on
  top on, hover controls on, hide key toggles, frame lock off.
- Minimum opacity 40/255 (~16%) on purpose: an invisible window cannot be
  grabbed again.
- 13 configurable hotkeys, all Ctrl+Alt based, plus four preset slots.
- A frame lock exists, and is honest about its limits: it puts a moved window
  back rather than preventing the move.

## Constraints that shape the interface

- The app's own UI is monochrome by design: near-black surface, white text,
  emphasis from brightness and weight. It must never compete with the video.
- Windows only. WinForms + GDI+ drawing; no web UI in the product itself.
- The hover bar is a per-pixel layered window, so it has no child controls.

## Surfaces in this repository

| Surface | Mode | Notes |
| --- | --- | --- |
| `README.md` | Read | The front door on GitHub; house style shared with the author's other repos |
| `docs/index.html` | Read | Static project page on GitHub Pages |
| `pipfade.ps1` panel | Operate | Settings UI, drawn in GDI+ |
| `pipfade.ps1` hover bar | Operate | In-player control strip |

## Voice

Plain, specific, and honest about limits. British spelling in the app UI and
docs ("monochrome", "colour", "minimise"). No marketing superlatives; prefer
"here is what it does and what it cannot do".
