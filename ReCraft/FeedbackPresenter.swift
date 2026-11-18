import AppKit

@MainActor
final class FeedbackPresenter {
    enum Kind {
        case processing
        case success
        case warning
        case failure

        var symbolName: String {
            switch self {
            case .processing:
                "ellipsis.circle.fill"
            case .success:
                "checkmark.circle.fill"
            case .warning:
                "questionmark.circle.fill"
            case .failure:
                "exclamationmark.triangle.fill"
            }
        }

        var color: NSColor {
            switch self {
            case .processing:
                .systemBlue
            case .success:
                .systemGreen
            case .warning:
                .systemYellow
            case .failure:
                .systemOrange
            }
        }
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, kind: Kind) {
        hideTask?.cancel()

        let panel = panel ?? makePanel()
        self.panel = panel

        guard let stack = panel.contentView?.subviews.first as? NSStackView,
              let imageView = stack.arrangedSubviews.first as? NSImageView,
              let label = stack.arrangedSubviews.last as? NSTextField else {
            return
        }

        imageView.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
        imageView.contentTintColor = kind.color
        label.stringValue = message

        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 360, height: 52))
        position(panel)
        panel.orderFrontRegardless()

        if case .processing = kind { return }

        hideTask = Task { @MainActor [weak panel] in
            let duration: Duration = switch kind {
            case .processing:
                .zero
            case .success:
                .seconds(1.5)
            case .warning, .failure:
                .seconds(3)
            }
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22),
        ])

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])

        panel.contentView = effect
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.maxY - panel.frame.height - 36
        )
        panel.setFrameOrigin(origin)
    }
}
