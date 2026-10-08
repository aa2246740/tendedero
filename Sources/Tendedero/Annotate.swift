import AppKit
import CoreImage

/// A fast, in-place annotation editor for a screenshot on the line. The
/// system Markup extension takes seconds to appear and has no mosaic or
/// smear tool at all, so this one draws everything itself: a dim backdrop,
/// the image centered, and a pill toolbar underneath — pick a tool, drag
/// on the image, Done writes back to the same file.
@MainActor
final class Annotate: NSObject {
    static let shared = Annotate()

    /// Called with the file once the edited image has been written back.
    var onSaved: (URL) -> Void = { _ in }

    enum Tool: Int { case mosaic = 1, smear, pen, text }

    private let ci = CIContext()
    private var panel: NSPanel?
    private var canvas: CanvasView?
    private var target: URL?
    private var toolButtons: [NSButton] = []

    // MARK: Opening

    func edit(_ url: URL) {
        close(committing: false)
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let screen = NSScreen.main else {
            NSWorkspace.shared.open(url)
            return
        }
        target = url

        // The canvas fits the image inside most of the screen, never above
        // its real size — scaling is display-only, marks bake at full res.
        let maxW = screen.frame.width * 0.78, maxH = screen.frame.height * 0.58
        let fit = min(1, min(maxW / CGFloat(cg.width), maxH / CGFloat(cg.height)))
        let size = NSSize(width: CGFloat(cg.width) * fit, height: CGFloat(cg.height) * fit)

        let cv = CanvasView(frame: NSRect(origin: .zero, size: size))
        cv.configure(base: cg, ci: ci)
        cv.onKey = { [weak self] event in self?.keyDown(event) ?? false }
        canvas = cv

        let bar = toolbar()
        let barSize = bar.fittingSize

        let panel = KeyPanel(contentRect: screen.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let backdrop = NSVisualEffectView(frame: screen.frame)
        backdrop.material = .hudWindow
        backdrop.state = .active
        backdrop.alphaValue = 0.92
        panel.contentView = backdrop

        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.midY - size.height / 2 + barSize.height / 2 + 20)
        cv.frame.origin = origin
        backdrop.addSubview(cv)
        bar.frame.origin = NSPoint(x: screen.frame.midX - barSize.width / 2,
                                   y: origin.y - barSize.height - 12)
        backdrop.addSubview(bar)
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(cv)
        select(.mosaic)
    }

