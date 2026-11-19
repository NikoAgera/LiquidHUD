# LiquidHUD

**A see-through system monitor widget and game overlay for Windows, built from scratch with nothing but PowerShell and WPF.**
No Rainmeter, no HWiNFO, no installer, no admin rights. One `.ps1` file.

![LiquidHUD on the desktop: widget and overlay bar in the Outline look](docs/images/hero.png)

> Images in this README are rendered previews of the UI.

---

## Features

| | |
|---|---|
| **Live stats** | CPU, GPU, RAM, **every disk in your PC**, network up/down, battery, uptime, top CPU app, top RAM app, clock |
| **60-second graph** | CPU and GPU history |
| **Two looks** | **Outline** (text + frame, see straight through) or **Solid** (filled + frame), for both the widget and the overlay |
| **Pick what's on screen** | Big widget, game overlay, or both |
| **Game overlay** | Thin click-through bar that stays on top of every app, on every monitor |
| **Global hotkeys** | Work while you're in a game |
| **Pin or free-move the overlay** | Pin it to any corner or the top center, or drag it anywhere and lock it there |
| **Pick your metrics** | Tick what you want to see. Unticked metrics aren't collected at all |
| **Lightweight** | Runs at BelowNormal priority with a 2 s refresh and periodic memory trim |
| **Status pill** | Shows `chill` below 40 % CPU, `busy` from 40–85 %, and `hot!` above 85 % (numbers also turn red) |

![Outline look vs Solid look, widget and overlay](docs/images/looks.png)

---

## Requirements

- **Windows 10 or 11.**
- **Windows PowerShell 5.1.** It's already built into Windows, so you don't need to install anything.

---

## Install (step by step)

### Step 1: Download

Pick **one**:

- **Easiest:** click the green **Code** button at the top of this page, then **Download ZIP**.
- **With git:**
  ```powershell
  git clone https://github.com/NikoAgera/LiquidHUD.git
  ```

### Step 2: Unzip

Right-click the ZIP, choose **Extract All…**, and pick a permanent spot, for example:

```
C:\Users\<you>\Documents\LiquidHUD
```

> Don't run it from inside the ZIP or from the Downloads folder if you plan to use *Start with Windows*. The startup shortcut points at the file's location.

### Step 3: Unblock the files (one time)

Windows marks downloaded files as "from the internet". To clear that mark, open PowerShell in the folder and run:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

Or right-click `LiquidHUD.ps1`, choose **Properties**, tick **Unblock**, then click **OK**.

### Step 4: Run it

Double-click **`Start-LiquidHUD.bat`**.

The widget appears in the top-right of your screen. The `.bat` launches PowerShell hidden, with `-ExecutionPolicy Bypass` for this one script only, so your system's execution policy isn't changed.

