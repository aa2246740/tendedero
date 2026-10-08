import AppKit
import CoreImage
import ImageIO

// MARK: - Architecture
//
// A fast, in-place annotation editor for a screenshot on the line. The system
// Markup extension takes seconds to appear and has no mosaic or blur brush,
// so this one draws everything itself.
//
// One borderless key panel covers the screen under the pointer:
//
//   backdrop (solid, dark)
//   ├─ CanvasView   the image at its real point size, or fitted to the screen
//   │   ├─ stage    image · marks bitmap · live preview layers
//   │   └─ text     an editable field while a text mark is being typed
//   ├─ Toolbar      a dark HUD pill directly under the image
//   └─ hint line    keyboard shortcuts, plus transient toasts above the bar
//
// Coordinates never flip: the view, its layers and every bitmap use a
// bottom-left origin. While you drag, a mark is a vector shape on a
// CAShapeLayer (GPU-composited, no per-move bitmap copies). On mouse-up it is
// rasterized once into the marks bitmap at the file's own resolution.
//
// Mosaic and blur are a stroked mask over a copy of the whole image that is
// pixellated or blurred once, so the mosaic grid stays aligned across strokes
// and the brush is round, not a trail of square stamps.
//
// Undo and redo keep only the pixels of the dirty rectangle, before and
// after each mark, never a snapshot of the whole bitmap.
//
// Saving goes through ImageIO with the original file's properties, so the
// DPI (Retina screenshots are 144) and the color profile survive the edit.

@MainActor
final class Annotate: NSObject {
    static let shared = Annotate()

    /// Called with the file once the edited image has been written back.
    var onSaved: (URL) -> Void = { _ in }

    /// Whether the editor is on screen. The line stays tucked away meanwhile.
    var isOpen: Bool { panel != nil }

    /// Raw values are what gets remembered between edits; the number keys
    /// follow the toolbar order instead.
    enum Tool: String, CaseIterable {
        case rect, ellipse, arrow, pen, text, mosaic, blur

        var usesColor: Bool { self != .mosaic && self != .blur }

        /// Dragged out from corner to corner; Shift squares or snaps them.
        var isShape: Bool { self == .rect || self == .ellipse || self == .arrow }

        var key: Int { Self.allCases.firstIndex(of: self)! + 1 }

        init?(key: Int) {
            guard Self.allCases.indices.contains(key - 1) else { return nil }
            self = Self.allCases[key - 1]
        }

        var icon: NSImage? {
            let symbol: String
            switch self {
            case .rect: symbol = "rectangle"
            case .ellipse: symbol = "circle"
            case .arrow: symbol = "arrow.up.right"
            case .pen: symbol = "scribble"
            case .text: return Self.letterIcon("T")
            case .mosaic: symbol = "checkerboard.rectangle"
            case .blur: symbol = "drop.halffull"
            }
            return NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        }

