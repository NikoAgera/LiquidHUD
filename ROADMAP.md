# LiquidHUD roadmap

Ideas to build next. Each one has a GitHub issue labelled [`roadmap`](https://github.com/NikoAgera/LiquidHUD/labels/roadmap), where we discuss it before building.

## Optional animations ([#29](https://github.com/NikoAgera/LiquidHUD/issues/29))
**Off by default.** Layered windows redraw completely on every animation frame, which costs CPU.
- [ ] Overlay slides out of the thin bar on hover (not only a fade)
- [ ] Numbers count up and down smoothly
- [ ] Mini graph draws in smoothly
- [ ] CPU/RAM value pulses when it goes red (over 85 %)
- [ ] Setting: *Off / Subtle / Full*, with the CPU cost shown live in Settings

## Maybe later
- [ ] More tray-icon info: a tiny live CPU meter drawn inside the icon
- [ ] Per-game profiles (a different position or metrics when a specific game is in front)
- [ ] Temperatures (need a driver or admin rights, so check what's possible first)

## Dropped
- ~~Big widget enhancements (#28)~~: the big widget was removed in v13 (#31). LiquidHUD is overlay-only now.

## Done
See the changelog in the [README](README.md#changelog).
