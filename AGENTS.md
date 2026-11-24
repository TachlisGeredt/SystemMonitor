# AGENTS.md — Modifying the SystemMonitor Plugin

Guide for AI coding agents and developers modifying, rebuilding, and testing the **SystemMonitor** plugin. Follow the root [AGENTS.md](../../AGENTS.md) rules in addition to the plugin-specific notes below.

---

## Folder Structure

Everything for this plugin lives strictly inside `Plugins/SystemMonitor/`:

```text
Plugins/SystemMonitor/
├── manifest.json                   # Plugin metadata (id: com.local.system-monitor)
├── .gitignore                      # Ignores *.dylib, *.dSYM/, Swift build artifacts, Data/, .DS_Store
├── README.md                       # User-facing overview, features, and build instructions
├── AGENTS.md                       # This guide
├── Resources/
│   ├── cpu.png                     # CPU chip icon (opaque outer white, transparent inner square)
│   ├── ram.png                     # RAM stick icon (opaque outer white, transparent inner body)
│   └── thermal.png                 # Thermal chip icon (opaque outer white, transparent flame cutout)
└── Sources/
    ├── SystemMetrics.swift         # Stack-only Mach CPU/RAM sampling + ProcessInfo.thermalState
    ├── IconRenderer.swift          # One-time PNG preprocessing + dirty-checked 2-blit CGContext renderer
    └── SystemMonitorPlugin.swift   # MenuBarPlugin entry point, 2 Hz timer, lazy menu, Data/settings.json
```

---

## Architecture & Modification Invariants

### 1. PNG Asset Contract (`Resources/` + `Sources/IconRenderer.swift`)
- **Interior fill mask**: Derived directly from `255 - originalAlpha`. Only the fillable interior should be transparent in source PNGs.
- **Outer background**: Stripped once on `activate()` via corner BFS flood-fill on near-white opaque pixels (`r,g,b >= 235, a >= 240`).
- **Monochrome foreground modes**:
  - `.darkInkOnWhite` (`ram.png`, `thermal.png`): Converts dark ink lines to monochrome foreground while keeping hollow white chip/pin interiors transparent.
  - `.allOpaqueForeground` (`cpu.png`): Converts all non-exterior opaque pixels (border, pins, and `"CPU"` text) into solid monochrome foreground.
- **Retina `@2x` layout**: Canvas height is `36 px` (`18 pt`); CPU/Thermal are `36×36 px`; RAM is `56×28 px` vertically centered inside `36 px`, separated by a `10 px` (`5 pt`) gap.

### 2. Efficiency Rules
- **No subprocesses, no SwiftUI, no WebKit**: Keep metric sampling in native Mach (`HOST_CPU_LOAD_INFO`, `HOST_VM_INFO64`) and `Foundation` (`ProcessInfo`).
- **Keep 2 Hz ticks allocation-free**:
  - Pre-bake `foregroundLight`, `foregroundDark`, and `gradientFilled` once in `IconRenderer.init(resourcesDirectoryURL:)`.
  - Never allocate `CGGradient` or run flood-fills inside `renderIfNeeded(...)`.
  - Keep `RenderKey` dirty-checking so unchanged quantized pixel fills perform **0 CoreGraphics calls** and skip `context.setImage(...)`.
- **Power-aware timers**: Always schedule via `context.scheduleRepeating(interval: 0.5, leeway: 0.1, fireImmediately: true)` so updates pause on sleep/display-off and cancel on `deactivate()`.

### 3. State, Menu & Persistence (`Sources/SystemMonitorPlugin.swift`)
- **Event-driven observers**: Observes `ProcessInfo.thermalStateDidChangeNotification` (immediate swap to `thermal.png`) and `AppleInterfaceThemeChangedNotification` (immediate Light/Dark monochrome switch). Remove both observers in `deactivate()`.
- **Lazy dropdown menu**: `buildMenu()` runs only on click. Both `CPU: ...` and `RAM: ...` always appear; their checkmarks toggle `settings.showCPU` and `settings.showRAM`. If both are `false`, show SF Symbol `gauge.with.dots.needle.bottom.50percent`.
- **Storage**: Persist settings only via `context.ensureDataDirectory()` (`Plugins/SystemMonitor/Data/settings.json`). Never write outside `Plugins/SystemMonitor/`.

---

## Rebuilding & Testing

Run from the MenuBarPlugins project root:

```bash
# 1. Compile libSystemMonitor.dylib in place
./mbp build Plugins/SystemMonitor

# 2. Verify discovery
./mbp list

# 3. Reload running MenuBarPlugins.app
./mbp reload
```

If you also changed `MenuBarPluginKit`, `MenuBarHost`, or `mbp-cli`, rebuild the host first and run the framework test suite:

```bash
./scripts/build-app.sh
./scripts/run-tests.sh
```