        /// SF Symbols has no plain "T"; "textformat" reads as "Aa", which
        /// nobody takes for "add text".
        private static func letterIcon(_ letter: String) -> NSImage {
            let text = NSAttributedString(string: letter, attributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .medium),
                .foregroundColor: NSColor.black,
            ])
            let size = text.size()
            let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { _ in
                text.draw(at: .zero)
                return true
            }
            image.isTemplate = true
            return image
        }

        var title: String {
            switch self {
            case .rect: return L("Rectangle", ["es": "Rectángulo", "zh": "矩形", "zh-Hant": "矩形"])
            case .ellipse: return L("Ellipse", ["es": "Elipse", "zh": "圆形", "zh-Hant": "圓形"])
            case .arrow: return L("Arrow", ["es": "Flecha", "zh": "箭头", "zh-Hant": "箭頭"])
            case .pen: return L("Pen", ["es": "Lápiz", "zh": "画笔", "zh-Hant": "畫筆"])
            case .text: return L("Text", ["es": "Texto", "zh": "文字", "zh-Hant": "文字"])
            case .mosaic: return L("Mosaic", ["es": "Mosaico", "zh": "马赛克", "zh-Hant": "馬賽克"])
            case .blur: return L("Blur", ["es": "Difuminar", "zh": "模糊", "zh-Hant": "模糊"])
            }
        }
    }

    /// Ink colors. Red first: it is what annotations are made of.
    static let palette: [(NSColor, String)] = [
        (NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), L("Red", ["es": "Rojo", "zh": "红色", "zh-Hant": "紅色"])),
        (NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1), L("Yellow", ["es": "Amarillo", "zh": "黄色", "zh-Hant": "黃色"])),
        (NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), L("Green", ["es": "Verde", "zh": "绿色", "zh-Hant": "綠色"])),
        (NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), L("Blue", ["es": "Azul", "zh": "蓝色", "zh-Hant": "藍色"])),
        (NSColor.white, L("White", ["es": "Blanco", "zh": "白色", "zh-Hant": "白色"])),
        (NSColor.black, L("Black", ["es": "Negro", "zh": "黑色", "zh-Hant": "黑色"])),
    ]

    static let sizeNames = [
        L("Thin", ["es": "Fino", "zh": "细", "zh-Hant": "細"]),
        L("Medium", ["es": "Medio", "zh": "中", "zh-Hant": "中"]),
        L("Thick", ["es": "Grueso", "zh": "粗", "zh-Hant": "粗"]),
    ]

    /// The original file and what is needed to write it back the same way.
    private struct Source {
        let url: URL
        let type: CFString
        let properties: [CFString: Any]
    }

    private let ci = CIContext()
    private var panel: NSPanel?
    private var canvas: CanvasView?
    private var source: Source?
    private var toolButtons: [Tool: HUDButton] = [:]
    private var sizeButtons: [DotButton] = []
    private var colorButtons: [DotButton] = []
    private var undoButton: HUDButton?
    private var redoButton: HUDButton?
    private var toast: NSView?
    private var toastAnchor: NSPoint = .zero
    /// Escape with unsaved marks only arms the discard; a second one inside
    /// this window confirms it.
    private var escapeArmedUntil = Date.distantPast

    // The last tool, size and color are remembered between edits.
    private var tool: Tool {
        get { UserDefaults.standard.string(forKey: "annotateTool").flatMap(Tool.init(rawValue:)) ?? .rect }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "annotateTool") }
    }
    private var sizeIndex: Int {
        get { UserDefaults.standard.object(forKey: "annotateSize") as? Int ?? 1 }
        set { UserDefaults.standard.set(max(0, min(2, newValue)), forKey: "annotateSize") }
    }
    private var colorIndex: Int {
        get { min(Self.palette.count - 1, max(0, UserDefaults.standard.integer(forKey: "annotateColor"))) }
        set { UserDefaults.standard.set(newValue, forKey: "annotateColor") }
    }

    // MARK: Opening

    func edit(_ url: URL) {
        close(committing: false, animated: false)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let screen = Self.screenUnderPointer() else {
            NSWorkspace.shared.open(url)
            return
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        source = Source(url: url, type: type, properties: properties)

        // The image's size in points comes from its DPI, so a Retina
        // screenshot opens at the size it was on screen, not doubled.
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let pointsPerPixel = 72 / (dpi > 0 ? dpi : 72)
        let natural = NSSize(width: CGFloat(cg.width) * pointsPerPixel,
                             height: CGFloat(cg.height) * pointsPerPixel)

        // Panel-local geometry: everything is laid out inside the visible
        // frame, clear of the menu bar and the Dock, on whichever screen.
        let local = NSRect(origin: .zero, size: screen.frame.size)
        let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let area = visible.insetBy(dx: 32, dy: 20)

        let bar = makeToolbar()
        let barSize = bar.frame.size
        let gap: CGFloat = 14, hintHeight: CGFloat = 26
        let maxW = area.width, maxH = area.height - barSize.height - gap - hintHeight
        let fit = min(1, maxW / natural.width, maxH / natural.height)
        let size = NSSize(width: max(1, (natural.width * fit).rounded()),
                          height: max(1, (natural.height * fit).rounded()))

        // Image, toolbar and hint form one group, centered in the area.
        let groupHeight = size.height + gap + barSize.height + hintHeight
        let bottom = (area.midY - groupHeight / 2).rounded()
        let imageOrigin = NSPoint(x: (area.midX - size.width / 2).rounded(),
                                  y: bottom + hintHeight + barSize.height + gap)

        let cv = CanvasView(frame: NSRect(origin: imageOrigin, size: size))
        cv.configure(base: cg, ci: ci)
        cv.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        cv.onChange = { [weak self] in self?.refreshHistory() }
        canvas = cv

        let panel = KeyPanel(contentRect: screen.frame, styleMask: [.borderless],
                             backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        // Solid, not translucent: the desktop bleeding through makes the
        // screenshot look washed out.
        panel.isOpaque = true
        panel.backgroundColor = NSColor(white: 0.09, alpha: 1)
        let root = NSView(frame: local)
        panel.contentView = root

        root.addSubview(cv)
        bar.frame.origin = NSPoint(x: clamp((area.midX - barSize.width / 2).rounded(),
                                            visible.minX + 8, visible.maxX - barSize.width - 8),
                                   y: bottom + hintHeight)
        root.addSubview(bar)

        let hint = NSTextField(labelWithString: L(
            "⏎ Done   ·   Esc Cancel   ·   ⌘Z Undo   ·   1–7 Tools   ·   [ ] Size   ·   ⇧ Straight / square / circle",
            ["es": "⏎ Listo   ·   Esc Cancelar   ·   ⌘Z Deshacer   ·   1–7 Herramientas   ·   [ ] Tamaño   ·   ⇧ Recto / cuadrado / círculo",
             "zh": "⏎ 完成   ·   Esc 取消   ·   ⌘Z 撤销   ·   1–7 切换工具   ·   [ ] 粗细   ·   ⇧ 水平/正方形/正圆",
             "zh-Hant": "⏎ 完成   ·   Esc 取消   ·   ⌘Z 撤銷   ·   1–7 切換工具   ·   [ ] 粗細   ·   ⇧ 水平/正方形/正圓"]))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 1, alpha: 0.38)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: (area.midX - hint.frame.width / 2).rounded(), y: bottom)
        root.addSubview(hint)
        // Toasts float just inside the bottom edge of the image.
        toastAnchor = NSPoint(x: area.midX, y: imageOrigin.y + 16)

        self.panel = panel
        select(tool)
        refreshStyle()
        refreshHistory()

        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(cv)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    private static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: Toolbar

    private func makeToolbar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        toolButtons = [:]
        for t in Tool.allCases {
            if t == .mosaic { stack.addArrangedSubview(Self.divider()) }
            let b = HUDButton(image: t.icon, fallback: t.title, tip: "\(t.title)   \(t.key)")
            b.tag = t.key
            b.target = self
            b.action = #selector(pickTool(_:))
            toolButtons[t] = b
            stack.addArrangedSubview(b)
        }

        stack.addArrangedSubview(Self.divider())
        sizeButtons = []
        for (i, d) in [CGFloat(4), 7, 10].enumerated() {
            let b = DotButton(color: .white, diameter: d, tip: Self.sizeNames[i] + (i == 0 ? "   [" : i == 2 ? "   ]" : ""), width: 24)
            b.tag = i
            b.target = self
            b.action = #selector(pickSize(_:))
            sizeButtons.append(b)
            stack.addArrangedSubview(b)
        }

        stack.addArrangedSubview(Self.divider())
        colorButtons = []
        for (i, entry) in Self.palette.enumerated() {
            let b = DotButton(color: entry.0, diameter: 14, tip: entry.1, width: 24)
            b.tag = i
            b.target = self
            b.action = #selector(pickColor(_:))
            colorButtons.append(b)
            stack.addArrangedSubview(b)
        }

        stack.addArrangedSubview(Self.divider())
        let undo = HUDButton(symbol: "arrow.uturn.backward", fallback: "↶",
                             tip: L("Undo", ["es": "Deshacer", "zh": "撤销", "zh-Hant": "撤銷"]) + "   ⌘Z")
        undo.target = self
        undo.action = #selector(undo(_:))
        let redo = HUDButton(symbol: "arrow.uturn.forward", fallback: "↷",
                             tip: L("Redo", ["es": "Rehacer", "zh": "重做", "zh-Hant": "重做"]) + "   ⇧⌘Z")
        redo.target = self
        redo.action = #selector(redo(_:))
        undoButton = undo
        redoButton = redo
        stack.addArrangedSubview(undo)
        stack.addArrangedSubview(redo)

        stack.addArrangedSubview(Self.divider())
        let cancel = HUDButton(symbol: "xmark", fallback: "✕",
                               tip: L("Discard changes", ["es": "Descartar cambios", "zh": "放弃修改", "zh-Hant": "放棄修改"]) + "   Esc")
        cancel.target = self
        cancel.action = #selector(cancel(_:))
        stack.addArrangedSubview(cancel)
        let done = DoneButton(title: L("Done", ["es": "Listo", "zh": "完成", "zh-Hant": "完成"]),
                              tip: L("Save to the file", ["es": "Guardar en el archivo", "zh": "保存到原文件", "zh-Hant": "儲存到原檔案"]) + "   ⏎")
        done.target = self
        done.action = #selector(commit(_:))
        stack.addArrangedSubview(done)
        stack.setCustomSpacing(6, after: cancel)

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        bar.layer?.cornerRadius = 12
        bar.layer?.cornerCurve = .continuous
        bar.layer?.borderWidth = 0.5
        bar.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        bar.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.5)
            s.shadowBlurRadius = 16
            s.shadowOffset = NSSize(width: 0, height: -4)
            return s
        }()
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        bar.frame.size = stack.fittingSize
        return bar
    }

    private static func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 18),
        ])
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(v)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: 11),
            wrap.heightAnchor.constraint(equalToConstant: 32),
            v.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
        ])
        return wrap
    }

    // MARK: Actions

    @objc private func pickTool(_ sender: NSButton) {
        if let t = Tool(key: sender.tag) { select(t) }
    }

    @objc private func pickSize(_ sender: NSButton) {
        sizeIndex = sender.tag
        refreshStyle()
    }

    @objc private func pickColor(_ sender: NSButton) {
        colorIndex = sender.tag
        // Picking a color while on mosaic or blur means you want to draw:
        // back to the last tool that uses ink.
        if !tool.usesColor { select(lastInkTool) }
        refreshStyle()
    }

    private var lastInkTool: Tool = .rect

    private func select(_ t: Tool) {
        tool = t
        if t.usesColor { lastInkTool = t }
        canvas?.tool = t
        for (k, b) in toolButtons { b.isOn = k == t }
        // Mosaic and blur have no color: the swatches step back.
        for b in colorButtons { b.isDimmed = !t.usesColor }
    }

    private func refreshStyle() {
        for (i, b) in sizeButtons.enumerated() { b.isOn = i == sizeIndex }
        for (i, b) in colorButtons.enumerated() { b.isOn = i == colorIndex }
        canvas?.style = CanvasView.Style(color: Self.palette[colorIndex].0, size: sizeIndex)
    }

    private func refreshHistory() {
        undoButton?.isEnabled = canvas?.canUndo ?? false
        redoButton?.isEnabled = canvas?.canRedo ?? false
    }

    @objc private func undo(_ sender: Any? = nil) { canvas?.undo() }

    @objc private func redo(_ sender: Any? = nil) { canvas?.redo() }

    @objc private func cancel(_ sender: Any? = nil) { close(committing: false) }

    @objc private func commit(_ sender: Any? = nil) { close(committing: true) }

    /// Escape never throws work away by surprise: with marks on the image,
    /// the first press only asks for a second.
    private func escape() {
        guard canvas?.isDirty == true, Date() >= escapeArmedUntil else {
            cancel()
            return
        }
        escapeArmedUntil = Date().addingTimeInterval(2)
        showToast(L("Press Esc again to discard your changes",
                    ["es": "Pulsa Esc otra vez para descartar los cambios",
                     "zh": "再按一次 Esc 放弃修改",
                     "zh-Hant": "再按一次 Esc 放棄修改"]))
    }

    /// Canvas keyboard entry. Text being typed gets its keys first.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 53: escape(); return true          // Esc
        case 36, 76: commit(); return true      // Return, Enter
        default: break
        }
        if flags.contains(.command) {
            switch chars {
            case "z": flags.contains(.shift) ? redo() : undo(); return true
            case "s": commit(); return true
            default: return false
            }
        }
        if let n = Int(chars), let t = Tool(key: n) { select(t); return true }
        if chars == "[" { sizeIndex -= 1; refreshStyle(); return true }
        if chars == "]" { sizeIndex += 1; refreshStyle(); return true }
        return false
    }

    private func showToast(_ text: String) {
        toast?.removeFromSuperview()
        guard let root = panel?.contentView else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let pill = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 28, height: 32))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0.24, alpha: 0.96).cgColor
        pill.layer?.cornerRadius = 16
        label.frame.origin = NSPoint(x: 14, y: (32 - label.frame.height) / 2)
        pill.addSubview(label)
        pill.frame.origin = NSPoint(x: (toastAnchor.x - pill.frame.width / 2).rounded(), y: toastAnchor.y)
        root.addSubview(pill)
        toast = pill
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self, weak pill] in
            guard let pill else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                pill.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    pill.removeFromSuperview()
                    if self?.toast === pill { self?.toast = nil }
                }
            })
        }
    }

    // MARK: Closing and saving

    private func close(committing: Bool, animated: Bool = true) {
        canvas?.finishText()
        // Nothing drawn means nothing to write: the file is left untouched.
        if committing, let source, let canvas, canvas.isDirty, let baked = canvas.bake() {
            write(baked, to: source)
        }
        guard let panel else { return }
        self.panel = nil
        canvas = nil
        source = nil
        toast = nil
        toolButtons = [:]
        sizeButtons = []
        colorButtons = []
        undoButton = nil
        redoButton = nil
        escapeArmedUntil = .distantPast
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func write(_ image: CGImage, to source: Source) {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, source.type, 1, nil) else {
            NSSound.beep()
            return
        }
        var properties = source.properties
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            NSSound.beep()
            return
        }
        do {
            try (data as Data).write(to: source.url, options: .atomic)
            onSaved(source.url)
        } catch {
            NSSound.beep()
        }
    }
}

