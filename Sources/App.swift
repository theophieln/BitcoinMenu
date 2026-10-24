import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let preferences = Preferences()
    private lazy var state = PriceState(cached: preferences.loadSnapshot())
    private let session = KrakenTicker.makeSession()
    private var refreshTimer: Timer?
    private var staleTimer: Timer?
    private var fetchTask: Task<Void, Never>?
    private var activeMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(openMenu(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.masksToBounds = true
            button.setAccessibilityLabel("Bitcoin-Kurs")
        }
        render()
        refresh()
        let refreshTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTimer.tolerance = 3
        RunLoop.main.add(refreshTimer, forMode: .common)
        self.refreshTimer = refreshTimer
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    private func refresh() {
        guard state.beginRefresh() else { return }
        render()
        fetchTask = Task { [weak self, session] in
            do {
                let snapshot = try await KrakenTicker.fetch(using: session)
                guard let self, !Task.isCancelled else { return }
                self.state.succeed(snapshot)
                self.preferences.save(snapshot: snapshot)
                self.scheduleStaleTimer(for: snapshot)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state.fail(error.localizedDescription)
            }
            self?.render()
            self?.fetchTask = nil
        }
    }

    private func scheduleStaleTimer(for snapshot: PriceSnapshot) {
        staleTimer?.invalidate()
        let timer = Timer(fire: snapshot.receivedAt.addingTimeInterval(PriceState.staleAfter),
                          interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer
    }

    @objc private func didWake() {
        render()
        refresh()
    }

    private func render() {
        let now = Date()
        let title = PriceFormatting.title(snapshot: state.snapshot, currency: preferences.currency,
                                          stale: state.isStale(now: now))
        statusItem.button?.title = title
        statusItem.button?.toolTip = state.tooltip(now: now)
        statusItem.button?.setAccessibilityValue(title)
        if let menu = activeMenu { updateMenu(menu) }
    }

    @objc private func openMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.delegate = self
        let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        info.tag = 1
        menu.addItem(info)
        menu.addItem(.separator())
        for currency in Currency.allCases {
            let item = NSMenuItem(title: "\(currency.rawValue) (\(currency.symbol))",
                                  action: #selector(selectCurrency(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = currency.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Beenden", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        activeMenu = menu
        updateMenu(menu)
        statusItem.menu = menu
        sender.performClick(nil)
    }

    private func updateMenu(_ menu: NSMenu) {
        for item in menu.items {
            if let raw = item.representedObject as? String {
                item.state = raw == preferences.currency.rawValue ? .on : .off
            }
            if item.tag == 1 {
                item.title = state.snapshot == nil ? (state.isRefreshing ? "Kraken · Lädt …" : "Kraken · Kein Kurs")
                    : (state.isStale(now: Date()) ? "Kraken · ⚠ Veraltet" : "Kraken · Aktuell")
                item.toolTip = state.tooltip(now: Date())
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
        activeMenu = nil
    }

    @objc private func selectCurrency(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let currency = Currency(rawValue: raw) else { return }
        preferences.currency = currency
        render()
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        staleTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        fetchTask?.cancel()
        session.invalidateAndCancel()
    }
}
