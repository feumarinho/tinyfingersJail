import Cocoa
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, EventGuardDelegate {
    private let config = Config.load()
    private lazy var browser = BrowserController(config: config)
    private lazy var guardian = EventGuard(config: config)
    private lazy var cornerWatcher = CornerExitWatcher(config: config)

    private var windows: [KioskWindow] = []
    private var primaryWindow: KioskWindow?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var heartbeatTimer: Timer?
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
        startCornerWatcher()
        startHeartbeat()
        observeSystemNotifications()

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
        ensureKeyboardFocus()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard isLocked, !isUnlocking else { return }
        // Se algo roubou o foco, o quiosque volta para frente.
        reactivateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isLocked, !self.isUnlocking else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.primaryWindow?.makeKeyAndOrderFront(nil)
        }
        reactivateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func observeSystemNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Ao acordar do sono o "sinal de vida" está velho; reseta para o watchdog não
        // confundir sono com travamento.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemDidWake() {
        guardian.noteHeartbeat()
    }

    // MARK: - Janelas

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        primaryWindow = nil

        let screens = NSScreen.screens
        guard let primary = NSScreen.main ?? screens.first else { return }

        for screen in screens {
            let window = KioskWindow(screen: screen)
            window.level = isLocked ? .screenSaver : .normal

            if screen === primary {
                browser.containerView.frame = NSRect(origin: .zero, size: screen.frame.size)
                window.contentView = browser.containerView
                browser.layoutSubviews()
                primaryWindow = window
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

        primaryWindow?.makeKeyAndOrderFront(nil)
        ensureKeyboardFocus()
    }

    @objc private func screenParametersChanged() {
        guard !isUnlocking else { return }
        buildWindows()
        if isLocked {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Garante que as teclas chegam no site. Sem first responder o teclado parece "morto".
    private func ensureKeyboardFocus() {
        guard let window = primaryWindow else { return }
        let target = browser.focusTarget
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: target) {
            return
        }
        window.makeFirstResponder(target)
    }

    // MARK: - Modo quiosque

    private func engageKiosk() {
        isLocked = true
        windows.forEach { $0.level = .screenSaver }
        applyPresentationOptions()
        browser.overlay.showHint(exitHintText, duration: 12)
        ensureKeyboardFocus()
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
            guard let self = self, !self.isLocked, !self.isUnlocking else { return }
            guard EventGuard.hasAccessibilityPermission, self.guardian.start() else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            self.engageKiosk()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    // MARK: - Sinal de vida para o watchdog

    /// O `EventGuard` devolve o teclado ao sistema se este sinal parar de chegar —
    /// é o que impede uma travada da interface de travar o Mac inteiro.
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.guardian.noteHeartbeat()
            if self.isLocked, !self.isUnlocking {
                self.ensureKeyboardFocus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    // MARK: - Saídas

    private var exitHintText: String {
        var text = "Saídas: segure \(config.exit.display) por \(seconds(config.holdSeconds))s"
        if config.cornerExitEnabled {
            text += " · ou clique e segure o canto \(config.cornerExitPosition.label) por \(seconds(config.cornerExitSeconds))s"
        }
        return text
    }

    private var keyboardExitMessage: String {
        "Segure \(config.exit.display) por \(seconds(config.holdSeconds))s para sair"
    }

    private var cornerExitMessage: String {
        "Segure o canto por \(seconds(config.cornerExitSeconds))s para sair"
    }

    private func seconds(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    /// Rede de segurança: mesmo sem event tap, a combinação de saída funciona
    /// enquanto o app estiver em primeiro plano.
    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            return self.guardian.handleLocalEvent(event) ? nil : event
        }
    }

    private func startCornerWatcher() {
        guard config.cornerExitEnabled else { return }

        cornerWatcher.onProgress = { [weak self] progress in
            guard let self = self else { return }
            self.browser.overlay.setExitProgress(progress, message: self.cornerExitMessage)
        }
        cornerWatcher.onComplete = { [weak self] in
            // Chamado fora da main thread: devolve o teclado primeiro, encerra depois.
            self?.guardian.hardRelease()
            DispatchQueue.main.async { self?.performUnlock() }
        }
        cornerWatcher.start()
    }

    private func performUnlock() {
        guard !isUnlocking else { return }
        isUnlocking = true
        isLocked = false

        reactivateWork?.cancel()
        permissionTimer?.invalidate()
        heartbeatTimer?.invalidate()
        cornerWatcher.stop()
        guardian.stop()
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        releaseKiosk()
        windows.forEach { $0.orderOut(nil) }

        // Garantia final: se o encerramento emperrar, o processo morre em 3s e o Mac
        // volta ao normal sozinho. Ninguém precisa reiniciar a máquina por causa deste app.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { _exit(0) }
        NSApp.terminate(nil)
    }

    // MARK: - EventGuardDelegate

    func eventGuard(_ guardian: EventGuard, holdProgress progress: Double?) {
        browser.overlay.setExitProgress(progress, message: keyboardExitMessage)
    }

    func eventGuardDidUnlock(_ guardian: EventGuard) {
        performUnlock()
    }
}
