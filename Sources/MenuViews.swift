import AppKit

/// Custom menu rows in the style of the system Wi-Fi, Bluetooth and Focus menus.
enum Metrics {
    static let width: CGFloat = 292
    static let inset: CGFloat = 14
    static let circle: CGFloat = 26
    static let textX = inset + circle + 9
}

class MenuRowView: NSView {
    init(height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: height))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Draws one line centered vertically, ending in an ellipsis past maxWidth. Returns the width used.
    @discardableResult
    func drawText(_ string: String, x: CGFloat, color: NSColor = .labelColor, alignRight: Bool = false,
                  maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: string, attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: color,
                                                                   .paragraphStyle: style])
        let size = text.size()
        let width = min(size.width, maxWidth)
        text.draw(in: NSRect(x: alignRight ? x - width : x, y: ((bounds.height - size.height) / 2).rounded(),
                             width: width, height: size.height))
        return width
    }

    func drawSymbol(_ name: String, in rect: NSRect, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return }
        let origin = NSPoint(x: (rect.midX - image.size.width / 2).rounded(), y: (rect.midY - image.size.height / 2).rounded())
        image.draw(in: NSRect(origin: origin, size: image.size), from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }
}

final class HeaderView: MenuRowView {
    let toggle = NSSwitch()
    private let title = NSTextField(labelWithString: "Insomnia")
    private let status = NSTextField(labelWithString: "")

    init() {
        super.init(height: 46)
        toggle.setAccessibilityLabel("Insomnia")
        title.font = .systemFont(ofSize: 13, weight: .bold)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        toggle.controlSize = .small
        [title, status, toggle].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    var statusText: String {
        get { status.stringValue }
        set { status.stringValue = newValue }
    }

    override func layout() {
        super.layout()
        toggle.sizeToFit()
        toggle.setFrameOrigin(NSPoint(x: bounds.width - Metrics.inset - toggle.frame.width,
                                      y: ((bounds.height - toggle.frame.height) / 2).rounded()))
        let width = toggle.frame.minX - Metrics.inset - 10
        // Labels carry a 2 pt inset of their own.
        title.frame = NSRect(x: Metrics.inset - 2, y: 6, width: width, height: 17)
        status.frame = NSRect(x: Metrics.inset - 2, y: 24, width: width, height: 16)
    }
}

/// A choice with a round glyph that fills with the accent color when selected. Picking one keeps the menu open.
final class OptionView: MenuRowView {
    var isSelected = false {
        didSet { needsDisplay = true }
    }
    var onSelect: () -> Void = {}
    private let symbol: String
    private let title: String

    init(symbol: String, title: String) {
        self.symbol = symbol
        self.title = title
        super.init(height: 34)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        var highlighted = enclosingMenuItem?.isHighlighted == true
        #if DEBUG
        highlighted = highlighted || ProcessInfo.processInfo.environment["INSOMNIA_HIGHLIGHT"] == title
        #endif
        if highlighted {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let circle = NSRect(x: Metrics.inset, y: ((bounds.height - Metrics.circle) / 2).rounded(),
                            width: Metrics.circle, height: Metrics.circle)
        (isSelected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
        NSBezierPath(ovalIn: circle).fill()
        drawSymbol(symbol, in: circle, pointSize: 12, weight: .semibold, color: isSelected ? .white : .labelColor)
        drawText(title, x: Metrics.textX)
    }

    override func mouseUp(with event: NSEvent) {
        onSelect()
    }

    override func accessibilityValue() -> Any? { isSelected }

    override func accessibilityPerformPress() -> Bool {
        onSelect()
        return true
    }
}

/// Something at work: an app with its icon, an agent with its project, or an upload.
struct WorkRow: Equatable {
    var title: String
    var detail = ""
    var bundle: String?
    var symbol = "apple.terminal"
}

final class WorkView: MenuRowView {
    private static var icons: [String: NSImage] = [:]

    var row = WorkRow(title: "") {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(row.detail.isEmpty ? row.title : "\(row.title), \(row.detail)")
        }
    }

    init() {
        super.init(height: 26)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let column = NSRect(x: Metrics.inset, y: 0, width: Metrics.circle, height: bounds.height)
        if let bundle = row.bundle {
            let icon = Self.icons[bundle] ?? NSWorkspace.shared.icon(forFile: bundle)
            Self.icons[bundle] = icon
            icon.draw(in: NSRect(x: column.midX - 9, y: column.midY - 9, width: 18, height: 18), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            drawSymbol(row.symbol, in: column, pointSize: 13, weight: .regular, color: .secondaryLabelColor)
        }
        let detailWidth = row.detail.isEmpty ? 0 : drawText(row.detail, x: bounds.width - Metrics.inset,
                                                            color: .secondaryLabelColor, alignRight: true) + 12
        drawText(row.title, x: Metrics.textX, maxWidth: bounds.width - Metrics.inset - detailWidth - Metrics.textX)
    }
}

/// A line of secondary text, for an empty list.
final class NoteView: MenuRowView {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(height: 26)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        drawText(text, x: Metrics.textX, color: .secondaryLabelColor)
    }
}
