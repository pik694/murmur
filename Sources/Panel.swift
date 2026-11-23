import AppKit

/// Floating top-right HUD with the live transcript. Non-activating, so clicking it never
/// takes focus away from the text field the result will be pasted into.
final class Panel {
    enum Mode { case recording, busy, message }

    var onPaste: () -> Void = {}
    var onCopy: () -> Void = {}
    var onCancel: () -> Void = {}

    private let width: CGFloat = 440
    private let pad: CGFloat = 12
    private let panel: NSPanel
    private let header = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private var buttons: [NSButton] = []
    private var mode: Mode = .message
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var hint = ""

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .vibrantDark) // light text on a dark HUD

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        panel.contentView = background

        header.font = .boldSystemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor
        body.font = .systemFont(ofSize: 14)
        body.textColor = .labelColor
        body.preferredMaxLayoutWidth = width - 2 * pad
        background.addSubview(header)
        background.addSubview(body)

        // Right to left: Paste, Copy, Cancel.
        for (title, action) in [("Paste", #selector(paste)), ("Copy", #selector(copy)), ("Cancel", #selector(cancel))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            background.addSubview(button)
            buttons.append(button)
        }
    }

    @objc private func paste() { onPaste() }
    @objc private func copy() { onCopy() }
    @objc private func cancel() { onCancel() }

    func showRecording(hint: String) {
        self.hint = hint
        mode = .recording
        body.stringValue = ""
        startBlinking()
        layout()
        panel.orderFrontRegardless()
    }

    func update(text: String) {
        guard mode == .recording else { return }
        body.stringValue = text
        layout()
    }

    func showBusy(_ title: String) {
        mode = .busy
        stopBlinking()
        header.stringValue = "⏳  \(title)"
        layout()
    }

    /// Shows a short message, then hides itself.
    func flash(_ title: String, text: String? = nil, seconds: Double = 1.6) {
        mode = .message
        stopBlinking()
        header.stringValue = title
        if let text { body.stringValue = text }
        layout()
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.mode == .message { self?.hide() }
        }
    }

    func hide() {
        stopBlinking()
        panel.orderOut(nil)
    }

    private func startBlinking() {
        blinkOn = true
        renderHeader()
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.blinkOn.toggle()
            self.renderHeader()
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    private func renderHeader() {
        header.stringValue = "\(blinkOn ? "🔴" : "⭕")  Listening — \(hint)"
    }

    private func layout() {
        let showButtons = mode == .recording
        buttons.forEach { $0.isHidden = !showButtons }
        if body.stringValue.isEmpty && mode == .recording { body.stringValue = "…" }

        let buttonRow: CGFloat = showButtons ? 30 : 0
        let headerHeight: CGFloat = 16
        let bodyHeight = min(body.sizeThatFits(NSSize(width: width - 2 * pad, height: 10_000)).height, 320)
        let height = pad + headerHeight + 6 + bodyHeight + buttonRow + pad

        header.frame = NSRect(x: pad, y: height - pad - headerHeight, width: width - 2 * pad, height: headerHeight)
        body.frame = NSRect(x: pad, y: pad + buttonRow, width: width - 2 * pad, height: bodyHeight)
        var x = width - pad
        for button in buttons {
            button.sizeToFit()
            x -= button.frame.width
            button.frame.origin = NSPoint(x: x, y: pad)
            x -= 8
        }

        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.maxX - width - 12, y: screen.maxY - height - 12, width: width, height: height),
                       display: true)
    }
}
