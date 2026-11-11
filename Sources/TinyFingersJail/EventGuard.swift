import ApplicationServices
import Cocoa
import Darwin

protocol EventGuardDelegate: AnyObject {
    /// `progress` vai de 0 a 1 enquanto a combinação de saída está pressionada; `nil` quando soltou.
    /// Sempre chamado na main thread.
    func eventGuard(_ guardian: EventGuard, holdProgress progress: Double?)
    /// Chamado na main thread quando a saída foi liberada.
    func eventGuardDidUnlock(_ guardian: EventGuard)
}

/// Intercepta o teclado do sistema inteiro enquanto o quiosque está ativo.
///
/// Teclas "normais" continuam chegando no site (é isso que a criança usa). Tudo que
/// carrega ⌘/⌃, teclas de função, Escape, teclas de mídia e gestos de trackpad são
/// engolidos, o que mata Spotlight (⌘Espaço), troca de app (⌘Tab), Mission Control, ⌘Q, etc.
///
/// ## Por que o tap roda numa thread própria
///
/// Um event tap `.defaultTap` em `headInsertEventTap` é **síncrono**: o servidor de janelas
/// espera a resposta do processo antes de entregar a tecla a quem for. Se o callback ficar
/// preso atrás de outra coisa (a main thread ocupada renderizando a página, por exemplo),
/// o teclado do Mac inteiro congela — inclusive a combinação de saída. Por isso o tap tem
/// run loop próprio, o callback não faz nada de UI, e existe um watchdog que devolve o
/// teclado se a main thread parar de responder.
final class EventGuard {
    weak var delegate: EventGuardDelegate?

    /// Se a main thread ficar este tempo sem dar sinal de vida, o teclado é devolvido ao sistema.
    private static let releaseAfterSeconds: Double = 6
    /// Se continuar travada, o app se encerra sozinho — melhor fechar o app do que travar o Mac.
    private static let hardExitAfterSeconds: Double = 20

    private let config: Config
    private let lock = NSLock()
    private let watchdogQueue = DispatchQueue(label: "com.tinyfingersjail.watchdog")
    private let hold: HoldTracker

    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var watchdog: DispatchSourceTimer?

    // Estado compartilhado entre threads — sempre sob `lock`.
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var lastWatchdogTick = ProcessInfo.processInfo.systemUptime
    private var isReleased = false
    private var isUnlocked = false
    private(set) var isTapInstalled = false

    init(config: Config) {
        self.config = config
        self.hold = HoldTracker(
            label: "com.tinyfingersjail.keyboard-hold",
            duration: config.holdSeconds
        )
        hold.onProgress = { [weak self] progress in
            guard let self = self else { return }
            self.delegate?.eventGuard(self, holdProgress: progress)
        }
        hold.onComplete = { [weak self] in
            self?.completeUnlock()
        }
    }

    // MARK: - Ciclo de vida

    /// Instala o event tap. Retorna `false` quando falta permissão de Acessibilidade.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return isTapInstalled }

