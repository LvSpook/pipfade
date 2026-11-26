# Changelog

All notable changes to pipfade are recorded here. The project follows
[Semantic Versioning](https://semver.org/).

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
