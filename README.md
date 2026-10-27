<p align="center">
  <img src="./resources/Assets.xcassets/AppIcon.appiconset/icon.png" width="128" alt="">
</p>

<h1 align="center">nanopress</h1>

<p align="center">A tiling window manager for macOS that you use with the mouse.</p>

<p align="center">
  <img src="./docs/readme/drag-and-drop.gif" width="720" alt="Dragging Ghostty over Dia: the half of Dia under the cursor turns blue, then the windows move into place">
</p>

nanopress keeps your windows side by side, so none of them hides another. To move a window, drag it by its title bar over another one: the part under the cursor turns blue and says where yours goes.

It's a fork of [AeroSpace](https://github.com/nikitabobko/AeroSpace). AeroSpace's keyboard shortcuts, commands and config file all still work.

## Arrange from the menu bar

<p align="center">
  <img src="./docs/readme/menu-bar-panel.gif" width="720" alt="The nanopress panel opens from the menu bar. Ghostty's tile is dragged next to Dia in the minimap and the real windows follow, then Slack's tile is dropped on workspace 2">
</p>

You don't have to push big windows around to arrange a workspace. Click the nanopress icon in the menu bar for a minimap of your screen and arrange it there: drag tiles to move windows, drag the gaps to resize, drop a tile on a workspace number to send the window there. The screen shows each change at full size before you let go. Below the minimap, Auto-arrange suggests a few roomy layouts, with windows of a kind, like browsers or terminals, stacked together.

## Install

```sh
brew install --cask emrecaglarid/tap/nanopress
```

Open nanopress from Applications and give it Accessibility access when macOS asks. It needs that to move windows.

You can also download it from [Releases](https://github.com/emrecaglarid/nanopress/releases). nanopress isn't notarized by Apple yet, so a downloaded copy needs one extra step: open it once, then go to System Settings ▸ Privacy & Security and click Open Anyway.

## Moving windows

Drag a window by its title bar over another window. Arrows show its four sides and a box in the middle says Stack and Swap:

| Where you drop | What happens |
| --- | --- |
| Toward a side | Splits that window, yours goes on that side |
| Stack | Puts the two windows in one spot, with tabs |
| Swap | The two windows trade places |

When there's more than one way to split, press Tab while still holding the mouse to switch between splitting the window, its column, or the whole screen. Esc puts the window back where it was.

## Stacks

<p align="center">
  <img src="./docs/readme/stack-tabs.gif" width="720" alt="A stack of Slack, Mail and Notes with a strip of tabs under it: clicking a tab brings that window forward, and + brings Ghostty in from another workspace">
</p>

Windows that share a spot get a strip of tabs under them, with the window in front highlighted. Click a tab to bring its window forward, scroll over the tabs to flip through them, or drag a tab away to give that window its own spot. "+" lists your other windows, minimized ones too, to bring one into the stack. A dot on a tab means the app has unread items.

## Also

- Resize a window over its neighbour to stack them; shrink a stacked window from a free edge to take it out.
- Double-click a title bar to give a window the whole screen, and again to bring your layout back.
- New windows open where you last put that app, and stack once the screen is full.
- Changes nanopress makes on its own come with Undo.
- Each display setup keeps its own layout. With nothing saved yet, nanopress starts from an auto-arranged one.
- Apps you don't want tiled, like Finder, can float. See Settings.
- AI agents that speak MCP can arrange your windows too, if you turn it on in Settings. I'm still working out what for.

## Keyboard and config

The config file is `~/.nanopress.toml` or `~/.config/nanopress/nanopress.toml`. Without one, nanopress reads your AeroSpace config. [AeroSpace's guide](https://nikitabobko.github.io/AeroSpace/guide) explains workspaces, key bindings and commands; use `nanopress` where it says `aerospace`.

## Building

With macOS and Swift 6:

```sh
swift build
.build/debug/NanopressApp
```

## Credits

nanopress is made by Emre Caglar, on [AeroSpace](https://github.com/nikitabobko/AeroSpace) by Nikita Bobko. You can [sponsor AeroSpace](https://github.com/sponsors/nikitabobko).

MIT licensed. See [LICENSE.txt](./LICENSE.txt) and [legal/](./legal).