    private func toolbar() -> NSView {
        let entries: [(Tool, String, String)] = [
            (.mosaic, L("Mosaic", ["es": "Mosaico", "zh": "马赛克", "zh-Hant": "馬賽克"]), "rectangle.fill"),
            (.smear, L("Smear", ["es": "Difuminar", "zh": "涂抹", "zh-Hant": "塗抹"]), "drop.fill"),
            (.pen, L("Pen", ["es": "Lápiz", "zh": "画笔", "zh-Hant": "畫筆"]), "pencil.tip"),
            (.text, L("Text", ["es": "Texto", "zh": "文字", "zh-Hant": "文字"]), "textformat"),
        ]
        let bar = NSView()
        var x: CGFloat = 12
        toolButtons = []
        for (tool, title, symbol) in entries {
            let b = NSButton(title: title, target: self, action: #selector(pickTool(_:)))
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            b.imagePosition = .imageLeading
            b.bezelStyle = .inline
            b.isBordered = false
            b.tag = tool.rawValue
            b.setButtonType(.pushOnPushOff)
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.sizeToFit()
            b.frame.origin = NSPoint(x: x, y: 10)
            bar.addSubview(b); toolButtons.append(b)
            x += b.frame.width + 14
        }
        x += 6
        for (title, symbol, action) in [
            (L("Undo", ["es": "Deshacer", "zh": "撤销", "zh-Hant": "撤銷"]), "arrow.uturn.backward", #selector(undo)),
            (L("Cancel", ["es": "Cancelar", "zh": "取消", "zh-Hant": "取消"]), "xmark", #selector(cancel)),
            (L("Done", ["es": "Listo", "zh": "完成", "zh-Hant": "完成"]), "checkmark", #selector(commit)),
        ] as [(String, String, Selector)] {
            let b = NSButton(title: title, target: self, action: action)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            b.imagePosition = .imageLeading
            b.bezelStyle = .inline
            b.isBordered = false
            b.font = .systemFont(ofSize: 12, weight: .medium)
            if action == #selector(commit) {
                b.font = .systemFont(ofSize: 12, weight: .semibold)
                b.contentTintColor = .systemGreen
            }
            b.sizeToFit()
            b.frame.origin = NSPoint(x: x, y: 10)
            bar.addSubview(b)
            x += b.frame.width + 14
        }
        bar.frame = NSRect(x: 0, y: 0, width: x + 2, height: 38)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.85).cgColor
        bar.layer?.cornerRadius = 19
        return bar
    }

    // MARK: Actions

    @objc private func pickTool(_ sender: NSButton) {
        if let t = Tool(rawValue: sender.tag) { select(t) }
    }

    private func select(_ tool: Tool) {
        canvas?.tool = tool
        for b in toolButtons {
            let on = b.tag == tool.rawValue
            b.state = on ? .on : .off
            b.contentTintColor = on ? .controlAccentColor : .labelColor
        }
    }

    @objc private func undo() { canvas?.undo() }

    @objc private func cancel() { close(committing: false) }

    @objc private func commit() { close(committing: true) }

    /// Canvas keyboard entry: Escape cancels, Cmd-Z undoes, Return saves,
    /// digits pick the tool.
    func keyDown(_ event: NSEvent) -> Bool {
        switch (event.keyCode, event.modifierFlags.contains(.command)) {
        case (53, _): cancel(); return true            // Esc
        case (36, _): commit(); return true            // Return
        case (6, true): undo(); return true            // Cmd-Z
        case (18, false): select(.mosaic); return true // 1
        case (11, false): select(.smear); return true  // 2
        case (35, false): select(.pen); return true    // 3
        case (17, false): select(.text); return true   // 4
        default: return false
        }
    }

    // MARK: Closing and saving

    private func close(committing: Bool) {
        if committing, let target, let canvas,
           let baked = canvas.bake() {
            write(baked, to: target)
        }
        panel?.orderOut(nil)
        panel = nil
        canvas = nil
        target = nil
    }

    private func write(_ image: CGImage, to target: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        let jpeg = ["jpg", "jpeg"].contains(target.pathExtension.lowercased())
        guard let data = rep.representation(using: jpeg ? .jpeg : .png, properties: [:]) else { return }
        do {
            try data.write(to: target, options: .atomic)
            onSaved(target)
        } catch {
            NSSound.beep()
        }
    }
}

/// A borderless panel that still accepts keystrokes (borderless windows
/// refuse key status by default, which would silence the text tool).
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Canvas

/// The image plus everything painted on it. All coordinates are plain
/// CoreGraphics space (y grows up, like the view) so nothing flips:
/// marks live in a persistent bitmap at image resolution, the in-flight
/// stroke lives in a small bitmap bounded to where the pointer has been,
/// and undo is a stack of states captured right before each stroke.
@MainActor
final class CanvasView: NSView {
    var tool: Annotate.Tool = .mosaic
    var onKey: (NSEvent) -> Bool = { _ in false }

    private var base: CGImage!
    private var ci: CIContext!
    private var marksCtx: CGContext!
    private var states: [CGImage] = []
    private let maxUndo = 16

    private var strokeCtx: CGContext?
    private var strokeBounds: CGRect = .zero
    private var penLast: CGPoint?
    private var editingText: NSTextField?

    private let imageLayer = CALayer()
    private let marksLayer = CALayer()
    private let liveLayer = CALayer()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }

    private var imageRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }
    private var viewScale: CGFloat { bounds.width / CGFloat(base.width) }
    private var stamp: CGFloat { max(18, CGFloat(base.width) / 48) }
    private var penWidth: CGFloat { max(4, CGFloat(base.width) / 400) }

