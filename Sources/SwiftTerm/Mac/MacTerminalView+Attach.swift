import AppKit

#if os(macOS)
extension TerminalView {
    public func attachTerminal(_ terminal: Terminal, fullRedraw: Bool = false) {
        let wasSameTerminal = (self.terminal === terminal)
        if wasSameTerminal {
            terminal.setDelegate(self)
            dirtyRowsToDraw = []
            invalidateLineRenderCache()
            updateScroller()
            startDisplayUpdates()
            requestDisplayRefresh()
            if fullRedraw {
                setNeedsDisplay(bounds)
            } else {
                setNeedsDisplay(visibleRect)
            }
            return
        }
        let preservedOptions = terminal.options
        self.terminal?.setDelegate(nil)
        self.terminal = terminal
        terminal.setDelegate(self)
        configureForAttachedTerminal(using: preservedOptions)
        dirtyRowsToDraw = []
        lastDrawnYDisp = terminal.buffer.yDisp
        invalidateLineRenderCache()
        updateScroller()
        startDisplayUpdates()
        requestDisplayRefresh()
        if fullRedraw {
            setNeedsDisplay(bounds)
        } else {
            setNeedsDisplay(visibleRect)
        }
    }

    public func detachTerminal() {
        terminal?.setDelegate(nil)
    }

    public func isAttached(to terminal: Terminal) -> Bool {
        self.terminal === terminal
    }

    private func configureForAttachedTerminal(using preservedOptions: TerminalOptions) {
        resetCaches()
        cellDimension = computeFontDimensions()

        let width = bounds.width
        let height = bounds.height
        let newCols = max(Int(getEffectiveWidth(size: bounds.size) / cellDimension.width), 1)
        let newRows = max(Int(height / cellDimension.height), 1)

        if width > 2, height > 2, (terminal.cols != newCols || terminal.rows != newRows) {
            terminal.resize(cols: newCols, rows: newRows)
        }

        var updatedOptions = preservedOptions
        updatedOptions.cols = terminal.cols
        updatedOptions.rows = terminal.rows
        terminal.options = updatedOptions

        selection = SelectionService(terminal: terminal)
        search = SearchService(terminal: terminal)

        if caretView == nil {
            let v = CaretView(
                frame: CGRect(origin: .zero,
                              size: CGSize(width: cellDimension.width, height: cellDimension.height)),
                cursorStyle: terminal.options.cursorStyle,
                terminal: self)
            addSubview(v)
            caretView = v
        } else {
            updateCaretView()
        }

        layer?.backgroundColor = nativeBackgroundColor.cgColor
        terminal.updateFullScreen()
    }
}
#endif
