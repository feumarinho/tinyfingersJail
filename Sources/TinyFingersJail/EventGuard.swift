import ApplicationServices
import Cocoa

protocol EventGuardDelegate: AnyObject {
    /// `progress` vai de 0 a 1 enquanto a combinação de saída está pressionada; `nil` quando soltou.
    func eventGuard(_ guardian: EventGuard, holdProgress progress: Double?)
    func eventGuardDidUnlock(_ guardian: EventGuard)
}

/// Intercepta o teclado do sistema inteiro enquanto o quiosque está ativo.
///
/// Teclas "normais" continuam chegando no site (é isso que a criança usa). Tudo que
/// carrega ⌘/⌃/fn, teclas de função e gestos de trackpad são engolidos, o que mata
/// Spotlight (⌘Espaço), troca de app (⌘Tab), Mission Control, ⌘Q, etc.
final class EventGuard {
    weak var delegate: EventGuardDelegate?

    private let config: Config
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdStart: CFAbsoluteTime?
    private var holdTimer: Timer?
    private var isUnlocked = false

    private(set) var isTapInstalled = false

    init(config: Config) {
        self.config = config
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

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        self.isTapInstalled = true
        return true
    }

    func stop() {
        cancelHold()
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isTapInstalled = false
    }

    /// Pede a permissão de Acessibilidade (mostra o diálogo do sistema).
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Event tap

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        guard !isUnlocked else { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown, .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            if config.exit.matches(keyCode: keyCode, flags: flags) {
                if type == .keyDown {
                    if !isRepeat { beginHold() }
                } else {
                    cancelHold()
                }
                return nil
            }

            if type == .keyDown, holdStart != nil {
                cancelHold()
            }

            return shouldSwallow(keyCode: keyCode, flags: flags) ? nil : Unmanaged.passUnretained(event)

        case .flagsChanged:
            // Se soltou um dos modificadores, a contagem de saída é cancelada.
            if holdStart != nil, !config.exit.modifiersMatch(flags: event.flags) {
                cancelHold()
            }
            // A tecla fn/globo sozinha abre ditado (toque duplo) e o painel de emoji.
            if event.getIntegerValueField(.keyboardEventKeycode) == 63 {
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            // Teclas de mídia e gestos de trackpad (Mission Control, pinça, swipe entre telas).
            return nil
        }
    }

    /// F1–F20 e Escape. Letras, números e setas continuam passando: é com elas que a criança brinca.
    private static let blockedKeyCodes: Set<Int64> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90, // F13–F20
        53, // escape
    ]

    private func shouldSwallow(keyCode: Int64, flags: CGEventFlags) -> Bool {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return true
        }
        return EventGuard.blockedKeyCodes.contains(keyCode)
    }

    private func shouldSwallow(keyCode: Int64, nsFlags: NSEvent.ModifierFlags) -> Bool {
        if nsFlags.contains(.command) || nsFlags.contains(.control) {
            return true
        }
        return EventGuard.blockedKeyCodes.contains(keyCode)
    }

    // MARK: - Fallback sem permissão de Acessibilidade

    /// Usado pelo monitor local de eventos: garante que a saída funciona mesmo sem event tap.
    /// Retorna `true` quando o evento deve ser consumido.
    func handleLocalEvent(_ event: NSEvent) -> Bool {
        guard !isUnlocked else { return false }

        switch event.type {
        case .keyDown, .keyUp:
            if config.exit.matches(event: event) {
                if event.type == .keyDown {
                    if !event.isARepeat { beginHold() }
                } else {
                    cancelHold()
                }
                return true
            }
            if event.type == .keyDown, holdStart != nil {
                cancelHold()
            }
            return shouldSwallow(keyCode: Int64(event.keyCode), nsFlags: event.modifierFlags)

        case .flagsChanged:
            if holdStart != nil, !config.exit.modifiersMatch(event: event) {
                cancelHold()
            }
            return false

        default:
            return false
        }
    }

    // MARK: - Contagem da saída

    private func beginHold() {
        guard holdStart == nil else { return }
        holdStart = CFAbsoluteTimeGetCurrent()
        delegate?.eventGuard(self, holdProgress: 0)

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickHold()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func tickHold() {
        guard let start = holdStart else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let progress = min(elapsed / config.holdSeconds, 1.0)
        delegate?.eventGuard(self, holdProgress: progress)

        if progress >= 1.0 {
            isUnlocked = true
            cancelHold()
            delegate?.eventGuardDidUnlock(self)
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        if holdStart != nil {
            holdStart = nil
            delegate?.eventGuard(self, holdProgress: nil)
        }
    }
}

/// Callback C do event tap (não pode capturar contexto).
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
