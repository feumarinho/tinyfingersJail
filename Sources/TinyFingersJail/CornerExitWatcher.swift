import Cocoa

/// Saída pelo mouse: pressione e segure num canto da tela (padrão: canto superior direito).
///
/// Nunca consome o clique — o site continua recebendo tudo normalmente. Se o cursor
/// sair da área do canto, ou o botão for solto, a contagem zera.
final class CornerExitWatcher {
    private let config: Config
    private let hold: HoldTracker
    private var monitor: Any?

    /// Progresso de 0 a 1, ou `nil` quando cancelado. Chamado na main thread.
    var onProgress: ((Double?) -> Void)?
    /// Contagem concluída. Chamado **fora da main thread** (ver `HoldTracker`).
    var onComplete: (() -> Void)?

    init(config: Config) {
        self.config = config
        self.hold = HoldTracker(
            label: "com.tinyfingersjail.corner-hold",
            duration: config.cornerExitSeconds
        )
    }

    func start() {
        hold.onProgress = { [weak self] progress in self?.onProgress?(progress) }
        hold.onComplete = { [weak self] in self?.onComplete?() }

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        ) { [weak self] event in
            self?.handle(event)
            return event // nunca consome o evento
        }
    }

    func stop() {
        hold.cancel()
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if isInsideCorner(NSEvent.mouseLocation) {
                hold.begin()
            }
        case .leftMouseDragged:
            if !isInsideCorner(NSEvent.mouseLocation) {
                hold.cancel()
            }
        case .leftMouseUp:
            hold.cancel()
        default:
            break
        }
    }

    /// `point` em coordenadas de tela (origem embaixo à esquerda).
    private func isInsideCorner(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main else { return false }

        let frame = screen.frame
        let size = CGFloat(config.cornerExitSize)
        let origin: NSPoint

        switch config.cornerExitPosition {
        case .topRight:
            origin = NSPoint(x: frame.maxX - size, y: frame.maxY - size)
        case .topLeft:
            origin = NSPoint(x: frame.minX, y: frame.maxY - size)
        case .bottomRight:
            origin = NSPoint(x: frame.maxX - size, y: frame.minY)
        case .bottomLeft:
            origin = NSPoint(x: frame.minX, y: frame.minY)
        }

        return NSRect(origin: origin, size: NSSize(width: size, height: size)).contains(point)
    }
}