        let bits: [UInt64] = [
            UInt64(CGEventType.keyDown.rawValue),
            UInt64(CGEventType.keyUp.rawValue),
            UInt64(CGEventType.flagsChanged.rawValue),
            14, // systemDefined: teclas de mídia/volume/brilho
            18, // rotate
            19, // beginGesture
            20, // endGesture
            29, // gesture
            30, // magnify
            31, // swipe (Mission Control, troca de Space)
        ]
        let mask: CGEventMask = bits.reduce(UInt64(0)) { $0 | (UInt64(1) << $1) }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventGuardCallback,
            userInfo: refcon
        ) else {
            isTapInstalled = false
            return false
        }

        self.tap = tap
        noteHeartbeat()

        // Run loop dedicado: o tap nunca depende da main thread.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runTapLoop(tap: tap, ready: ready)
        }
        thread.name = "com.tinyfingersjail.event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread

        // Um tap sem run loop atendendo é pior que nenhum tap: o servidor de janelas
        // esperaria por um callback que nunca vem. Se a thread não subir, desiste.
        guard ready.wait(timeout: .now() + 2) == .success else {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
            tapThread = nil
            isTapInstalled = false
            NSLog("TinyFingersJail: a thread do event tap não subiu; seguindo sem bloqueio global")
            return false
        }

        startWatchdog()
        isTapInstalled = true
        return true
    }

    private func runTapLoop(tap: CFMachPort, ready: DispatchSemaphore) {
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()

        lock.lock()
        tapRunLoop = runLoop
        lock.unlock()

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ready.signal()

        CFRunLoopRun()

        CFRunLoopRemoveSource(runLoop, source, .commonModes)
    }

    func stop() {
        hold.cancel()
        disableTap()

        lock.lock()
        let runLoop = tapRunLoop
        tapRunLoop = nil
        lock.unlock()

        if let runLoop = runLoop {
            CFRunLoopStop(runLoop)
        }
        watchdog?.cancel()
        watchdog = nil
        tapThread = nil
        // `tap` não é zerado de propósito: a thread do tap pode estar lendo a referência.
        isTapInstalled = false
    }

    /// Devolve o teclado ao sistema imediatamente, de qualquer thread.
    /// Usado na saída e pelo watchdog — nunca depende da main thread.
    func hardRelease() {
        lock.lock()
        isUnlocked = true
        lock.unlock()
        disableTap()
    }

    private func disableTap() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    /// Pede a permissão de Acessibilidade (mostra o diálogo do sistema).
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Watchdog

    /// A main thread chama isso de segundo em segundo. É o "sinal de vida" da interface.
    func noteHeartbeat() {
        lock.lock()
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
        let shouldReengage = isReleased && !isUnlocked
        if shouldReengage { isReleased = false }
        lock.unlock()

        if shouldReengage, let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        lock.lock()
        lastWatchdogTick = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkMainThread() }
        watchdog = timer
        timer.resume()
    }

    private func checkMainThread() {
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        // Se o próprio watchdog ficou parado (Mac dormindo, carga alta), a medida anterior
        // não vale nada: começa a contar de novo em vez de acusar travamento.
        let tickGap = now - lastWatchdogTick
        lastWatchdogTick = now
        if tickGap > 3 {
            lastHeartbeat = now
            lock.unlock()
            return
        }

        let age = now - lastHeartbeat
        let unlocked = isUnlocked
        let shouldRelease = !unlocked && !isReleased && age > EventGuard.releaseAfterSeconds
        if shouldRelease { isReleased = true }
        lock.unlock()

        guard !unlocked else { return }

        if shouldRelease {
            // A interface travou: solta o teclado para o sistema voltar a responder.
            NSLog("TinyFingersJail: main thread sem resposta há %.0fs — devolvendo o teclado ao sistema", age)
            disableTap()
        }

        if age > EventGuard.hardExitAfterSeconds {
            NSLog("TinyFingersJail: main thread travada há %.0fs — encerrando o app", age)
            disableTap()
            _exit(0)
        }
    }

    // MARK: - Event tap

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        let unlocked = isUnlocked
        let released = isReleased
        lock.unlock()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !unlocked, !released, let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        guard !unlocked, !released else { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown, .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            if config.exit.matches(keyCode: keyCode, flags: flags) {
                if type == .keyDown {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        hold.begin()
                    }
                } else {
                    hold.cancel()
                }
                return nil
            }

            if type == .keyDown {
                hold.cancel()
            }

            return shouldSwallow(keyCode: keyCode, flags: flags) ? nil : Unmanaged.passUnretained(event)

        case .flagsChanged:
            if !config.exit.modifiersMatch(flags: event.flags) {
                hold.cancel()
            }
            // A tecla fn/globo sozinha abre ditado (toque duplo) e o painel de emoji.
            if event.getIntegerValueField(.keyboardEventKeycode) == 63 {
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            // Teclas de mídia e gestos de trackpad (Mission Control, pinça, swipe entre Spaces).
            return nil
        }
    }

    /// F1–F20 e Escape. Letras, números e setas continuam passando: é com elas que a criança brinca.
    private static let blockedKeyCodes: Set<Int64> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90, // F13–F20
        53, // escape
    ]

    /// ⌘⌥Esc (Forçar Encerramento) passa de propósito: é uma saída de emergência
    /// que nenhuma criança acerta sem querer.
    private static func isForceQuitShortcut(keyCode: Int64, command: Bool, option: Bool) -> Bool {
        keyCode == 53 && command && option
    }

    private func shouldSwallow(keyCode: Int64, flags: CGEventFlags) -> Bool {
        if EventGuard.isForceQuitShortcut(
            keyCode: keyCode,
            command: flags.contains(.maskCommand),
            option: flags.contains(.maskAlternate)
        ) {
            return false
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return true
        }
        return EventGuard.blockedKeyCodes.contains(keyCode)
    }

    private func shouldSwallow(keyCode: Int64, nsFlags: NSEvent.ModifierFlags) -> Bool {
        if EventGuard.isForceQuitShortcut(
            keyCode: keyCode,
            command: nsFlags.contains(.command),
            option: nsFlags.contains(.option)
        ) {
            return false
        }
        if nsFlags.contains(.command) || nsFlags.contains(.control) {
            return true
        }
        return EventGuard.blockedKeyCodes.contains(keyCode)
    }

    // MARK: - Fallback sem permissão de Acessibilidade

    /// Usado pelo monitor local de eventos: garante que a saída funciona mesmo sem event tap.
    /// Retorna `true` quando o evento deve ser consumido.
    func handleLocalEvent(_ event: NSEvent) -> Bool {
        lock.lock()
        let unlocked = isUnlocked
        lock.unlock()
        guard !unlocked else { return false }

        switch event.type {
        case .keyDown, .keyUp:
            if config.exit.matches(event: event) {
                if event.type == .keyDown {
                    if !event.isARepeat { hold.begin() }
                } else {
                    hold.cancel()
                }
                return true
            }
            if event.type == .keyDown {
                hold.cancel()
            }
            return shouldSwallow(keyCode: Int64(event.keyCode), nsFlags: event.modifierFlags)

        case .flagsChanged:
            if !config.exit.modifiersMatch(event: event) {
                hold.cancel()
            }
            return false

        default:
            return false
        }
    }

    // MARK: - Saída

    /// Chamado fora da main thread. Devolve o teclado primeiro, avisa a interface depois.
    private func completeUnlock() {
        hardRelease()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.eventGuardDidUnlock(self)
        }
    }
}

/// Callback C do event tap (não pode capturar contexto). Precisa ser rápido: nada de UI aqui.
private func eventGuardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let guardian = Unmanaged<EventGuard>.fromOpaque(refcon).takeUnretainedValue()
    return guardian.handle(type: type, event: event)
}