private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    max(lo, min(hi, v))
}

/// A borderless panel that still accepts keystrokes (borderless windows
/// refuse key status by default, which would silence the text tool).
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Toolbar controls

/// An icon button for the dark HUD: a soft highlight on hover, a solid one
/// when it is the current tool.
private final class HUDButton: NSButton {
    var isOn = false { didSet { refresh() } }
    private var hovering = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?

    override var isEnabled: Bool { didSet { refresh() } }

    convenience init(symbol: String, fallback: String, tip: String) {
        self.init(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)), fallback: fallback, tip: tip)
    }

    init(image: NSImage?, fallback: String, tip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        if let image {
            self.image = image
            title = ""
            imagePosition = .imageOnly
        } else {
            title = fallback
        }
        imageScaling = .scaleNone
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        refusesFirstResponder = true
        toolTip = tip
        setAccessibilityLabel(tip)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func refresh() {
        let fill: NSColor = isOn ? NSColor(white: 1, alpha: 0.20)
            : (hovering && isEnabled ? NSColor(white: 1, alpha: 0.08) : .clear)
        layer?.backgroundColor = fill.cgColor
        contentTintColor = isOn ? .white : NSColor(white: 1, alpha: isEnabled ? 0.72 : 0.22)
    }
}

/// A round swatch: a color, or a white dot whose size is the stroke size.
/// The current one wears a ring.
private final class DotButton: NSButton {
    let dotColor: NSColor
    let diameter: CGFloat
    var isOn = false { didSet { needsDisplay = true } }
    var isDimmed = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(color: NSColor, diameter: CGFloat, tip: String, width: CGFloat) {
        dotColor = color
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        refusesFirstResponder = true
        toolTip = tip
        setAccessibilityLabel(tip)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isDimmed ? 0.3 : 1
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let r = diameter / 2
        if isOn && !isDimmed {
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r - 4, y: c.y - r - 4,
                                                   width: diameter + 8, height: diameter + 8))
            ring.lineWidth = 1.5
            NSColor(white: 1, alpha: 0.9).setStroke()
            ring.stroke()
        } else if hovering && !isDimmed {
            let halo = NSBezierPath(ovalIn: NSRect(x: c.x - r - 4, y: c.y - r - 4,
                                                   width: diameter + 8, height: diameter + 8))
            NSColor(white: 1, alpha: 0.08).setFill()
            halo.fill()
        }
        let dot = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: diameter, height: diameter))
        dotColor.withAlphaComponent(alpha).setFill()
        dot.fill()
        // An edge so black still reads on the dark bar, and white on light.
        dot.lineWidth = 1
        NSColor(white: 1, alpha: 0.28 * alpha).setStroke()
        dot.stroke()
    }
}

