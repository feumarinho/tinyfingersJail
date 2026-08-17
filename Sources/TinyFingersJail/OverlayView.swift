import Cocoa

/// Camada por cima do site: dica de saída no topo e a barra de progresso do "segure para sair".
/// Nunca captura clique — todo o mouse continua indo para a página.
final class OverlayView: NSView {
    private let hintLabel = OverlayView.makeLabel(size: 13, weight: .medium)
    private let hintBackground = NSView()
    private let panel = NSView()
    private let panelLabel = OverlayView.makeLabel(size: 17, weight: .semibold)
    private let barTrack = NSView()
    private let barFill = NSView()
    private var hintHideWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        hintBackground.wantsLayer = true
        hintBackground.layer?.backgroundColor = NSColor(white: 0, alpha: 0.65).cgColor
        hintBackground.layer?.cornerRadius = 10
        hintBackground.alphaValue = 0
        hintBackground.addSubview(hintLabel)
        addSubview(hintBackground)

        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0, alpha: 0.78).cgColor
        panel.layer?.cornerRadius = 16
        panel.alphaValue = 0

        barTrack.wantsLayer = true
        barTrack.layer?.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
        barTrack.layer?.cornerRadius = 5

        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = NSColor.systemGreen.cgColor
        barFill.layer?.cornerRadius = 5

        barTrack.addSubview(barFill)
        panel.addSubview(panelLabel)
        panel.addSubview(barTrack)
        addSubview(panel)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let hintWidth = min(max(hintLabel.intrinsicContentSize.width + 28, 220), bounds.width - 40)
        hintBackground.frame = NSRect(
            x: (bounds.width - hintWidth) / 2,
            y: bounds.height - 56,
            width: hintWidth,
            height: 34
        )
        hintLabel.frame = hintBackground.bounds.insetBy(dx: 12, dy: 8)

        let panelSize = NSSize(width: 360, height: 104)
        panel.frame = NSRect(
            x: (bounds.width - panelSize.width) / 2,
            y: (bounds.height - panelSize.height) / 2,
            width: panelSize.width,
            height: panelSize.height
        )
        panelLabel.frame = NSRect(x: 20, y: 56, width: panelSize.width - 40, height: 26)
        barTrack.frame = NSRect(x: 24, y: 28, width: panelSize.width - 48, height: 10)
        applyProgressFrame()
    }

    private var progress: Double = 0 {
        didSet { applyProgressFrame() }
    }

    private func applyProgressFrame() {
        let width = barTrack.bounds.width * CGFloat(min(max(progress, 0), 1))
        barFill.frame = NSRect(x: 0, y: 0, width: width, height: barTrack.bounds.height)
    }

    // MARK: - API

    /// Mostra uma dica temporária no topo da tela (usada no boot e para avisos).
    func showHint(_ text: String, duration: TimeInterval = 8) {
        hintLabel.stringValue = text
        needsLayout = true
        hintHideWork?.cancel()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            hintBackground.animator().alphaValue = 1
        }

        guard duration > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self?.hintBackground.animator().alphaValue = 0
            }
        }
        hintHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// `progress == nil` esconde o painel; caso contrário mostra a barra de saída.
    func setExitProgress(_ progress: Double?, comboText: String, holdSeconds: Double) {
        guard let progress = progress else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }
            self.progress = 0
            return
        }

        panelLabel.stringValue = "Segure \(comboText) por \(String(format: "%.0f", holdSeconds))s para sair"
        panel.alphaValue = 1
        self.progress = progress
    }

    // MARK: - Helpers

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil // deixa o mouse passar direto para o WKWebView
    }

    private static func makeLabel(size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
