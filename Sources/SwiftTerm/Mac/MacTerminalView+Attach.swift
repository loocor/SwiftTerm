import AppKit

#if os(macOS)
extension TerminalView {
    public func attachTerminal(_ terminal: Terminal, fullRedraw: Bool = false) {
        if self.terminal === terminal {
            if fullRedraw {
                setNeedsDisplay(bounds)
            }
            return
        }
        self.terminal?.setDelegate(nil)
        self.terminal = terminal
        terminal.setDelegate(self)
        setupOptions()
        dirtyRowsToDraw = []
        lastDrawnYDisp = terminal.buffer.yDisp
        invalidateLineRenderCache()
        updateScroller()
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
}
#endif
