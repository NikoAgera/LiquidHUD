# LiquidHUD roadmap

Ideas to build next. Each one has a GitHub issue labelled [`roadmap`](https://github.com/NikoAgera/LiquidHUD/labels/roadmap), where we discuss it before building.

## 1. Big widget enhancements ([#28](https://github.com/NikoAgera/LiquidHUD/issues/28))
- [ ] Same look options as the overlay: adaptive text (black on bright, white on dark), plus auto-hide or peek
- [ ] Compact / mini layout (CPU, GPU, RAM and the graph only)
- [ ] Choose the graph contents (CPU + GPU, CPU + RAM, network)
- [ ] Per-disk read/write speed, not just used space
- [ ] Bigger graph, or a 5-minute history
- [ ] Click a top app to open it in Task Manager
- [ ] Snap to screen edges and corners while dragging
- [ ] Temperatures (need a driver or admin rights, so check what's possible first)

## 2. Optional animations ([#29](https://github.com/NikoAgera/LiquidHUD/issues/29))
**Off by default.** Layered windows redraw completely on every animation frame, which costs CPU.
- [ ] Overlay slides out of the thin bar on hover (not only a fade)
- [ ] Bars ease to new values (disabled in v12 for performance)
- [ ] Numbers count up and down smoothly
- [ ] Status pill pulses on `hot!`
- [ ] Graph line draws in smoothly
- [ ] Setting: *Off / Subtle / Full*, with the CPU cost shown live in Settings

## Done
See the changelog in the [README](README.md#changelog).
