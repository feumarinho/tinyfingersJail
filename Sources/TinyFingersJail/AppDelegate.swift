import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, EventGuardDelegate {
    private let config = Config.load()
    private lazy var browser = BrowserController(config: config)
    private lazy var guardian = EventGuard(config: config)

    private var windows: [KioskWindow] = []
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var reactivateWork: DispatchWorkItem?
    private var isLocked = false
    private var isUnlocking = false

    // MARK: - Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = nil // sem menu não existe item "Sair"
        guardian.delegate = self

        buildWindows()
        browser.loadHome()
        installLocalMonitor()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if guardian.start() {
            engageKiosk()
        } else {
            // Sem permissão de Acessibilidade não dá para bloquear Spotlight/⌘Tab.
            // O app continua utilizável em modo reduzido enquanto o pai/mãe autoriza.
            EventGuard.requestAccessibilityPermission()
            browser.overlay.showHint(
                "Autorize “TinyFingersJail” em Ajustes do Sistema › Privacidade e Segurança › Acessibilidade para travar a tela",
                duration: 0
            )
            startPermissionPolling()
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isUnlocking || !isLocked ? .terminateNow : .terminateCancel
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard isLocked, !isUnlocking else { return }
        applyPresentationOptions()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard isLocked, !isUnlocking else { return }
        // Se algo roubou o foco, o quiosque volta para frente.
        reactivateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isLocked, !self.isUnlocking else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.windows.first?.makeKeyAndOrderFront(nil)
        }
        reactivateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - Janelas

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []

        let screens = NSScreen.screens
        guard let primary = NSScreen.main ?? screens.first else { return }

        for screen in screens {
            let window = KioskWindow(screen: screen)
            window.level = isLocked ? .screenSaver : .normal

            if screen === primary {
                browser.containerView.frame = NSRect(origin: .zero, size: screen.frame.size)
                window.contentView = browser.containerView
                browser.layoutSubviews()
            } else {
                // Telas secundárias ficam pretas: nada de clicar em outro monitor.
                let black = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                black.wantsLayer = true
                black.layer?.backgroundColor = NSColor.black.cgColor
                window.contentView = black
            }

            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
    }

    @objc private func screenParametersChanged() {
        guard !isUnlocking else { return }
        buildWindows()
        if isLocked {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Modo quiosque

    private func engageKiosk() {
        isLocked = true
        windows.forEach { $0.level = .screenSaver }
        applyPresentationOptions()
        browser.overlay.showHint(
            "Segure \(config.exit.display) por \(Int(config.holdSeconds.rounded()))s para sair",
            duration: 10
        )
    }

    private func applyPresentationOptions() {
        // As opções só valem com o app ativo; se ainda não estiver, `applicationDidBecomeActive`
        // reaplica assim que ele vier para frente.
        guard NSApp.isActive else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        var options: NSApplication.PresentationOptions = [
            .hideDock,
            .hideMenuBar,
            .disableAppleMenu,
            .disableProcessSwitching,
            .disableHideApplication,
        ]
        if config.blockForceQuit {
            options.insert(.disableForceQuit)
        }
        if config.blockSessionTermination {
            options.insert(.disableSessionTermination)
        }
        NSApp.presentationOptions = options
    }

    private func releaseKiosk() {
        NSApp.presentationOptions = []
        windows.forEach { $0.level = .normal }
    }

    // MARK: - Permissão de Acessibilidade

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, !self.isLocked else { return }
            guard EventGuard.hasAccessibilityPermission, self.guardian.start() else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            self.engageKiosk()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    // MARK: - Teclado

    /// Rede de segurança: mesmo sem event tap, a combinação de saída funciona
    /// enquanto o app estiver em primeiro plano.
    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            return self.guardian.handleLocalEvent(event) ? nil : event
        }
    }

    // MARK: - EventGuardDelegate

    func eventGuard(_ guardian: EventGuard, holdProgress progress: Double?) {
        browser.overlay.setExitProgress(
            progress,
            comboText: config.exit.display,
            holdSeconds: config.holdSeconds
        )
    }

    func eventGuardDidUnlock(_ guardian: EventGuard) {
        isUnlocking = true
        isLocked = false
        reactivateWork?.cancel()
        permissionTimer?.invalidate()
        guardian.stop()
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        releaseKiosk()
        windows.forEach { $0.orderOut(nil) }
        NSApp.terminate(nil)
    }
}