/// The one prominent button: an accent-filled "✓ Done". It draws itself,
/// because NSButton's own image-and-title layout pushes the checkmark and
/// the label to opposite ends once the button is wider than its content.
private final class DoneButton: NSButton {
    private let label: NSAttributedString
    private static let labelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let check: NSImage?
    private let gap: CGFloat = 5
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(title: String, tip: String) {
        label = NSAttributedString(string: title, attributes: [.font: Self.labelFont, .foregroundColor: NSColor.white])
        check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
            .map { symbol in
                NSImage(size: symbol.size, flipped: false) { r in
                    symbol.draw(in: r)
                    NSColor.white.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
            }
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        refusesFirstResponder = true
        toolTip = tip
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        let content = (check.map { $0.size.width + gap } ?? 0) + label.size().width
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ceil(content) + 28),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let fill = isHighlighted ? accent.blended(withFraction: 0.18, of: .black)
            : hovering ? accent.blended(withFraction: 0.10, of: .white) : accent
        (fill ?? accent).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()

        // Checkmark and label sit as one centered group, both centered on
        // the label's cap height so the glyphs line up optically.
        let textWidth = label.size().width
        let checkSize = check?.size ?? .zero
        let content = (check == nil ? 0 : checkSize.width + gap) + textWidth
        var x = ((bounds.width - content) / 2).rounded()
        let mid = bounds.midY
        if let check {
            check.draw(in: NSRect(x: x, y: (mid - checkSize.height / 2).rounded(),
                                  width: checkSize.width, height: checkSize.height))
            x += checkSize.width + gap
        }
        let baseline = (mid - Self.labelFont.capHeight / 2).rounded()
        label.draw(at: NSPoint(x: x, y: baseline + Self.labelFont.descender))
    }
}

