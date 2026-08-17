import Cocoa

/// Janela sem barra de título que cobre uma tela inteira.
final class KioskWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Nenhum atalho de teclado do app (⌘Q, ⌘W, ⌘H…) tem efeito aqui dentro.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        true
    }

    convenience init(screen: NSScreen) {
        self.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        setFrame(screen.frame, display: true)
    }
}
