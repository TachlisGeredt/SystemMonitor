import AppKit
import Foundation
import MenuBarPluginKit

private struct MonitorSettings: Codable {
    var showCPU: Bool = true
    var showRAM: Bool = true
}

final class SystemMonitorPlugin: NSObject, MenuBarPlugin {
    let identifier = "com.local.system-monitor"

    private var context: PluginContext?
    private var metrics: SystemMetrics?
    private var renderer: IconRenderer?
    private var settings = MonitorSettings()
    private var latestSnapshot = SystemSnapshot(
        cpuUsage: 0,
        ramUsage: 0,
        ramUsedBytes: 0,
        ramTotalBytes: ProcessInfo.processInfo.physicalMemory,
        thermalState: ProcessInfo.processInfo.thermalState
    )

    private var thermalObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var showingFallbackSymbol = false

    func activate(context: PluginContext) {
        self.context = context
        self.metrics = SystemMetrics()

        let resourcesURL = context.pluginDirectoryURL.appendingPathComponent("Resources", isDirectory: true)
        self.renderer = IconRenderer(resourcesDirectoryURL: resourcesURL)
        loadSettings(from: context)

        context.setTitle("")
        context.setTooltip("System Monitor")

        // Event-driven thermal state notifications for immediate icon swap.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.tick()
        }

        // Event-driven appearance change notification (Light/Dark menu bar switch).
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.renderer?.invalidateCache()
            self?.renderCurrentSnapshot()
        }

        // 2 Hz coalesced repeating timer (auto-paused on sleep/display-off, auto-cancelled on deactivate).
        context.scheduleRepeating(interval: 0.5, leeway: 0.1, fireImmediately: true) { [weak self] in
            self?.tick()
        }
    }

    func deactivate() {
        if let token = thermalObserver {
            NotificationCenter.default.removeObserver(token)
            thermalObserver = nil
        }
        if let token = appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(token)
            appearanceObserver = nil
        }
        metrics = nil
        renderer = nil
        context = nil
        showingFallbackSymbol = false
    }

    func buildMenu() -> [MenuItemModel] {
        // Refresh snapshot on click so numbers are always up-to-the-moment.
        if let metrics {
            latestSnapshot = metrics.sample()
            renderCurrentSnapshot()
        }

        let cpuPercent = latestSnapshot.cpuUsage * 100.0
        let ramPercent = latestSnapshot.ramUsage * 100.0
        let usedGB = Double(latestSnapshot.ramUsedBytes) / 1_073_741_824.0
        let totalGB = Double(latestSnapshot.ramTotalBytes) / 1_073_741_824.0

        let cpuTitle = String(format: "CPU: %.1f%%", cpuPercent)
        let ramTitle = String(format: "RAM: %.1f / %.1f GB (%.0f%%)", usedGB, totalGB, ramPercent)
        let thermalSymbol = latestSnapshot.isThrottling ? "flame.fill" : "thermometer.medium"
        let thermalTitle = "Thermal: \(latestSnapshot.thermalDescription)"

        return [
            .action(cpuTitle, symbolName: "cpu", isChecked: settings.showCPU) { [weak self] in
                guard let self else { return }
                self.settings.showCPU.toggle()
                self.saveSettings()
                self.renderer?.invalidateCache()
                self.renderCurrentSnapshot()
            },
            .action(ramTitle, symbolName: "memorychip", isChecked: settings.showRAM) { [weak self] in
                guard let self else { return }
                self.settings.showRAM.toggle()
                self.saveSettings()
                self.renderer?.invalidateCache()
                self.renderCurrentSnapshot()
            },
            .separator(),
            .label(thermalTitle, symbolName: thermalSymbol)
        ]
    }

    // MARK: - Sampling & Rendering

    private func tick() {
        guard let metrics else { return }
        latestSnapshot = metrics.sample()
        renderCurrentSnapshot()
    }

    private func renderCurrentSnapshot() {
        guard let context else { return }

        if !settings.showCPU && !settings.showRAM {
            if !showingFallbackSymbol {
                context.setSymbol(
                    "gauge.with.dots.needle.bottom.50percent",
                    accessibilityDescription: "System Monitor"
                )
                showingFallbackSymbol = true
            }
            return
        }

        showingFallbackSymbol = false
        let isDarkMode = Self.isDarkMenuBar()

        if let image = renderer?.renderIfNeeded(
            cpuUsage: latestSnapshot.cpuUsage,
            ramUsage: latestSnapshot.ramUsage,
            isThrottling: latestSnapshot.isThrottling,
            showCPU: settings.showCPU,
            showRAM: settings.showRAM,
            isDarkMode: isDarkMode
        ) {
            context.setImage(image)
        }
    }

    private static func isDarkMenuBar() -> Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Settings Persistence (inside plugin's own Data/ folder)

    private func loadSettings(from context: PluginContext) {
        let fileURL = context.dataDirectoryURL.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(MonitorSettings.self, from: data) else {
            return
        }
        settings = decoded
    }

    private func saveSettings() {
        guard let context else { return }
        do {
            let dir = try context.ensureDataDirectory()
            let fileURL = dir.appendingPathComponent("settings.json")
            let data = try JSONEncoder().encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Non-fatal: keep in-memory state.
        }
    }
}

@_cdecl("mbp_create_plugin")
public func createPlugin() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SystemMonitorPlugin()).toOpaque()
}