// MARK: - Canvas

/// The image plus everything painted on it. See the architecture note at
/// the top of the file.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    struct Style {
        var color: NSColor
        /// 0 thin, 1 medium, 2 thick.
        var size: Int
    }

    var tool: Annotate.Tool = .rect {
        didSet {
            finishText()
            window?.invalidateCursorRects(for: self)
        }
    }

    var style = Style(color: .systemRed, size: 1) {
        didSet {
            window?.invalidateCursorRects(for: self)
            restyleText()
        }
    }

    var onKey: (NSEvent) -> Bool = { _ in false }
    /// Undo/redo availability may have changed.
    var onChange: () -> Void = {}

    // Sizes in on-screen points, so marks look the same whatever the zoom.
    private static let strokePoints: [CGFloat] = [2, 4, 7]
    private static let brushPoints: [CGFloat] = [14, 28, 48]
    private static let fontPoints: [CGFloat] = [14, 20, 30]

    private var base: CGImage!
    private var ci: CIContext!
    private var space: CGColorSpace!
    private var marks: CGContext!
    private var filtered: [Annotate.Tool: CGImage] = [:]

    /// One undoable step: the pixels of `rect` in the marks bitmap.
    private struct Edit {
        let rect: CGRect
        let before: CGImage?
        let after: CGImage?
    }
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private let maxUndo = 60

    /// Everything a mark needs to be previewed and rasterized.
    private enum Mark {
        case stroke(CGPath, width: CGFloat, color: CGColor, join: CGLineJoin = .round)
        case fill(CGPath, color: CGColor)
        case brush(CGPath, width: CGFloat, image: CGImage)
        /// Text draws itself: the field's own cell, replayed at image
        /// resolution, so the set-down text is exactly what was typed.
        case text(bounds: CGRect, draw: (CGContext) -> Void)
    }

    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var points: [CGPoint] = []
    private var editingText: NSTextField?

    private let stage = Stage()
    private let imageLayer = CALayer()
    private let marksLayer = CALayer()
    private let liveShape = CAShapeLayer()
    private let liveFiltered = CALayer()
    private let liveMask = CAShapeLayer()
    private var cursors: [CGFloat: NSCursor] = [:]

    var canUndo: Bool { !undoStack.isEmpty || editingText != nil }
    var canRedo: Bool { !redoStack.isEmpty }
    var isDirty: Bool { !undoStack.isEmpty }

    /// While text is being typed the field keeps the keyboard: a click on
    /// the canvas then sets the text down instead of stealing focus.
    override var acceptsFirstResponder: Bool { editingText == nil }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }

    private var imageRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }
    /// On-screen points per image pixel.
    private var scale: CGFloat { bounds.width / CGFloat(base.width) }
    private var strokeWidth: CGFloat { Self.strokePoints[style.size] / scale }
    private var brushWidth: CGFloat { Self.brushPoints[style.size] / scale }

    func configure(base: CGImage, ci: CIContext) {
        self.base = base
        self.ci = ci
        let rgb = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        space = rgb ?? CGColorSpace(name: CGColorSpace.sRGB)!

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // A hairline and a shadow, so a dark screenshot still has an edge on
        // the dark backdrop.
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.55)
            s.shadowBlurRadius = 24
            s.shadowOffset = NSSize(width: 0, height: -6)
            return s
        }()

        stage.frame = bounds
        stage.autoresizingMask = [.width, .height]
        stage.wantsLayer = true
        addSubview(stage)
        for l in [imageLayer, marksLayer, liveFiltered, liveShape] as [CALayer] {
            l.frame = bounds
            stage.layer?.addSublayer(l)
        }
        imageLayer.contents = base
        imageLayer.magnificationFilter = .nearest
        liveShape.fillColor = nil
        liveShape.lineCap = .round
        liveShape.lineJoin = .round
        liveMask.frame = bounds
        liveMask.fillColor = nil
        liveMask.strokeColor = NSColor.black.cgColor
        liveMask.lineCap = .round
        liveMask.lineJoin = .round
        liveFiltered.mask = liveMask

        marks = CGContext(data: nil, width: base.width, height: base.height,
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        return CGPoint(x: v.x / scale, y: v.y / scale)
    }

    // MARK: Cursor

    override func resetCursorRects() {
        switch tool {
        case .text: addCursorRect(bounds, cursor: .iBeam)
        case .mosaic, .blur: addCursorRect(bounds, cursor: brushCursor(Self.brushPoints[style.size]))
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    /// A ring the size of the brush, legible on light and dark pixels.
    private func brushCursor(_ diameter: CGFloat) -> NSCursor {
        if let c = cursors[diameter] { return c }
        let side = diameter + 4
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 3
            NSColor.black.withAlphaComponent(0.55).setStroke()
            ring.stroke()
            ring.lineWidth = 1.25
            NSColor.white.setStroke()
            ring.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
        cursors[diameter] = cursor
        return cursor
    }

    // MARK: Filters for mosaic and blur

    /// The whole image pixellated or blurred once, at full resolution. The
    /// mosaic grid is anchored at the image origin, so every stroke lines up.
    private func filteredImage(for tool: Annotate.Tool) -> CGImage? {
        if let f = filtered[tool] { return f }
        let input = CIImage(cgImage: base).clampedToExtent()
        let output: CIImage
        if tool == .mosaic {
            output = input.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(6, (11 / scale).rounded()),
                kCIInputCenterKey: CIVector(x: 0, y: 0),
            ])
        } else {
            output = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(6, 8 / scale)])
        }
        let image = ci.createCGImage(output.cropped(to: imageRect), from: imageRect,
                                     format: .RGBA8, colorSpace: space)
        filtered[tool] = image
        return image
    }

    // MARK: Building marks

    /// A smooth path through the pointer samples: quadratic curves between
    /// midpoints, so fast strokes do not turn into polygons.
    private static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 1 else {
            // A single click still leaves a round dot.
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// A filled arrow with a slightly tapered shaft and a solid head.
    private static func arrowPath(from a: CGPoint, to b: CGPoint, width w: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return path }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let head = min(length * 0.65, max(w * 4.2, 10))
        let headHalf = head * 0.5
        let neckHalf = w * 0.6
        let tailHalf = w * 0.25
        let neck = CGPoint(x: b.x - ux * head * 0.82, y: b.y - uy * head * 0.82)
        let wing = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        func p(_ o: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: o.x + nx * k, y: o.y + ny * k) }
        path.move(to: p(a, tailHalf))
        path.addLine(to: p(neck, neckHalf))
        path.addLine(to: p(wing, headHalf))
        path.addLine(to: b)
        path.addLine(to: p(wing, -headHalf))
        path.addLine(to: p(neck, -neckHalf))
        path.addLine(to: p(a, -tailHalf))
        path.closeSubpath()
        return path
    }

    /// Shift makes squares and circles, and snaps arrows to 45 degrees.
    private func constrained(_ a: CGPoint, _ b: CGPoint, shift: Bool) -> CGPoint {
        guard shift else { return b }
        let dx = b.x - a.x, dy = b.y - a.y
        if tool == .rect || tool == .ellipse {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
        }
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }

    private func currentMark(shift: Bool) -> Mark? {
        guard let a = dragStart, var b = dragEnd else { return nil }
        let color = style.color.cgColor
        switch tool {
        case .rect, .ellipse:
            b = constrained(a, b, shift: shift)
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            guard r.width > 2 || r.height > 2 else { return nil }
            return tool == .rect
                ? .stroke(CGPath(rect: r, transform: nil), width: strokeWidth, color: color, join: .miter)
                : .stroke(CGPath(ellipseIn: r, transform: nil), width: strokeWidth, color: color)
        case .arrow:
            b = constrained(a, b, shift: shift)
            guard hypot(b.x - a.x, b.y - a.y) > strokeWidth * 2 else { return nil }
            return .fill(Self.arrowPath(from: a, to: b, width: strokeWidth), color: color)
        case .pen:
            return .stroke(Self.smoothPath(points), width: strokeWidth, color: color)
        case .mosaic, .blur:
            guard let image = filteredImage(for: tool) else { return nil }
            return .brush(Self.smoothPath(points), width: brushWidth, image: image)
        case .text:
            return nil
        }
    }

    // MARK: Live preview

    private func showLive(_ mark: Mark?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        liveShape.path = nil
        liveMask.path = nil
        guard let mark else { return }
        var t = CGAffineTransform(scaleX: scale, y: scale)
        switch mark {
        case let .stroke(path, width, color, join):
            liveShape.path = path.copy(using: &t)
            liveShape.lineWidth = width * scale
            liveShape.lineJoin = join == .miter ? .miter : .round
            liveShape.strokeColor = color
            liveShape.fillColor = nil
        case let .fill(path, color):
            liveShape.path = path.copy(using: &t)
            liveShape.lineWidth = 0
            liveShape.strokeColor = nil
            liveShape.fillColor = color
        case let .brush(path, width, image):
            liveFiltered.contents = image
            liveMask.path = path.copy(using: &t)
            liveMask.lineWidth = width * scale
        case .text:
            break
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // A click while typing just sets the text down.
        if editingText != nil {
            finishText()
            return
        }
        window?.makeFirstResponder(self)
        if tool == .text {
            placeText(at: convert(event.locationInWindow, from: nil))
            return
        }
        let p = imagePoint(event)
        dragStart = p
        dragEnd = p
        points = [p]
        if tool == .pen || tool == .mosaic || tool == .blur {
            showLive(currentMark(shift: false))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        let p = imagePoint(event)
        dragEnd = p
        if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 0.75 / scale {
            points.append(p)
        }
        showLive(currentMark(shift: event.modifierFlags.contains(.shift)))
    }

    override func flagsChanged(with event: NSEvent) {
        guard dragStart != nil, tool.isShape else { return super.flagsChanged(with: event) }
        showLive(currentMark(shift: event.modifierFlags.contains(.shift)))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        if tool.isShape { dragEnd = imagePoint(event) }
        let mark = currentMark(shift: event.modifierFlags.contains(.shift))
        dragStart = nil
        dragEnd = nil
        points = []
        if let mark { commit(mark) }
        showLive(nil)
    }

    // MARK: Text

    private var fontSize: CGFloat { Self.fontPoints[style.size] }

    private func textFont(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    /// A soft dark shadow lifts colored and white ink off any screenshot.
    /// Only near-black ink gets a light halo: a white glow around red or
    /// blue on a dark screenshot just reads as a smudge.
    private func halo(for color: NSColor, blur: CGFloat) -> NSShadow {
        let s = NSShadow()
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let dark = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent < 0.2
        s.shadowColor = dark ? NSColor.white.withAlphaComponent(0.7) : NSColor.black.withAlphaComponent(0.5)
        s.shadowBlurRadius = blur
        s.shadowOffset = .zero
        return s
    }

    private func placeText(at viewPoint: NSPoint) {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.placeholderString = L("Type…", ["es": "Escribe…", "zh": "输入文字…", "zh-Hant": "輸入文字…"])
        field.wantsLayer = true
        field.layer?.cornerRadius = 3
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor(white: 1, alpha: 0.55).cgColor
        field.layer?.backgroundColor = NSColor(white: 0, alpha: 0.12).cgColor
        addSubview(field)
        editingText = field
        restyleText()
        // The click marks the start of the text, centered on its line.
        field.setFrameOrigin(NSPoint(x: viewPoint.x - 3, y: viewPoint.y - field.frame.height / 2))
        window?.makeFirstResponder(field)
        onChange()
    }

    /// The field follows the current color and size while you type.
    private func restyleText() {
        guard let field = editingText else { return }
        field.font = textFont(fontSize)
        field.textColor = style.color
        field.shadow = halo(for: style.color, blur: 2)
        sizeField(field)
    }

    private func sizeField(_ field: NSTextField) {
        let text = field.stringValue.isEmpty ? (field.placeholderString ?? "") : field.stringValue
        let font = field.font ?? textFont(fontSize)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let height = ceil(font.ascender - font.descender + font.leading) + 4
        let center = field.frame.midY
        field.frame.size = NSSize(width: ceil(width) + 12, height: height)
        if field.superview != nil { field.frame.origin.y = (center - height / 2).rounded() }
    }

    func controlTextDidChange(_ note: Notification) {
        if let field = editingText { sizeField(field) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelText()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finishText()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ note: Notification) {
        finishText()
    }

    private func cancelText() {
        guard let field = editingText else { return }
        editingText = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        onChange()
    }

    func finishText() {
        guard let field = editingText else { return }
        editingText = nil
        let text = field.stringValue
        // Ending the edit hands the text from the field editor to the cell.
        window?.makeFirstResponder(self)
        field.stringValue = text
        field.removeFromSuperview()
        defer { onChange() }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, let cell = field.cell else { return }

        // Replay the cell in the field's own flipped space, scaled from view
        // points to image pixels. Shadows ignore the transform, so the halo
        // is sized in pixels.
        let frame = field.frame
        let s = scale
        let halo = halo(for: field.textColor ?? style.color, blur: 2 / s)
        let bounds = CGRect(x: frame.minX / s, y: frame.minY / s,
                            width: frame.width / s, height: frame.height / s)
            .insetBy(dx: -4 / s, dy: -4 / s)
        commit(.text(bounds: bounds) { ctx in
            ctx.translateBy(x: frame.minX / s, y: frame.maxY / s)
            ctx.scaleBy(x: 1 / s, y: -1 / s)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            halo.set()
            cell.drawInterior(withFrame: NSRect(origin: .zero, size: frame.size), in: field)
            NSGraphicsContext.restoreGraphicsState()
        })
    }

    // MARK: Rasterizing and history

    private func bounds(of mark: Mark) -> CGRect {
        switch mark {
        case let .stroke(path, width, _, join):
            return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: join, miterLimit: 10)
                .boundingBoxOfPath
        case let .brush(path, width, _):
            return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .boundingBoxOfPath
        case let .fill(path, _):
            return path.boundingBoxOfPath
        case let .text(bounds, _):
            return bounds
        }
    }

    private func draw(_ mark: Mark, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch mark {
        case let .stroke(path, width, color, join):
            ctx.addPath(path)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(join)
            ctx.setStrokeColor(color)
            ctx.strokePath()
        case let .fill(path, color):
            ctx.addPath(path)
            ctx.setFillColor(color)
            ctx.fillPath()
        case let .brush(path, width, image):
            ctx.addPath(path)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.draw(image, in: imageRect)
        case let .text(_, drawText):
            drawText(ctx)
        }
    }

    private func commit(_ mark: Mark) {
        let dirty = bounds(of: mark).insetBy(dx: -2, dy: -2).integral.intersection(imageRect)
        guard !dirty.isNull, dirty.width >= 1, dirty.height >= 1 else { return }
        let before = snapshot(dirty)
        draw(mark, in: marks)
        let after = snapshot(dirty)
        undoStack.append(Edit(rect: dirty, before: before, after: after))
        if undoStack.count > maxUndo { undoStack.removeFirst(undoStack.count - maxUndo) }
        redoStack.removeAll()
        showMarks()
        onChange()
    }

    /// A detached copy of one rectangle of the marks bitmap.
    private func snapshot(_ rect: CGRect) -> CGImage? {
        // CGImage cropping counts rows from the top.
        let flipped = CGRect(x: rect.minX, y: CGFloat(base.height) - rect.maxY,
                             width: rect.width, height: rect.height)
        guard let crop = marks.makeImage()?.cropping(to: flipped),
              let ctx = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(origin: .zero, size: rect.size))
        return ctx.makeImage()
    }

    private func restore(_ image: CGImage?, in rect: CGRect) {
        marks.saveGState()
        marks.clip(to: rect)
        marks.clear(rect)
        if let image { marks.draw(image, in: rect) }
        marks.restoreGState()
        showMarks()
    }

    private func showMarks() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marksLayer.contents = marks.makeImage()
        CATransaction.commit()
    }

    func undo() {
        if editingText != nil {
            cancelText()
            return
        }
        guard let edit = undoStack.popLast() else { return }
        restore(edit.before, in: edit.rect)
        redoStack.append(edit)
        onChange()
    }

    func redo() {
        guard editingText == nil, let edit = redoStack.popLast() else { return }
        restore(edit.after, in: edit.rect)
        undoStack.append(edit)
        onChange()
    }

    /// The image with every mark composited, at the file's own resolution.
    func bake() -> CGImage? {
        guard let marksImage = marks.makeImage() else { return nil }
        let opaque = [.none, .noneSkipLast, .noneSkipFirst].contains(base.alphaInfo)
        let info = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
        let out = CGContext(data: nil, width: base.width, height: base.height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: info.rawValue)
        out?.draw(base, in: imageRect)
        out?.draw(marksImage, in: imageRect)
        return out?.makeImage()
    }
}

/// Hosts the canvas layers. Never takes a click: those belong to the canvas.
private final class Stage: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