<details>
<summary>Prefer to run it manually?</summary>

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\LiquidHUD.ps1
```
</details>

### Step 5: Make it yours

- **Drag** the widget anywhere. Its position is remembered.
- **Right-click** the widget and choose **Settings**, or press `Ctrl+Alt+S`.
- **Right-click** the widget and choose **Start with Windows** if you want it on every boot.

---

## Settings

![Settings window and right-click menu](docs/images/settings.png)

| Setting | What it does |
|---|---|
| **Show** | Tick **Big widget** and/or **Game overlay**. If both are off, press `Ctrl+Alt+S` to come back |
| **Look** | **Outline**: text and a frame only, you see straight through to what's behind. **Solid**: text on a fully coloured background with a frame |
| **Overlay position** | Top left, Top center, Top right, Bottom left, Bottom right, or Custom (where you last dropped it) |
| **Free move** | Tick it, then drag the overlay anywhere (it gets a dashed outline). Untick it and the overlay locks in place and goes back to click-through, so it never blocks what's behind it |
| **Disks** | Every ready fixed or removable drive is listed with its label and size. Tick the ones you want on the widget. New drives show up the next time you open Settings |
| **What to monitor** | Tick a metric to show and collect it. Untick it to hide it and stop collecting it |
| **Refresh rate** | 1 s, 2 s or 5 s. Slower uses less CPU |
| **LiquidHUD itself is using** | Live RAM and CPU used by the widget itself |


Settings are saved to `%APPDATA%\LiquidHUD\settings.json`.

---

## Game overlay

![Outline overlay free-moved under the browser's address bar](docs/images/browser.png)

1. Press **`Ctrl+Alt+O`** to turn the overlay on.
2. Press **`Ctrl+Alt+P`** to cycle its pinned position: top left, top center, top right, bottom left, bottom right, custom.
   - **Or put it anywhere:** press **`Ctrl+Alt+M`** (or tick **Free move** in Settings), drag the bar where you want it, then press `Ctrl+Alt+M` again to lock it. Its spot is saved as a fraction of the screen, so it lands in the same place on every monitor.
3. Press **`Ctrl+Alt+H`** to turn the big widget off so only the overlay stays (or untick **Big widget** in Settings).
4. If the bar sits over something you need to see, like browser tabs, use the **Outline** look and/or **Free move** it out of the way.

When it's locked, the overlay is **click-through**: your mouse goes straight to the game, and it never steals focus or shows up in Alt+Tab.

> **Important:** set your game's display mode to **Borderless** or **Windowed Fullscreen**. In **Exclusive Fullscreen** the game takes over the whole display and no overlay can draw on top. That's a Windows limit, not a bug in LiquidHUD.

**Anti-cheat:** LiquidHUD is a plain top-most window. It doesn't inject into, hook or read from any game process. It only reads the same public Windows counters that Task Manager uses.

---

## Hotkeys

| Keys | Action |
|---|---|
| `Ctrl+Alt+S` | Open Settings |
| `Ctrl+Alt+O` | Toggle game overlay |
| `Ctrl+Alt+P` | Cycle overlay position |
| `Ctrl+Alt+M` | Free move overlay on/off (drag it, then press again to lock) |
| `Ctrl+Alt+H` | Big widget on/off |
| Double-click widget | Open Task Manager |
| Right-click widget | Menu |

---

## How it works

```
+------------------------------+       synchronized        +-------------------------+
|  Background runspace         |        hashtable          |  UI thread (WPF)        |
|  BelowNormal priority        |  ---------------------->  |  DispatcherTimer        |
|                              |                           |                         |
|  PerformanceCounter (CPU,GPU)|                           |  Widget window          |
|  ComputerInfo (RAM)          |                           |   (Outline / Solid)     |
|  DriveInfo (all disks)       |                           |  Overlay window(s)      |
|  NetworkInterface (net)      |                           |   (layered, click-thru) |
|  PowerStatus (battery)       |                           |  Settings window        |
|  Process list (top apps)     |                           |                         |
+------------------------------+                           +-------------------------+
```

- **Windows:** per-pixel-alpha (layered) WPF windows. In the Outline look the widget keeps a 1 % fill so you can still grab it and drag it, and the text gets a soft shadow so it stays readable on any wallpaper.
- **Overlay:** a layered window with the extended styles `WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`. LiquidHUD calls `SetWindowPos(HWND_TOPMOST)` every tick so the overlay stays on top.
- **Hotkeys:** `RegisterHotKey` on a hidden message window.
- **Low cost:**
  - The data collection runs on its own thread at BelowNormal priority.
  - GPU counters are created only when GPU is ticked, and refreshed every 30 s.
  - The process scan for top apps runs every 5 s, and only when one of those metrics is ticked.
  - Text only re-renders when it changes, and bars only animate when their value changes.
  - The working set is trimmed every 60 s.

### Expected resource use

These are estimates. Open **Settings** to see the live numbers on your machine.


| | |
|---|---|
| CPU | ~0.1–0.5 % at a 2 s refresh |
| RAM | ~50–80 MB. This is mostly the PowerShell and WPF runtime itself, so it's the practical floor for a script-based app |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| **Nothing happens** when I double-click the `.bat` | Run Step 3 (Unblock). Then try the manual command from Step 4 in a PowerShell window so you can see any error |
| **I want to quit, but nothing is on screen** | Press `Ctrl+Alt+S` for Settings, or `Ctrl+Alt+H` to show the widget, then right-click and choose **Exit**. Or open Task Manager and end **Windows PowerShell** |
| **GPU shows `n/a`** | Your GPU driver doesn't expose the `GPU Engine` counters. Update your graphics driver |
| **The overlay hides tabs or buttons behind it** | Switch **Look** to **Outline**, or turn on **Free move** (`Ctrl+Alt+M`) and drag it somewhere empty |
| **Overlay not visible in a game** | Switch the game to Borderless or Windowed Fullscreen |
| **The overlay is in the wrong spot on a second monitor** | Mixed DPI scaling across monitors can offset it. Untick **Overlay on all monitors** to keep it on the main screen |
| **I want to reset everything** | Delete `%APPDATA%\LiquidHUD\settings.json` |

---

## Uninstall

1. Right-click the widget and choose **Exit**.
2. If you turned on **Start with Windows**, delete `LiquidHUD.lnk` from `shell:startup` (press `Win+R`, type `shell:startup`, press Enter).
3. Delete the LiquidHUD folder and `%APPDATA%\LiquidHUD`.

---

## Not included (yet)

- **CPU/GPU temperature.** Windows doesn't expose it without a kernel driver or admin rights.
- **Game FPS.** Measuring FPS needs hooking into the game, which this project deliberately avoids.

---

## License

[MIT](LICENSE). Do whatever you like with it.

---

## Changelog

| Version | What changed | Issues |
|---|---|---|
| **v7** | Clear rendering only: Acrylic, Mica and the background sliders are removed. Added the **Outline / Solid** look and **Show** toggles for the widget and the overlay | #5, #6, #7 |
| v6 | Every disk detected with a tick box each. Overlay can be pinned or free-moved. Faint box kept at 0 % | #2, #3, #4 |
| v5 | Clear style with real transparency | #1 |
| v4 | Settings window, metric picker, refresh rate, resource savings | |
