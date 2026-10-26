<img src="./resources/Assets.xcassets/AppIcon.appiconset/icon.png" width="128" align="right" alt="">

# nanopress

Tiling for the rest of us.

Tiling window managers keep every window in view and nothing on top of anything else, but most of them assume you'll learn a page of keyboard shortcuts first. nanopress is a tiling window manager for macOS that you use with the mouse. Drag a window where you want it, see the result before you let go, and nanopress keeps everything tidy from there.

It's a fork of [AeroSpace](https://github.com/nikitabobko/AeroSpace), so the tiling engine underneath is fast and proven, and keyboard users keep all of it.

<img src="./design/preview.png" alt="Dragging a window below another: the landing slot is highlighted in blue, the windows that move are outlined, and a card says what the drop does">

## What it does

**Drag and drop with a preview.** Drag any window by its title bar. Before you let go, nanopress shows where it lands and which windows move to make room. Near an edge of another window, it splits; in the middle, it stacks; hold ⌥ to swap. Press Tab mid-drag to choose between splitting a window, its column, or the whole screen.

**Stacks with tabs.** When windows share a spot, they get a row of tabs, like a browser. Click a tab to bring its window forward, scroll over the tabs to flip through them, drag a tab out to give the window its own tile. "+" brings in any other window, even a minimized one. Apps with unread messages show a dot on their tab.

**A map of your screen in the menu bar.** Open nanopress from the menu bar to see every window as a tile. Drag tiles to rearrange, drag the gaps to resize, drop a window on a workspace number to move it there.

**Auto-arrange.** Pick how many windows you want to see and nanopress suggests layouts, sized for what each app needs. Rest the pointer on one to try it on your real windows.

**It guesses what you mean.**
- Resize a window over its neighbour, and they become a stack. Shrink a stacked window from a free edge, and it gets its own tile again.
- Double-click a title bar, and the window gets the whole screen while the others wait as tabs. Double-click again, and your layout comes back.
- New windows open where you last put that app. When the screen is full, they stack instead of shrinking everything.
- When a window closes, the window that was stacked to make room gets its tile back.
- Every change nanopress makes on its own shows a note with Undo.

**Fits your desk.** nanopress remembers a layout for each display setup: laptop alone, laptop with a monitor, and so on. Unplug a screen and its windows join the one you're on. A laptop screen never gets more tiles than it can show.

**Your apps, your rules.** Apps you don't want tiled, like Finder, float on top. Pick a background that makes windows stand out, or keep your wallpaper.

**Works with your AI agent.** Turn on Agents in Settings, and Claude or any other agent that speaks MCP can see your windows and arrange them: "put my editor on the left and stack the chats on the right". Agents only see window titles if you let them.

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask emrecaglarid/tap/nanopress
```

Then open nanopress from Applications. macOS asks for Accessibility access, which nanopress needs to move windows.

You can also download it from [Releases](https://github.com/emrecaglarid/nanopress/releases). nanopress isn't notarized by Apple yet, so a downloaded copy needs one extra step: open it once, then go to System Settings ▸ Privacy & Security and click Open Anyway. Homebrew takes care of that for you.

To build it yourself, you need macOS and Swift 6:

```sh
swift build
.build/debug/NanopressApp
```

## For keyboard users

Everything AeroSpace can do still works: workspaces, key bindings, the `nanopress` command line tool and the config file at `~/.nanopress.toml` or `~/.config/nanopress/nanopress.toml`. If you have neither, nanopress reads your AeroSpace config, so your shortcuts come along. [AeroSpace's guide](https://nikitabobko.github.io/AeroSpace/guide) covers all of it; read `aerospace` as `nanopress`.

## Credits

nanopress is made by Emre Caglar, on top of [AeroSpace](https://github.com/nikitabobko/AeroSpace) by Nikita Bobko. If nanopress is useful to you, consider [sponsoring AeroSpace](https://github.com/sponsors/nikitabobko).

MIT licensed. See [LICENSE.txt](./LICENSE.txt) and [legal/](./legal).
