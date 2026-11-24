# SystemMonitor

An ultra-lightweight macOS menu bar plugin for **MenuBarPlugins** that displays live **CPU usage**, **RAM usage**, and **thermal throttling** status at **2 Hz** using custom gradient-filled monochrome icons.

## Features

- **Live Menu Bar Icons (CPU left, RAM right)**:
  - Converts the bundled PNG icons (`cpu.png`, `ram.png`, `thermal.png`) into single-color monochrome outlines matching the macOS menu bar (**black** in Light Mode, **white** in Dark Mode).
  - Fills only the transparent interior of each icon **left to right** in proportion to current usage (`0%`–`100%`), revealing a fixed **green → yellow → red** horizontal gradient.
  - **Thermal Throttling Indicator**: Automatically swaps the CPU icon for the thermal throttling flame icon (also filled left-to-right by CPU %) whenever macOS enters `.serious` or `.critical` thermal state.
- **Lazy Click Dropdown Menu**:
  - Always displays live **CPU %**, **RAM used / total GB (%)**, and **Thermal state** (`Normal`, `Fair`, `Throttling (Serious)`, `Throttling (Critical)`).
  - Clicking **CPU** or **RAM** toggles its checkmark to show or hide that icon in the menu bar while keeping both stats visible in the dropdown.
  - Shows a small fallback gauge icon if both CPU and RAM icons are unchecked so the menu remains accessible.
  - Persists icon visibility preferences in `Plugins/SystemMonitor/Data/settings.json`.
- **Near-Zero CPU & RAM Overhead**:
  - Uses stack-allocated Mach/Foundation syscalls (`HOST_CPU_LOAD_INFO`, `HOST_VM_INFO64` Activity Monitor "Memory Used", and `ProcessInfo.thermalState`) with zero subprocesses.
  - Pre-bakes monochrome foregrounds and masked gradients once at startup, then uses quantized dirty-checking and a single reusable `CGContext` (~14 KB) at 2 Hz.
  - Automatically pauses updates on sleep and display-off via `PluginScheduler`.

## Build & Run

From the MenuBarPlugins project root:

```bash
# 1. Build the host app & CLI (if not already built)
./scripts/build-app.sh

# 2. Build SystemMonitor in place inside Plugins/SystemMonitor/
./mbp build Plugins/SystemMonitor

# 3. Verify discovery and launch/reload
./mbp list
open MenuBarPlugins.app   # or ./mbp reload if already running
```