    func configure(base: CGImage, ci: CIContext) {
        self.base = base
        self.ci = ci
        wantsLayer = true
        imageLayer.contents = base
        imageLayer.frame = bounds
        marksLayer.frame = bounds
        liveLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(marksLayer)
        layer?.addSublayer(liveLayer)
        marksCtx = CGContext(data: nil, width: base.width, height: base.height,
                             bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private func imagePoint(_ viewPoint: NSPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / viewScale, y: viewPoint.y / viewScale)
    }

    // MARK: The in-flight stroke bitmap

    private func ensureStrokeContext(covering rect: CGRect) {
        if strokeCtx != nil && strokeBounds.contains(rect) { return }
        let grow = strokeBounds.union(rect).insetBy(dx: -stamp, dy: -stamp)
            .integral.intersection(imageRect)
        guard !grow.isEmpty else { return }
        let ctx = CGContext(data: nil, width: Int(grow.width), height: Int(grow.height),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        // Keep what the stroke already painted when the bitmap grows.
        if let old = strokeCtx, let img = old.makeImage() {
            ctx?.draw(img, in: CGRect(origin: CGPoint(x: strokeBounds.origin.x - grow.origin.x,
                                                    y: strokeBounds.origin.y - grow.origin.y),
                                      size: strokeBounds.size))
        }
        ctx?.translateBy(x: -grow.origin.x, y: -grow.origin.y)
        strokeCtx = ctx
        strokeBounds = grow
        liveLayer.frame = CGRect(x: grow.origin.x * viewScale,
                                 y: grow.origin.y * viewScale,
                                 width: grow.width * viewScale,
                                 height: grow.height * viewScale)
    }

    // MARK: Mosaic and smear stamps

    private func stamp(_ point: CGPoint) {
        let size = stamp
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2,
                          width: size, height: size).intersection(imageRect)
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return }
        ensureStrokeContext(covering: rect)

        let filtered: CIImage
        if tool == .mosaic {
            filtered = CIImage(cgImage: base).cropped(to: rect)
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: max(8, size / 3),
                    kCIInputCenterKey: CIVector(cgPoint: CGPoint(x: rect.midX, y: rect.midY)),
                ])
        } else {
            // Blur a padded crop so the patch edges stay smooth, then cut
            // back to the stamp rect.
            let wide = rect.insetBy(dx: -32, dy: -32).intersection(imageRect)
            filtered = CIImage(cgImage: base).cropped(to: wide)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 10])
                .cropped(to: rect)
        }
        if let out = ci.createCGImage(filtered, from: rect) {
            strokeCtx?.draw(out, in: rect)
        }
        liveLayer.contents = strokeCtx?.makeImage()
    }

    // MARK: Pen

    private func penSegment(to point: CGPoint) {
        guard let from = penLast else { penLast = point; return }
        let box = CGRect(x: min(from.x, point.x) - penWidth, y: min(from.y, point.y) - penWidth,
                         width: abs(point.x - from.x) + penWidth * 2,
                         height: abs(point.y - from.y) + penWidth * 2)
        ensureStrokeContext(covering: box)
        strokeCtx?.setStrokeColor(NSColor.systemRed.cgColor)
        strokeCtx?.setLineWidth(penWidth)
        strokeCtx?.setLineCap(.round)
        strokeCtx?.setLineJoin(.round)
        strokeCtx?.move(to: from)
        strokeCtx?.addLine(to: point)
        strokeCtx?.strokePath()
        penLast = point
        liveLayer.contents = strokeCtx?.makeImage()
    }

    // MARK: Text

    private func placeText(at viewPoint: NSPoint) {
        finishText()
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y - 32,
                                              width: 280, height: 32))
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 24, weight: .bold)
        field.textColor = .white
        field.focusRingType = .none
        field.placeholderString = L("Type…", ["es": "Escribe…", "zh": "输入文字…", "zh-Hant": "輸入文字…"])
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        field.shadow = shadow
        addSubview(field)
        editingText = field
        window?.makeFirstResponder(field)
        NotificationCenter.default.addObserver(self, selector: #selector(textDone(_:)),
                                               name: NSControl.textDidEndEditingNotification, object: field)
    }

    @objc private func textDone(_ note: Notification) { finishText() }

    private func finishText() {
        guard let field = editingText else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSControl.textDidEndEditingNotification, object: field)
        editingText = nil
        let text = field.stringValue
        let origin = NSPoint(x: field.frame.minX / viewScale,
                             y: field.frame.minY / viewScale)
        field.removeFromSuperview()
        guard !text.isEmpty else { return }

        states.append(marksCtx.makeImage()!)
        trimUndo()
        // Rasterize at image resolution through an NSImage: it owns its
        // own flipped drawing space, so nothing here has to flip.
        let size = 24.0 / viewScale
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white,
            .shadow: { let s = NSShadow()
                s.shadowColor = NSColor.black.withAlphaComponent(0.8)
                s.shadowBlurRadius = 4
                s.shadowOffset = NSSize(width: 0, height: -1)
                return s }(),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let strSize = str.size()
        let img = NSImage(size: strSize)
        img.lockFocus()
        str.draw(at: .zero)
        img.unlockFocus()
        if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            marksCtx.draw(cg, in: CGRect(origin: origin, size: strSize))
        }
        marksLayer.contents = marksCtx.makeImage()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if tool == .text {
            placeText(at: viewPoint)
            return
        }
        if editingText != nil { finishText() }
        states.append(marksCtx.makeImage()!)
        strokeBounds = .zero
        strokeCtx = nil
        penLast = nil
        if tool == .pen { penSegment(to: imagePoint(viewPoint)) }
        else { stamp(imagePoint(viewPoint)) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        if tool == .pen { penSegment(to: p) } else { stamp(p) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let ctx = strokeCtx, let img = ctx.makeImage() else {
            // A click that painted nothing still pushed a state.
            if !states.isEmpty { states.removeLast() }
            return
        }
        // Bake the stroke into the marks bitmap once, at commit time.
        marksCtx.draw(img, in: CGRect(origin: strokeBounds.origin,
                                      size: strokeBounds.size))
        marksLayer.contents = marksCtx.makeImage()
        strokeCtx = nil
        liveLayer.contents = nil
        trimUndo()
    }

    private func trimUndo() {
        if states.count > maxUndo { states.removeFirst(states.count - maxUndo) }
    }

    func undo() {
        if editingText != nil { finishText(); return }
        guard let before = states.popLast() else { return }
        marksCtx.clear(imageRect)
        marksCtx.draw(before, in: imageRect)
        marksLayer.contents = marksCtx.makeImage()
    }

    /// The image with every mark composited, at the file's own resolution.
    func bake() -> CGImage? {
        guard let marks = marksCtx.makeImage() else { return nil }
        let out = CGContext(data: nil, width: base.width, height: base.height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        out?.draw(base, in: imageRect)
        out?.draw(marks, in: imageRect)
        return out?.makeImage()
    }
}
