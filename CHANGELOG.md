# Changelog

All notable changes to pipfade are recorded here. The project follows
[Semantic Versioning](https://semver.org/).

## What's New in v1.2.0

A size that remembers what the video looks like, and a quiet word when there is
a newer version.

### Size and position

- **A remembered size no longer forces an old shape onto a new video.** The
  window belongs to the browser, and the browser shapes it to the video it is
  showing, so a rect saved from a wide video applied to a tall one left black
  bars down the sides. Position is still restored every time; the size is only
  applied when the shapes agree to within 2%, and otherwise the player keeps its
  own proportions and is centred on the spot you left it.
- **A restored window cannot land off the screen.** Centring a window that grew
  past the edge the old one sat against could hang it a hundred pixels outside
  the desktop, so the result is pulled back inside the virtual screen.

### The update notice

- **A row at the bottom of the panel says when there is a newer version**, with a
  Download link that opens the release page — the notes first, then the archive.
  The row only exists when there is news; when you are current it is not there at
  all, and neither is the space it would have taken.
- **One check per launch, and nothing else.** A single read-only request for the
  latest release tag, off the main thread, with an eight-second timeout. Nothing
  is downloaded, nothing is installed, and a failure — offline, GitHub down, rate
  limited — says nothing at all. The app makes no other network request.

## What's New in v1.1.0

The bar became pressable, the panel stopped moving, and leaving the app running
stopped costing anything.

### The hover bar

- **Every pixel answers the mouse.** A per-pixel layered window passes the mouse
  through whatever it leaves transparent, and the bar only painted its controls -
  so the gaps between them dropped your press onto the video, which in a mini
  player toggles playback. A near miss felt like the wrong button. The whole body
  of the bar is a target now, and the four icon columns are contiguous for the
  full height of the bar instead of 24px boxes whose slack overlapped.
- **It stays above the player.** The bar was placed once and left in the topmost
  band, so raising the player buried it: still visible on screen, no longer
  clickable, until it was hidden and shown again. It now puts itself back above
  the player whenever the player is raised over it.
- **Almost no idle cost.** The resident loop used to wake four times a second to
  decide that nothing had happened, and the message check answered "input" from
  flags a dispatched message had already consumed, so it came back early nearly
  every time. The wait is one native call now, a peek decides whether a message is
  real, the pointer watch reports only arrivals and departures, and the backstop
  sweep runs every three seconds. 107 of 120 measured seconds sit at exactly zero
  CPU; the average over the whole run is under 0.7% of one core.

### The panel

- **One fixed size.** 360×470, and it stays there, so nothing moves under the
  pointer between visits. A binding or a preset name too wide for its box shows the
  rest of itself in a tip when you hover over it.
- **The tray menu is dark**, so it does not arrive as a scrap of the light system
  theme on a dark taskbar.

### Honest limits

- The frame lock cannot stop another program moving its own window. It puts the
  player back the moment it moves.

## What's New in v1.0.0

The first release. Everything below is what that means in practice.

### The mini player

- **Opacity from Windows itself.** The mini player is a native window, not a web
  page, so it is faded with a layered-window attribute rather than by styling
  anything. Any level from 16% to solid.
- **Automatic on open.** A saved level is applied to every new player the moment it
  appears, and to players that were already open when pipfade started.
- **Remembers size and position.** Each player has its own saved geometry, so two
  players at once are two separate layouts.
- **Frame lock.** Holds the player where it is and puts it back if something moves
  it. Per window, so one player can be locked while the other is free.
- **Click-through.** Clicks pass through the player to the window behind it.

### The interface

- **Three-tab panel.** Controls, Hotkeys and Presets, in one small monochrome
  window with no title bar.
- **Resizable.** Grab any edge or corner. The size and position are remembered, and
  the contents keep a readable column in the middle instead of stretching a label
  and its switch to opposite sides of a very wide window.
- **Type an exact percentage.** Click the big number in the panel, or the percentage
  on the hover bar, and type the value you want.
- **Thirteen rebindable hotkeys**, recorded by pressing the combination rather than
  typing its name.
- **Four presets**, each holding every setting the panel can change and each with an
  optional shortcut.
- **Hover bar.** Percentage, slider and four buttons inside the player, fading in
  when you point at it and never taking focus.

### Living on the desktop

- **Tray icon** that survives an Explorer restart.
- **Own taskbar button and icon**, rather than being folded into the PowerShell one.
- **Starts with Windows**, with no console flash.
- **Remembers the panel's own size and position**, clamped to the screen so it can
  never reopen somewhere unreachable.
- **Escape closes the panel**, and it comes back where you left it.

### Honest limits

- The frame lock cannot stop another program moving its own window. It puts the
  player back the moment it moves.
- A game in exclusive fullscreen cannot be drawn over by any normal window.
- Keypad digits cannot take Shift while NumLock is on, because Windows turns that
  into the arrow key first. The recorder refuses the combination instead of storing
  one that would never fire.
- Windows only.
