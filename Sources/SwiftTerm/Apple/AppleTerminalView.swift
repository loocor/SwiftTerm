//
//  AppleTerminalView.swift
//
// Shared code for UIKit and Appkit for the terminal view
//
//  Created by Miguel de Icaza on 4/21/20.
//
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics
import CoreText
import os

#if os(iOS) || os(visionOS)
import UIKit
typealias TTColor = UIColor
typealias TTFont = UIFont
typealias TTRect = CGRect
typealias TTBezierPath = UIBezierPath
public typealias TTImage = UIImage
#endif

#if os(macOS)
import AppKit
typealias TTColor = NSColor
typealias TTFont = NSFont
typealias TTRect = CGRect
typealias TTBezierPath = NSBezierPath
public typealias TTImage = NSImage
#endif

// Holds the information used to render a line
struct ViewLineInfo {
    // Contains the generated NSAttributedString
    var attrStr: NSAttributedString
    // contains an array of (image, column where the image was found)
    var images: [TerminalImage]?
}

struct CachedLine {
    let row: Int
    let lineIdentifier: ObjectIdentifier
    let version: UInt64
    let selectionGeneration: UInt64
    let lineInfo: ViewLineInfo
    let ctLine: CTLine
}

public struct RenderStats {
    var cacheHits: Int = 0
    var cacheMisses: Int = 0
    var linesDrawn: Int = 0
    var dirtyLinesExamined: Int = 0
    var scrollDeltaRows: Int = 0
    var scrollBlitAttempts: Int = 0
    var scrollBlitHits: Int = 0
    var scrollBlitExposedRows: Int = 0
    var linesRebuilt: Int = 0
    var charsRebuilt: Int = 0
}

#if canImport(os)
private let renderLog = OSLog(subsystem: "com.codmate.swiftterm", category: "render")
#endif

// Display throttling state used by queuePendingDisplay/resume
struct DisplayThrottleState {
    var suspended: Bool = false
    var needsFlushWhenResumed: Bool = false
}

struct GlyphWidthCache {
    private struct Entry {
        var value: Int
        var age: UInt64
    }
    private var cache: [UInt32: Entry] = [:]
    private var currentAge: UInt64 = 0
    private let capacity: Int
    init(capacity: Int) {
        self.capacity = max(64, capacity)
    }
    mutating func value(for scalar: UInt32, resolver: () -> Int) -> Int {
        currentAge &+= 1
        if var entry = cache[scalar] {
            entry.age = currentAge
            cache[scalar] = entry
            return entry.value
        }
        let width = resolver()
        cache[scalar] = Entry(value: width, age: currentAge)
        if cache.count > capacity {
            evictLeastRecent()
        }
        return width
    }
    mutating func reset() {
        cache.removeAll(keepingCapacity: true)
        currentAge = 0
    }
    private mutating func evictLeastRecent() {
        guard let victim = cache.min(by: { $0.value.age < $1.value.age })?.key else {
            return
        }
        cache.removeValue(forKey: victim)
    }
}

struct ColorMapCacheKey: Hashable {
    let color: Attribute.Color
    let isFg: Bool
    let isBold: Bool
    let useBrightColors: Bool
}

struct ColorMapCache {
    private struct Entry {
        var color: TTColor
        var age: UInt64
    }
    private var cache: [ColorMapCacheKey: Entry] = [:]
    private var currentAge: UInt64 = 0
    private let capacity: Int
    init(capacity: Int) {
        self.capacity = max(64, capacity)
    }
    mutating func color(for key: ColorMapCacheKey, resolver: () -> TTColor) -> TTColor {
        currentAge &+= 1
        if var entry = cache[key] {
            entry.age = currentAge
            cache[key] = entry
            return entry.color
        }
        let value = resolver()
        cache[key] = Entry(color: value, age: currentAge)
        if cache.count > capacity {
            evictLeastRecent()
        }
        return value
    }
    mutating func reset() {
        cache.removeAll(keepingCapacity: true)
        currentAge = 0
    }
    private mutating func evictLeastRecent() {
        guard let victim = cache.min(by: { $0.value.age < $1.value.age })?.key else {
            return
        }
        cache.removeValue(forKey: victim)
    }
}

extension TerminalView {
    typealias CellDimension = CGSize
    
    // When true, queuePendingDisplay will avoid scheduling a redraw and mark
    // needsFlushWhenResumed to repaint once resumed.
    var displayThrottleState: DisplayThrottleState {
        get { _displayThrottleState }
        set { _displayThrottleState = newValue }
    }

    // Track which visible rows should be redrawn in the current paint pass.
    var dirtyRowsToDraw: Set<Int> {
        get { _dirtyRowsToDraw }
        set { _dirtyRowsToDraw = newValue }
    }

    // Track last drawn render metrics (for diagnostics).
    public var renderStats: RenderStats {
        get { _renderStats }
        set { _renderStats = newValue }
    }

    // Whether to emit os_signpost entries for draw passes.
    public var renderInstrumentationEnabled: Bool {
        get { _renderInstrumentationEnabled }
        set { _renderInstrumentationEnabled = newValue }
    }

    // Last scroll delta applied via blit (rows, positive when yDisp increased).
    var lastScrollDeltaRows: Int {
        get { _lastScrollDeltaRows }
        set { _lastScrollDeltaRows = newValue }
    }

    // Scroll blit accounting used for renderStats.
    var pendingScrollBlitAttempts: Int {
        get { _pendingScrollBlitAttempts }
        set { _pendingScrollBlitAttempts = newValue }
    }
    var pendingScrollBlitHits: Int {
        get { _pendingScrollBlitHits }
        set { _pendingScrollBlitHits = newValue }
    }
    var pendingScrollBlitExposedRows: Int {
        get { _pendingScrollBlitExposedRows }
        set { _pendingScrollBlitExposedRows = newValue }
    }
    var lastScrollExposedRows: Int {
        get { _lastScrollExposedRows }
        set { _lastScrollExposedRows = newValue }
    }

    // Counts of line/string rebuild work during the current paint.
    var renderRebuildLineCount: Int {
        get { _renderRebuildLineCount }
        set { _renderRebuildLineCount = newValue }
    }
    var renderRebuildCharCount: Int {
        get { _renderRebuildCharCount }
        set { _renderRebuildCharCount = newValue }
    }

    // Logging controls for render stats.
    var renderLogEveryNFrames: Int {
        get { _renderLogEveryNFrames }
        set { _renderLogEveryNFrames = max(0, newValue) }
    }
    var renderLogFrameCounter: Int {
        get { _renderLogFrameCounter }
        set { _renderLogFrameCounter = newValue }
    }
    var renderLogUsePrint: Bool {
        get { _renderLogUsePrint }
        set { _renderLogUsePrint = newValue }
    }
    
    // Track last drawn yDisp to detect scrolling and fall back to full redraw for new viewport.
    var lastDrawnYDisp: Int {
        get { _lastDrawnYDisp }
        set { _lastDrawnYDisp = newValue }
    }

    func resetCaches ()
    {
        self.attributes = [:]
        self.urlAttributes = [:]
        self.colors = Array(repeating: nil, count: 256)
        self.trueColors = [:]
        glyphWidthCache.reset()
        colorMapCache.reset()
        invalidateLineRenderCache()
    }

    func prewarmCachesIfNeeded() {
        if cachesPrewarmed { return }
        // Prime glyph widths for common ASCII to reduce first-keypress spikes.
        for scalar in 32...126 {
            let u = UInt32(scalar)
            _ = glyphWidthCache.value(for: u) {
                Wcwidth.scalarSize(Int(u))
            }
        }
        // Prime a small set of ANSI colors for both fg/bg to populate ColorMapCache.
        for idx in 0...15 {
            let ansi = UInt8(idx)
            _ = mapColor(color: .ansi256(code: ansi), isFg: true, isBold: false, useBrightColors: true)
            _ = mapColor(color: .ansi256(code: ansi), isFg: false, isBold: false, useBrightColors: true)
        }
        _ = mapColor(color: .defaultColor, isFg: true, isBold: false, useBrightColors: true)
        _ = mapColor(color: .defaultColor, isFg: false, isBold: false, useBrightColors: true)
        cachesPrewarmed = true
    }

    func invalidateLineRenderCache() {
        lineRenderCache.removeAll(keepingCapacity: false)
    }

    func cachedLine(forRow row: Int, line: BufferLine, cols: Int) -> CachedLine {
        let identifier = ObjectIdentifier(line)
        if let cached = lineRenderCache[row],
           cached.lineIdentifier == identifier,
           cached.version == line.renderGeneration,
           cached.selectionGeneration == selectionGeneration {
            _renderStats.cacheHits &+= 1
            return cached
        }

        // During scroll, the same BufferLine may move to a different row index.
        if let reused = lineRenderCache.values.first(where: {
            $0.lineIdentifier == identifier &&
            $0.version == line.renderGeneration &&
            $0.selectionGeneration == selectionGeneration
        }) {
            _renderStats.cacheHits &+= 1
            let updated = CachedLine(row: row,
                                     lineIdentifier: identifier,
                                     version: line.renderGeneration,
                                     selectionGeneration: selectionGeneration,
                                     lineInfo: reused.lineInfo,
                                     ctLine: reused.ctLine)
            lineRenderCache[row] = updated
            return updated
        }

        _renderStats.cacheMisses &+= 1
        let lineInfo = buildAttributedString(row: row, line: line, cols: cols)
        let ctline = CTLineCreateWithAttributedString(lineInfo.attrStr)
        renderRebuildLineCount &+= 1
        renderRebuildCharCount &+= lineInfo.attrStr.length
        let updated = CachedLine(row: row,
                                 lineIdentifier: identifier,
                                 version: line.renderGeneration,
                                 selectionGeneration: selectionGeneration,
                                 lineInfo: lineInfo,
                                 ctLine: ctline)
        lineRenderCache[row] = updated
        return updated
    }

    func logRenderStatsIfNeeded() {
        guard renderLogEveryNFrames > 0 else { return }
        renderLogFrameCounter &+= 1
        guard renderLogFrameCounter % renderLogEveryNFrames == 0 else { return }
        let stats = _renderStats
        #if canImport(os)
        if #available(macOS 10.12, iOS 12.0, *) {
            os_log("render frame drawn:%{public}d hits:%{public}d misses:%{public}d rebuilt:%{public}d chars:%{public}d dirty:%{public}d scroll:%{public}d blit:%{public}d/%{public}d exp:%{public}d",
                   log: renderLog,
                   type: .info,
                   stats.linesDrawn,
                   stats.cacheHits,
                   stats.cacheMisses,
                   stats.linesRebuilt,
                   stats.charsRebuilt,
                   stats.dirtyLinesExamined,
                   stats.scrollDeltaRows,
                   stats.scrollBlitHits,
                   stats.scrollBlitAttempts,
                   stats.scrollBlitExposedRows)
            if !renderLogUsePrint {
                return
            }
        }
        #endif
        if renderLogUsePrint {
            print("render frame drawn:\(stats.linesDrawn) hits:\(stats.cacheHits) misses:\(stats.cacheMisses) rebuilt:\(stats.linesRebuilt) chars:\(stats.charsRebuilt) dirty:\(stats.dirtyLinesExamined) scroll:\(stats.scrollDeltaRows) blit:\(stats.scrollBlitHits)/\(stats.scrollBlitAttempts) exp:\(stats.scrollBlitExposedRows)")
        }
    }

    func pruneLineRenderCache(visibleStart: Int, visibleEnd: Int) {
        guard lineRenderCache.count > 0 else {
            return
        }
        guard let terminal else {
            lineRenderCache.removeAll()
            return
        }

        // Allow a larger cache to reduce CTLine rebuilds during scroll/oscillating updates.
        let maxEntries = max(terminal.rows * 8, 512)
        guard lineRenderCache.count > maxEntries else {
            return
        }

        let padding = max(terminal.rows, 1)
        let lowerBound = max(visibleStart - padding, 0)
        let upperBound = visibleEnd + padding
        var keysToRemove: [Int] = []
        keysToRemove.reserveCapacity(lineRenderCache.count - maxEntries)
        for key in lineRenderCache.keys {
            if key < lowerBound || key > upperBound {
                keysToRemove.append(key)
            }
        }
        for key in keysToRemove {
            lineRenderCache.removeValue(forKey: key)
        }
    }
    
    // This is invoked when the font changes to recompute state
    func resetFont()
    {
        resetCaches()
        self.cellDimension = computeFontDimensions ()
        let newCols = Int(frame.width / cellDimension.width)
        let newRows = Int(frame.height / cellDimension.height)
        resize(cols: newCols, rows: newRows)
        updateCaretView()
    }
    
    func updateCaretView ()
    {
        guard let caretView else { return }
        caretView.frame.size = CGSize(width: cellDimension.width, height: cellDimension.height)
        caretView.updateCursorStyle()
    }
    
    /// The frame used by the caretView
    public var caretFrame: CGRect {
        return caretView?.frame ?? CGRect.zero
    }
    
    func setupOptions(width: CGFloat, height: CGFloat)
    {
        resetCaches ()
        // Calculation assume that all glyphs in the font have the same advancement.
        // Get the ascent + descent + leading from the font, already scaled for the font's size
        self.cellDimension = computeFontDimensions ()
        
        let terminalOptions = TerminalOptions(cols: Int(width / cellDimension.width),
                                              rows: Int(height / cellDimension.height))
        
        if terminal == nil {
            terminal = Terminal(delegate: self, options: terminalOptions)
        } else {
            terminal.options = terminalOptions
            terminal.setup(isReset: false)
        }
        terminal.backgroundColor = Color.defaultBackground
        terminal.foregroundColor = Color.defaultForeground

        selection = SelectionService(terminal: terminal)
        
        // Install carret view
        if caretView == nil {
            let v = CaretView(frame: CGRect(origin: .zero, size: CGSize(width: cellDimension.width, height: cellDimension.height)), cursorStyle: terminal.options.cursorStyle, terminal: self)
            addSubview(v)
            caretView = v
        } else {
            updateCaretView ()
        }
        
        search = SearchService (terminal: terminal)
        
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay(frame)
        #endif
    }

    /// Returns the underlying terminal emulator that the `TerminalView` is a view for
    public func getTerminal () -> Terminal
    {
        return terminal
    }
    
    /// This function computes the new columns and rows for the terminal when a pixel-size changes
    /// Returns true if this changed the number of columns/rows, false otherwise
    @discardableResult
    func processSizeChange (newSize: CGSize) -> Bool {
        let newRows = Int (newSize.height / cellDimension.height)
        let newCols = Int (getEffectiveWidth (size: newSize) / cellDimension.width)
        
        if newCols != terminal.cols || newRows != terminal.rows {
            selection.active = false
            terminal.resize (cols: newCols, rows: newRows)
            
            // These used to be outside
            accessibility.invalidate ()
            search.invalidate ()
            
            terminalDelegate?.sizeChanged (source: self, newCols: newCols, newRows: newRows)
           
            updateScroller()
            invalidateLineRenderCache()
            return true
        }
        return false
    }
    
    // Computes the font dimensions once font.normal has been set
    func computeFontDimensions () -> CellDimension
    {
        let lineAscent = CTFontGetAscent (fontSet.normal)
        let lineDescent = CTFontGetDescent (fontSet.normal)
        let lineLeading = CTFontGetLeading (fontSet.normal)
        let cellHeight = ceil(lineAscent + lineDescent + lineLeading)
        #if os(macOS)
        // The following is a more robust way of getting the largest ascii character width, but comes with a performance hit.
        // See: https://github.com/migueldeicaza/SwiftTerm/issues/286
        // var sizes = UnsafeMutablePointer<NSSize>.allocate(capacity: 95)
        // let ctFont = (font as CTFont)
        // var glyphs = (32..<127).map { CTFontGetGlyphWithName(ctFont, String(Unicode.Scalar($0)) as CFString) }
        // withUnsafePointer(to: glyphs[0]) { glyphsPtr in
        //     fontSet.normal.getAdvancements(NSSizeArray(sizes), forCGGlyphs: glyphsPtr, count: 95)
        // }
        // let cellWidth = (0..<95).reduce(into: 0) { partialResult, idx in
        //     partialResult = max(partialResult, sizes[idx].width)
        // }
        let glyph = fontSet.normal.glyph(withName: "W")
        let cellWidth = fontSet.normal.advancement(forGlyph: glyph).width
        #else
        let fontAttributes = [NSAttributedString.Key.font: fontSet.normal]
        let cellWidth = "W".size(withAttributes: fontAttributes).width
        #endif
        return CellDimension(width: max (1, cellWidth), height: max (min (cellHeight, 8192), 1))
    }
    
    func mapColor (color: Attribute.Color, isFg: Bool, isBold: Bool, useBrightColors: Bool = true) -> TTColor
    {
        let key = ColorMapCacheKey(color: color, isFg: isFg, isBold: isBold, useBrightColors: useBrightColors)
        return colorMapCache.color(for: key) { [self] in
            return resolveMapColor(color: color, isFg: isFg, isBold: isBold, useBrightColors: useBrightColors)
        }
    }

    private func resolveMapColor(color: Attribute.Color, isFg: Bool, isBold: Bool, useBrightColors: Bool) -> TTColor {
        switch color {
        case .defaultColor:
            return isFg ? nativeForegroundColor : nativeBackgroundColor
        case .defaultInvertedColor:
            return isFg ? nativeForegroundColor.inverseColor() : nativeBackgroundColor.inverseColor()
        case .ansi256(let ansi):
            var midx: Int
            if useBrightColors {
                midx = ansi < 7 ? (Int(ansi) + (isBold ? 8 : 0)) : Int(ansi)
            } else {
                midx = ansi > 7 ? (Int(ansi) - 8) : Int(ansi)
            }
            if let c = colors[midx] {
                return c
            }
            let tcolor = terminal.ansiColors[midx]
            let newColor = TTColor.make(color: tcolor)
            colors[midx] = newColor
            return newColor
        case .trueColor(let r, let g, let b):
            if let tc = trueColors[color] {
                return tc
            }
            let newColor = TTColor.make(red: CGFloat(r) / 255.0,
                                        green: CGFloat(g) / 255.0,
                                        blue: CGFloat(b) / 255.0,
                                        alpha: 1.0)
            trueColors[color] = newColor
            return newColor
        }
    }

    // Clears the cached state for colors and triggers a full display
    func colorsChanged ()
    {
        urlAttributes = [:]
        attributes = [:]
        colorMapCache.reset()
        
        terminal.updateFullScreen ()
        invalidateLineRenderCache()
        queuePendingDisplay()
    }
    
    public func hostCurrentDirectoryUpdated (source: Terminal)
    {
        terminalDelegate?.hostCurrentDirectoryUpdate(source: self, directory: terminal.hostCurrentDirectory)
    }

    
    /// Installs the new colors as the default colors and recomputes the
    /// current and ansi palette.   This installs both the colors into the terminal
    /// engine and updates the UI accordingly.
    /// 
    /// - Parameter colors: this should be an array of 16 values that correspond to the 16 ANSI colors,
    /// if the array does not contain 16 elements, it will not do anything
    public func installColors (_ colors: [Color])
    {
        terminal.installPalette(colors: colors)
        self.colors = Array(repeating: nil, count: 256)
        self.colorsChanged()
    }
    
    public func colorChanged (source: Terminal, idx: Int?)
    {
        if let index = idx {
            colors [index] = nil
        } else {
            colors = Array(repeating: nil, count: 256)
        }
        colorsChanged ()
    }

    public func setBackgroundColor(source: Terminal, color: Color) {
        // Can not implement this until I change the color to not be this struct
        nativeBackgroundColor = TTColor.make (color: color)
        colorsChanged()
    }
    
    public func setForegroundColor(source: Terminal, color: Color) {
        nativeForegroundColor = TTColor.make (color: color)
        colorsChanged()
    }
    
    /// Sets the color for the cursor block, and the text when it is under that cursor in block mode
    public func setCursorColor(source: Terminal, color: Color?, textColor: Color?) {
        if let setColor = color {
            caretColor = TTColor.make (color: setColor)
        } else {
            if let caretView {
                caretColor = caretView.defaultCaretColor
            }
        }
        if let setColor = textColor {
            caretTextColor = TTColor.make (color: setColor)
        } else {
            if let caretView {
                caretTextColor = caretView.defaultCaretTextColor
            }
        }
    }
    
    func getAttributedValue (_ attribute: Attribute, usingFg: TTColor, andBg: TTColor) -> [NSAttributedString.Key:Any]?
    {
        let flags = attribute.style
        var bg = andBg
        var fg = usingFg
        
        if flags.contains (.inverse) {
            swap (&bg, &fg)
        }
        
        var tf: TTFont
        let isBold = flags.contains(.bold)
        if isBold {
            if flags.contains (.italic) {
                tf = fontSet.boldItalic
            } else {
                tf = fontSet.bold
            }
        } else if flags.contains (.italic) {
            tf = fontSet.italic
        } else {
            tf = fontSet.normal
        }
        
        var nsattr: [NSAttributedString.Key:Any] = [
            .font: tf,
            .foregroundColor: fg,
            .backgroundColor: bg
        ]
        if flags.contains (.underline) {
            nsattr [.underlineColor] = fg
            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if flags.contains (.crossedOut) {
            nsattr [.strikethroughColor] = fg
            nsattr [.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return nsattr
    }
    
    //
    // Given a vt100 attribute, return the NSAttributedString attributes used to render it
    //
    func getAttributes (_ attribute: Attribute, withUrl: Bool) -> [NSAttributedString.Key:Any]?
    {
        let flags = attribute.style
        var bg = attribute.bg
        var fg = attribute.fg
        
        if flags.contains (.inverse) {
            swap (&bg, &fg)
            
            if fg == .defaultColor {
                fg = .defaultInvertedColor
            }
            if bg == .defaultColor {
                bg = .defaultInvertedColor
            }
        }
        
        if let result = withUrl ? urlAttributes [attribute] : attributes [attribute] {
            return result
        }
        
        var useBoldForBrightColor: Bool = false
        // if high - bright colors are disabled in settings we will use bold font instead
        if case .ansi256(let code) = fg, code > 7, !useBrightColors {
            useBoldForBrightColor = true
        }
        var tf: TTFont
        let isBold = flags.contains(.bold)
        
        if isBold || useBoldForBrightColor {
            if flags.contains (.italic) {
                tf = fontSet.boldItalic
            } else {
                tf = fontSet.bold
            }
        } else if flags.contains (.italic) {
            tf = fontSet.italic
        } else {
            tf = fontSet.normal
        }
        
        let fgColor = mapColor (color: fg, isFg: true, isBold: isBold, useBrightColors: useBrightColors)
        var nsattr: [NSAttributedString.Key:Any] = [
            .font: tf,
            .foregroundColor: fgColor,
            .backgroundColor: mapColor(color: bg, isFg: false, isBold: false)
        ]
        if flags.contains (.underline) {
            nsattr [.underlineColor] = fgColor
            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if flags.contains (.crossedOut) {
            nsattr [.strikethroughColor] = fgColor
            nsattr [.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        if withUrl {
            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue
            nsattr [.underlineColor] = fgColor
            
            // Add to cache
            urlAttributes [attribute] = nsattr
        } else {
            // Just add to cache
            attributes [attribute] = nsattr
        }
        return nsattr
    }
    
    //
    // Given a line of text with attributes, returns the NSAttributedString, suitable to be drawn
    // as a side effect, it updates the `images` array
    //
    func buildAttributedString (row: Int, line: BufferLine, cols: Int, prefix: String = "") -> ViewLineInfo
    {
        struct LineRun {
            var attr: Attribute
            var hasUrl: Bool
            var start: Int
            var length: Int
        }
        var runs: [LineRun] = []
        runs.reserveCapacity(cols / 4)
        let prefixUTF16Count = prefix.utf16.count
        var utf16Buffer: [UInt16] = []
        utf16Buffer.reserveCapacity(prefixUTF16Count + cols + 8)
        if prefixUTF16Count > 0 {
            utf16Buffer.append(contentsOf: prefix.utf16)
        }
        var currentLength = utf16Buffer.count
        var pendingPrefixLength = prefixUTF16Count
        var hasActiveRun = false
        var currentAttr = Attribute.empty
        var currentHasUrl = false
        var currentRunStart = 0
        var col = 0

        func finalizeActiveRun() {
            if hasActiveRun {
                runs.append(LineRun(attr: currentAttr,
                                    hasUrl: currentHasUrl,
                                    start: currentRunStart,
                                    length: currentLength - currentRunStart))
                hasActiveRun = false
            }
        }

        func startRun(attr: Attribute, hasUrl: Bool) {
            finalizeActiveRun()
            currentAttr = attr
            currentHasUrl = hasUrl
            if pendingPrefixLength > 0 {
                currentRunStart = 0
                pendingPrefixLength = 0
            } else {
                currentRunStart = currentLength
            }
            hasActiveRun = true
        }
        
        while col < cols {
            let ch: CharData = line[col]
            let chHasUrl = ch.hasPayload
            if !hasActiveRun || currentAttr != ch.attribute || currentHasUrl != chHasUrl {
                startRun(attr: ch.attribute, hasUrl: chHasUrl)
            }
            let code = ch.code
            let isWide = ch.width > 1
            let renderedChar = code == 0 ? " " : ch.getCharacter()
            for unit in renderedChar.utf16 {
                utf16Buffer.append(unit)
                currentLength &+= 1
            }
            if isWide {
                utf16Buffer.append(UInt16(UnicodeScalar(" ").value))
                currentLength &+= 1
                col += 1
            }
            col += 1
        }
        finalizeActiveRun()
        let finalString: String
        if utf16Buffer.isEmpty {
            finalString = ""
        } else {
            finalString = utf16Buffer.withUnsafeBufferPointer { ptr in
                String(utf16CodeUnits: ptr.baseAddress!, count: ptr.count)
            }
        }
        let res = NSMutableAttributedString(string: finalString)
        res.beginEditing()
        if runs.isEmpty && !finalString.isEmpty {
            res.setAttributes(getAttributes(.empty, withUrl: false), range: NSRange(location: 0, length: finalString.utf16.count))
        } else {
            for run in runs where run.length > 0 {
                res.setAttributes(getAttributes(run.attr, withUrl: run.hasUrl), range: NSRange(location: run.start, length: run.length))
            }
        }
        res.endEditing()
        updateSelectionAttributesIfNeeded(attributedLine: res, row: row, cols: cols)
        return ViewLineInfo(attrStr: res, images: line.images)
    }
    
    /// Apply selection attributes
    /// TODO: Optimize the logic below
    func updateSelectionAttributesIfNeeded(attributedLine attributedString: NSMutableAttributedString, row: Int, cols: Int) {
        guard let selection = self.selection, selection.active else {
            attributedString.removeAttribute(.selectionBackgroundColor)
            return
        }

        let startRow = selection.start.row
        let endRow = selection.end.row
        
        let startCol = selection.start.col
        let endCol = selection.end.col
        
        var selectionRange: NSRange = .empty

        // single row
        if endRow == startRow && startRow == row {
            if startCol < endCol {
                let extra = endCol == terminal.cols-1 ? 1 : 0
                selectionRange = NSRange(location: startCol, length: endCol - startCol + extra)
            } else if startCol > endCol {
                selectionRange = NSRange(location: endCol, length: startCol - endCol)
            }
        } else if endRow > startRow {
            // first row
            if startRow == row && endRow > row {
                selectionRange = NSRange(location: startCol, length: cols - startCol)
            }
            
            // in between
            if startRow < row && endRow > row {
                selectionRange = NSRange(location: 0, length: cols)
            }
            
            // last row
            if startRow < row && endRow == row {
                let extra = endCol == terminal.cols-1 ? 1 : 0
                selectionRange = NSRange(location: 0, length: endCol + extra)
            }
        } else if endRow < startRow {
            
            // first row
            if endRow == row && startRow > row {
                selectionRange = NSRange(location: endCol, length: cols - endCol)
            }
            
            // in between
            if startRow > row && endRow < row {
                selectionRange = NSRange(location: 0, length: cols)
            }
            
            // last row
            if endRow < row && startRow == row {
                let extra = startCol == terminal.cols-1 ? 1 : 0
                selectionRange = NSRange(location: 0, length: startCol + extra)
            }
        }
        
        if selectionRange != .empty {
            assert (selectionRange.location >= 0)
            // Looks like we can start the selection range beyond the boundary and it wont be a problem
            //assert (selectionRange.location < cols)
            assert (selectionRange.length >= 0)
            if (selectionRange.location + selectionRange.length >= cols) {
            }
            if row == 1 {
                print(selectionRange)
            }
            attributedString.addAttribute(.selectionBackgroundColor, value: selectedTextBackgroundColor, range: selectionRange)
        }
    }

    func drawRunAttributes(_ attributes: [NSAttributedString.Key : Any], glyphPositions positions: [CGPoint], in currentContext: CGContext) {
        currentContext.saveGState()

        let scale = backingScaleFactor()

        if attributes.keys.contains(.underlineStyle) {
            // draw underline at font.normal.underlinePosition baseline
            let underlineStyle = NSUnderlineStyle(rawValue: attributes[.underlineStyle] as? NSUnderlineStyle.RawValue ?? 0)
            let underlineColor = attributes[.underlineColor] as? TTColor ?? nativeForegroundColor
            let underlinePosition = fontSet.underlinePosition ()

            // draw line at the baseline
            currentContext.setShouldAntialias(false)
            currentContext.setStrokeColor(underlineColor.cgColor)

            let underlineThickness = max(round(scale * fontSet.underlineThickness ()) / scale, 0.5)
            for p in positions {
                switch underlineStyle {
                case let style where style.contains(.single):
                    let path = TTBezierPath()
                    path.move(to: p.applying(.init(translationX: 0, y: underlinePosition)))
                    path.addLine(to: p.applying(.init(translationX: ceil(cellDimension.width), y: underlinePosition)))
                    path.lineWidth = underlineThickness
                    switch underlineStyle {
                    case let pattern where pattern.contains(.patternDash):
                        let pattern: [CGFloat] = [2.0]
                        path.setLineDash(pattern, count: pattern.count, phase: 0)
                    default:
                        break
                    }
                    path.stroke()
                case let style where style.contains(.double):
                    let path1 = TTBezierPath()
                    path1.move(to: p.applying(.init(translationX: 0, y: underlinePosition)))
                    path1.addLine(to: p.applying(.init(translationX: ceil(cellDimension.width), y: underlinePosition)))
                    path1.lineWidth = underlineThickness

                    let path2 = TTBezierPath()
                    path2.move(to: p.applying(.init(translationX: 0, y: underlinePosition - underlineThickness - 1)))
                    path2.addLine(to: p.applying(.init(translationX: ceil(cellDimension.width), y: underlinePosition - underlineThickness - 1)))
                    path2.lineWidth = underlineThickness

                    switch underlineStyle {
                    case let pattern where pattern.contains(.patternDash):
                        let pattern: [CGFloat] = [2.0]
                        path1.setLineDash(pattern, count: pattern.count, phase: 0)
                        path2.setLineDash(pattern, count: pattern.count, phase: 0)
                    default:
                        break
                    }
                    path1.stroke()
                    path2.stroke()
                default:
                    preconditionFailure("Unsupported underline style.")
                    break
                }
            }
        }
        currentContext.restoreGState()
    }

    
    // TODO: this should not render any lines outside the dirtyRect
    func drawTerminalContents (dirtyRect: TTRect, context: CGContext, bufferOffset: Int)
    {
        let lineDescent = CTFontGetDescent(fontSet.normal)
        let lineLeading = CTFontGetLeading(fontSet.normal)
        let yOffset = ceil(lineDescent+lineLeading)

        func calcLineOffset (forRow: Int) -> CGFloat {
            cellDimension.height * CGFloat (forRow-bufferOffset+1)
        }
        // draw lines
        #if os(iOS) || os(visionOS)
        // On iOS, we are drawing the exposed region
        let cellHeight = cellDimension.height
        let firstRow = Int (dirtyRect.minY/cellHeight)
        let lastRow = Int(dirtyRect.maxY/cellHeight)
        #else
        // On Mac, we are drawing the terminal buffer
        let cellHeight = cellDimension.height
        let boundsMaxY = bounds.maxY
        let firstRow = terminal.buffer.yDisp+Int ((boundsMaxY-dirtyRect.maxY)/cellHeight)
        let lastRow = terminal.buffer.yDisp+Int((boundsMaxY-dirtyRect.minY)/cellHeight)
        #endif

        let dirtySet = dirtyRowsToDraw
        _renderStats.cacheHits = 0
        _renderStats.cacheMisses = 0
        _renderStats.linesDrawn = 0
        _renderStats.dirtyLinesExamined = 0
        _renderStats.scrollDeltaRows = lastScrollDeltaRows
        _renderStats.scrollBlitAttempts = pendingScrollBlitAttempts
        _renderStats.scrollBlitHits = pendingScrollBlitHits
        _renderStats.scrollBlitExposedRows = pendingScrollBlitExposedRows
        _renderStats.linesRebuilt = 0
        _renderStats.charsRebuilt = 0
        renderRebuildLineCount = 0
        renderRebuildCharCount = 0
        pendingScrollBlitAttempts = 0
        pendingScrollBlitHits = 0
        pendingScrollBlitExposedRows = 0
        #if canImport(os)
        var signpostID: OSSignpostID?
        if renderInstrumentationEnabled, #available(macOS 10.14, iOS 12.0, *) {
            let totalRows = max(0, lastRow - firstRow + 1)
            let dirtyCount = dirtySet.count
            let scrollDelta = lastScrollDeltaRows
            let newID = OSSignpostID(log: renderLog)
            os_signpost(.begin, log: renderLog, name: "drawTerminalContents", signpostID: newID, "rows:%d dirty:%d scroll:%d", totalRows, dirtyCount, scrollDelta)
            signpostID = newID
        }
        #endif
        // Clear after each paint to avoid filtering stale rows during scroll.
        defer { dirtyRowsToDraw = [] }
        let currentYDisp = terminal.buffer.yDisp
        let minVisible = firstRow - currentYDisp
        let maxVisible = lastRow - currentYDisp
        // Only enable filtering if:
        //  - We are not in a new viewport (yDisp unchanged)
        //  - Dirty set intersects visible rows
        let forceFullRedrawThisScroll = lastScrollDeltaRows != 0
        let useDirtyFilter: Bool = {
            guard !dirtySet.isEmpty else { return false }
            guard lastDrawnYDisp == currentYDisp else { return false }
            return dirtySet.contains(where: { $0 >= minVisible && $0 <= maxVisible })
        }()
        let shouldUseDirtyFilter = !forceFullRedrawThisScroll && useDirtyFilter
        lastDrawnYDisp = currentYDisp

        var drawnLines = 0

        // For scroll frames, rebuild only exposed rows but still draw cached lines for the rest.
        let rowRange: ClosedRange<Int> = firstRow...lastRow
        let scrollExposedRows: ClosedRange<Int>? = {
            guard forceFullRedrawThisScroll, lastScrollExposedRows > 0 else { return nil }
            if lastScrollDeltaRows > 0 {
                // Scrolling down (into scrollback): new rows at bottom.
                let start = max(firstRow, lastRow - lastScrollExposedRows + 1)
                return start...lastRow
            } else {
                // Scrolling up (towards live buffer): new rows at top.
                let end = min(lastRow, firstRow + lastScrollExposedRows - 1)
                return firstRow...end
            }
        }()

        for row in rowRange {
            if shouldUseDirtyFilter && !dirtySet.contains(row - terminal.buffer.yDisp) {
                continue
            }
            if row < 0 {
                continue
            }
            if row >= terminal.buffer.lines.count {
                continue
            }
            let renderMode = terminal.buffer.lines [row].renderMode
            let lineOffset = calcLineOffset(forRow: row)
            let lineOrigin = CGPoint(x: 0, y: frame.height - lineOffset)
            
            switch renderMode {
            case .single:
                break
            case .doubledDown:
                context.saveGState()
                let pivot = lineOrigin.y
                let lineRect = CGRect (origin: CGPoint (x: 0, y: lineOrigin.y), size: CGSize (width: dirtyRect.width, height: cellDimension.height))
                context.clip(to: [lineRect])
                // Debug aid
                //  context.setFillColor(CGColor(red: 0, green: Double (row)/25.0, blue: 0, alpha: 1))
                // context.fill([lineRect])

                context.translateBy(x: 0, y: pivot)
                context.scaleBy (x: 2, y: 2)
                context.translateBy(x: 0, y: -pivot)

            case .doubledTop:
                context.saveGState()
                let pivot = lineOrigin.y + cellDimension.height
                let lineRect = CGRect (origin: CGPoint (x: 0, y: lineOrigin.y), size: CGSize (width: dirtyRect.width, height: cellDimension.height))

                context.clip(to: [lineRect])
                
                // Debug Aid
                //context.setFillColor(CGColor(red: Double (row)/25.0, green: 0, blue: 0, alpha: 1))
                //context.fill([lineRect])

                context.translateBy(x: 0, y: pivot)
                context.scaleBy (x: 2, y: 2)
                context.translateBy(x: 0, y: -pivot)
                
            case .doubleWidth:
                context.saveGState()
                context.scaleBy (x: 2, y: 1)
            }
            #if false
            // This optimization is useful, but only if we can get proper exposed regions
            // and while it works most of the time with the BigSur change, there is still
            // a case where we just get full exposes despite requesting only a line
            // repro: fill 300 lines, then clear screen then repeatedly output commands
            // that produce 3-5 lines of text: while we send AppKit the right boundary,
            // AppKit still send everything.  
            let lineRect = CGRect (origin: lineOrigin, size: CGSize (width: dirtyRect.width, height: cellDimension.height))
            
            if !lineRect.intersects(dirtyRect) {
                //print ("Skipping row \(row) because it does nto intersect")
                continue
            } 
            #endif
            let line = terminal.buffer.lines [row]
            let cacheEntry: CachedLine
            if forceFullRedrawThisScroll,
               let exposed = scrollExposedRows,
               exposed.contains(row) {
                // Rebuild for newly exposed rows during scroll.
                _renderStats.cacheMisses &+= 1
                let lineInfo = buildAttributedString(row: row, line: line, cols: terminal.cols)
                let ctline = CTLineCreateWithAttributedString(lineInfo.attrStr)
                renderRebuildLineCount &+= 1
                renderRebuildCharCount &+= lineInfo.attrStr.length
                let updated = CachedLine(row: row,
                                         lineIdentifier: ObjectIdentifier(line),
                                         version: line.renderGeneration,
                                         selectionGeneration: selectionGeneration,
                                         lineInfo: lineInfo,
                                         ctLine: ctline)
                lineRenderCache[row] = updated
                cacheEntry = updated
            } else {
                cacheEntry = cachedLine(forRow: row, line: line, cols: terminal.cols)
            }
            let lineInfo = cacheEntry.lineInfo
            let ctline = cacheEntry.ctLine

            var col = 0
            for run in CTLineGetGlyphRuns(ctline) as? [CTRun] ?? [] {
                let runGlyphsCount = CTRunGetGlyphCount(run)
                let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
                let runFont = runAttributes[.font] as! TTFont

                let runGlyphs = [CGGlyph](unsafeUninitializedCapacity: runGlyphsCount) { (bufferPointer, count) in
                    CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                    count = runGlyphsCount
                }

                var positions = runGlyphs.enumerated().map { (i: Int, glyph: CGGlyph) -> CGPoint in
                    CGPoint(x: lineOrigin.x + (cellDimension.width * CGFloat(col + i)), y: lineOrigin.y + yOffset)
                }

                var backgroundColor: TTColor?
                if runAttributes.keys.contains(.selectionBackgroundColor) {
                    backgroundColor = runAttributes[.selectionBackgroundColor] as? TTColor
                } else if runAttributes.keys.contains(.backgroundColor) {
                    backgroundColor = runAttributes[.backgroundColor] as? TTColor
                }

                if let backgroundColor = backgroundColor {
                    context.saveGState ()

                    context.setShouldAntialias (false)
                    context.setLineCap (.square)
                    context.setLineWidth(0)
                    context.setFillColor(backgroundColor.cgColor)

                    let transform = CGAffineTransform (translationX: positions[0].x, y: 0)

                    var size = CGSize (width: CGFloat (cellDimension.width * CGFloat(runGlyphsCount)), height: cellDimension.height)
                    var origin: CGPoint = lineOrigin

                    #if (lastLineExtends)
                    // Stretch last col/row to full frame size.
                    // TODO: need apply this kind of fixup to selection too
                    if (row-terminal.buffer.yDisp) >= terminal.rows - 1 {
                        let missing = frame.height - (cellDimension.height + CGFloat(row) + 1)
                        size.height += missing
                        origin.y -= missing
                    }
                    #endif

                    if col + runGlyphsCount >= terminal.cols {
                        size.width += frame.width - size.width
                    }
                    
                    let rect = CGRect (origin: origin, size: size)
                    #if os(macOS)
                    rect.applying(transform).fill(using: .destinationOver)
                    #else
                    context.fill(rect.applying(transform))
                    #endif
                    context.restoreGState()
                }

                nativeForegroundColor.set()

                if runAttributes.keys.contains(.foregroundColor) {
                    let color = runAttributes[.foregroundColor] as! TTColor
                    let cgColor = color.cgColor
                    if let colorSpace = cgColor.colorSpace {
                        context.setFillColorSpace(colorSpace)
                    }
                    context.setFillColor(cgColor)
                }
                
                CTFontDrawGlyphs(runFont, runGlyphs, &positions, positions.count, context)

                // Draw other attributes
                drawRunAttributes(runAttributes, glyphPositions: positions, in: context)

                col += runGlyphsCount
            }

            // Render any sixel content last
            if let images = lineInfo.images {
                let rowBase = frame.height - (CGFloat(row) * cellDimension.height)
                for basicImage in images {
                    guard let image = basicImage as? AppleImage else {
                        continue
                    }
                    let col = image.col
                    let rect = CGRect(x: CGFloat (col)*cellDimension.width,
                                      y: rowBase - CGFloat (image.pixelHeight),
                                      width: CGFloat (image.pixelWidth),
                                      height: CGFloat (image.pixelHeight))
                    
                    image.image.draw (in: rect)
                }
            }
            switch renderMode {
            case .single:
                break
            case .doubledDown:
                context.restoreGState()
            case .doubledTop:
                context.restoreGState()
            case .doubleWidth:
                context.restoreGState()
            }
            drawnLines &+= 1
        }

        _renderStats.linesDrawn = drawnLines
        _renderStats.dirtyLinesExamined = shouldUseDirtyFilter ? dirtySet.count : max(0, lastRow - firstRow + 1)
        _renderStats.linesRebuilt = renderRebuildLineCount
        _renderStats.charsRebuilt = renderRebuildCharCount
        logRenderStatsIfNeeded()
        #if canImport(os)
        if renderInstrumentationEnabled, #available(macOS 10.14, iOS 12.0, *), let signpostID {
            os_signpost(.end, log: renderLog, name: "drawTerminalContents", signpostID: signpostID, "drawn:%d hits:%d misses:%d rebuilt:%d chars:%d dirty:%d scroll:%d blit:%d/%d exp:%d", drawnLines, _renderStats.cacheHits, _renderStats.cacheMisses, _renderStats.linesRebuilt, _renderStats.charsRebuilt, _renderStats.dirtyLinesExamined, _renderStats.scrollDeltaRows, _renderStats.scrollBlitHits, _renderStats.scrollBlitAttempts, _renderStats.scrollBlitExposedRows)
        }
        #endif
        lastScrollDeltaRows = 0
        lastScrollExposedRows = 0

        pruneLineRenderCache(visibleStart: bufferOffset, visibleEnd: bufferOffset + terminal.rows)
        
#if os(macOS)
        // Fills gaps at the end with the default terminal background
        let box = CGRect (x: 0, y: 0, width: bounds.width, height: bounds.height.truncatingRemainder(dividingBy: cellHeight))
        if dirtyRect.intersects(box) {
            nativeBackgroundColor.setFill()
            context.fill ([box])
        }
#elseif false
        // Currently the caller on iOS is clearing the entire dirty region due to the ordering of
        // font change sizes, but once we fix that, we should remove the clearing of the dirty
        // region in the calling code, and enable this code instead.
        let lineOffset = calcLineOffset(forRow: lastRow)
        let lineOrigin = CGPoint(x: 0, y: frame.height - lineOffset)

        let inter = dirtyRect.intersection(CGRect (x: 0, y: lineOrigin.y, width: bounds.width, height: cellHeight))
        if !inter.isEmpty {
            nativeBackgroundColor.setFill()
            context.fill ([inter])
        }
#endif
        
#if os(iOS) || os(visionOS)
        if selection.active {
            let start, end: Position

            func drawSelectionHandle (drawStart: Bool, row: Int) {
                let lineOffset = calcLineOffset(forRow: row)
                let lineOrigin = frame.height - lineOffset
                
                context.saveGState ()
                let start = CGPoint (
                    x: CGFloat (drawStart ? start.col : end.col) * cellDimension.width,
                    y: lineOrigin)
                let end = CGPoint(x: start.x, y: start.y + cellDimension.height)
                
                context.move(to: end)
                context.addLine(to: start)
                let size = 6.0
                let location = drawStart ? end : start
                
                let rect = CGRect (origin:
                                    CGPoint (x: location.x-(size/2.0),
                                             y: location.y - (drawStart ? 0.0 : size)),
                                   size: CGSize (width: size, height: size))
                context.addEllipse(in: rect)
                context.closePath()
                context.setLineWidth(2)
                selectionHandleColor.set ()
                //TTColor.systemBlue.set ()
                context.drawPath(using: .fillStroke)
                context.restoreGState()
            }
            
            // Normalize the selection start/end, regardless of where it started
            let sstart = selection.start
            let send = selection.end
            if Position.compare (sstart, send) == .before {
                start = sstart
                end = send
            } else {
                start = send
                end = sstart
            }
            
            drawSelectionHandle (drawStart: true, row: start.row)
            drawSelectionHandle (drawStart: false, row: end.row)
        }
#endif
    }
    
    /// Update visible area
    func updateDisplay (notifyAccessibility: Bool)
    {
        updateCursorPosition()
        guard let (rowStart, rowEnd) = terminal.getUpdateRange () else {
            if notifyUpdateChanges {
                let buffer = terminal.buffer
                let y = buffer.yDisp+buffer.y
                terminalDelegate?.rangeChanged (source: self, startY: y, endY: y)
            }
            return
        }
        if notifyUpdateChanges {
            terminalDelegate?.rangeChanged (source: self, startY: rowStart, endY: rowEnd)
        }

        // Capture dirty rows (if any) to enable filtering during draw.
        let dirtyRowsSet = terminal.changedLines()
        dirtyRowsToDraw = dirtyRowsSet

        let shouldForceFullRedraw: Bool = {
            guard !dirtyRowsSet.isEmpty else { return false }
            guard let minRow = dirtyRowsSet.min(), let maxRow = dirtyRowsSet.max() else { return false }
            let span = maxRow - minRow + 1
            let minSpan = max(terminal.rows / 2, 6)
            let maxSparseCount = max(span / 4, 4)
            return span >= minSpan && dirtyRowsSet.count <= maxSparseCount
        }()

        terminal.clearUpdateRange ()
        if shouldForceFullRedraw {
            dirtyRowsToDraw = []
            #if os(macOS)
            setNeedsDisplay(bounds)
            #else
            setNeedsDisplay(frame)
            #endif
            return
        }
                
        #if os(macOS)
        let baseLine = frame.height
        if dirtyRowsSet.isEmpty {
            var region = CGRect (x: 0,
                                 y: baseLine - (cellDimension.height + CGFloat(rowEnd) * cellDimension.height),
                                 width: frame.width,
                                 height: CGFloat(rowEnd-rowStart + 1) * cellDimension.height)
            
            // If we are the last line, we should also queue a refresh for the "remaining" bits at the
            // end which can be redrawn by large unicode
            if rowEnd == terminal.rows - 1 {
                let oh = region.height
                let oy = region.origin.y
                region = CGRect (x: 0, y: 0, width: frame.width, height: oh + oy)
            }
            setNeedsDisplay(region)
        } else {
            let sorted = dirtyRowsSet.sorted()
            var runStart = sorted.first!
            var runEnd = runStart

            func enqueueRegion(start: Int, end: Int) {
                var region = CGRect(x: 0,
                                    y: baseLine - (cellDimension.height + CGFloat(end) * cellDimension.height),
                                    width: frame.width,
                                    height: CGFloat(end - start + 1) * cellDimension.height)
                if end == terminal.rows - 1 {
                    let oh = region.height
                    let oy = region.origin.y
                    region = CGRect(x: 0, y: 0, width: frame.width, height: oh + oy)
                }
                setNeedsDisplay(region)
            }

            for row in sorted.dropFirst() {
                if row == runEnd + 1 {
                    runEnd = row
                } else {
                    enqueueRegion(start: runStart, end: runEnd)
                    runStart = row
                    runEnd = row
                }
            }
            enqueueRegion(start: runStart, end: runEnd)
        }
        #else
        // TODO iOS: need to update the code above, but will do that when I get some real
        // life data being fed into it.
        setNeedsDisplay(bounds)
        #endif
        
        pendingDisplay = false
        updateDebugDisplay ()
        
        if (notifyAccessibility) {
            accessibility.invalidate ()
            #if os(macOS)
            NSAccessibility.post (element: self, notification: .valueChanged)
            NSAccessibility.post (element: self, notification: .selectedTextChanged)
            #endif
        }
    }
    
    func updateCursorPosition()
    {
        guard let caretView else { return }
        //let lineOrigin = CGPoint(x: 0, y: frame.height - (cellDimension.height * (CGFloat(terminal.buffer.y - terminal.buffer.yDisp + 1))))
        //caretView.frame.origin = CGPoint(x: lineOrigin.x + (cellDimension.width * CGFloat(terminal.buffer.x)), y: lineOrigin.y)
        let buffer = terminal.buffer
        let vy = buffer.yBase + buffer.y
        
        if vy >= buffer.yDisp + buffer.rows {
            caretView.removeFromSuperview()
            return
        } else if terminal.cursorHidden == false && caretView.superview != self {
            addSubview(caretView)
        }
        let doublePosition = buffer.lines [vy].renderMode == .single ? 1.0 : 2.0
        #if os(iOS) || os(visionOS)
        let offset = (cellDimension.height * (CGFloat(buffer.y+(buffer.yBase))))
        let lineOrigin = CGPoint(x: 0, y: offset)
        #else
        let offset = (cellDimension.height * (CGFloat(buffer.y-(buffer.yDisp-buffer.yBase)+1)))
        let lineOrigin = CGPoint(x: 0, y: frame.height - offset)
        #endif
        caretView.frame.origin = CGPoint(x: lineOrigin.x + (cellDimension.width * doublePosition * CGFloat(buffer.x)), y: lineOrigin.y)
        caretView.setText (ch: buffer.lines [vy][buffer.x])
    }
    
    // Does not use a default argument and merge, because it is called back
    func updateDisplay ()
    {
        updateDisplay (notifyAccessibility: true)
        updateDebugDisplay()
        pendingDisplay = false
    }
    
    //
    // The code below is intended to not repaint too often, which can produce flicker, for example
    // when the user refreshes the display, and this repains the screen, as dispatch delivers data
    // in blocks of 1024 bytes, which is not enough to cover the whole screen, so this delays
    // the update for a 1/600th of a second.
    //
    // It is also cheap, so should be called when new data has been posted or received.
    func queuePendingDisplay ()
    {
        if displayThrottleState.suspended {
            displayThrottleState.needsFlushWhenResumed = true
            return
        }
        // throttle
        if !pendingDisplay {
            // Aim for ~60fps to improve scroll smoothness; still throttled vs immediate redraw.
            let targetFrameNs: UInt64 = 16_000_000
            pendingDisplay = true
            DispatchQueue.main.asyncAfter(
                deadline: DispatchTime (uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + targetFrameNs),
                execute: updateDisplay)
        }
    }

    /// Public helper to schedule a display refresh honoring throttling.
    public func requestDisplayRefresh() {
        queuePendingDisplay()
    }
    
    ///
    /// This takes a string returned by events (NSEvent or UIKey) as the 'charactersIngoringModifiers'
    /// and returns the control-version of that, and only applies to a handful of characters
    ///
    func applyControlToEventCharacters (_ ch: String) -> [UInt8]
    {
        let arr = [UInt8](ch.utf8)
        if arr.count == 1 {
            let ch = Character (UnicodeScalar (arr [0]))
            var value: UInt8
            switch ch {
            case "A"..."Z":
                value = (ch.asciiValue! - 0x40 /* - 'A' + 1 */)
            case "a"..."z":
                value = (ch.asciiValue! - 0x60 /* - 'a' + 1 */)
            case "\\":
                value = 0x1c
            case "_":
                value = 0x1f
            case "]":
                value = 0x1d
            case "[":
                value = 0x1b
            case "^", "6":
                value = 0x1e
            case " ":
                value = 0
            default:
                return []
            }
            return [value]
        }
        return []
    }
    /**
     * Returns the thumb size in proportion to the visible content of the entire content, alternate buffers are not scrollable, so this returns 0
     */
    public var scrollThumbsize: CGFloat {
        get {
            if terminal.isCurrentBufferAlternate {
                return 0
            }
            
            // the thumb size is the proportion of the visible content of the
            // entire content but don't make it too small
            return max (CGFloat (terminal.rows) / CGFloat (terminal.buffer.lines.count), 0.01)
        }
    }
    
    /**
     * Gets a value indicating the relative position of the terminal viewport
     */
    public var scrollPosition: Double {
        get {
            if terminal.isCurrentBufferAlternate || terminal.buffer.yDisp <= 0 {
                return 0
            }
            
            let maxScrollback = terminal.buffer.lines.count - terminal.rows
            if terminal.buffer.yDisp >= maxScrollback {
                return 1
            }
            
            return Double (terminal.buffer.yDisp) / Double (maxScrollback)
        }
    }
    
    /// <summary>
    /// Gets a value indicating whether or not the user can scroll the terminal contents
    /// </summary>
    public var canScroll: Bool {
        get {
            return !terminal.isCurrentBufferAlternate &&
                terminal.buffer.hasScrollback &&
                terminal.buffer.lines.count > terminal.rows
        }
    }

    @discardableResult
    func performScrollBlit(from oldYDisp: Int, to newYDisp: Int) -> Bool {
        let deltaRows = newYDisp - oldYDisp
        lastScrollDeltaRows = deltaRows
        pendingScrollBlitAttempts &+= 1
        lastScrollExposedRows = 0
        #if os(macOS)
        guard deltaRows != 0 else { return false }
        let rowsToMove = abs(deltaRows)
        let maxBlitRows = max(terminal.rows * 3, terminal.rows)
        if rowsToMove > maxBlitRows {
            return false
        }
        let dy = CGFloat(deltaRows) * cellDimension.height
        if dy == 0 || bounds.isEmpty {
            return false
        }

        scroll(bounds, by: NSSize(width: 0, height: dy))

        let exposedHeight = min(abs(dy), bounds.height)
        if exposedHeight == 0 {
            return true
        }
        let exposedRows = min(terminal.rows, Int(ceil(exposedHeight / cellDimension.height)))
        let exposedRect: CGRect
        let startRow: Int
        if dy > 0 {
            exposedRect = CGRect(x: 0, y: 0, width: bounds.width, height: exposedHeight)
            startRow = max(terminal.rows - exposedRows, 0)
        } else {
            exposedRect = CGRect(x: 0, y: bounds.height - exposedHeight, width: bounds.width, height: exposedHeight)
            startRow = 0
        }
        setNeedsDisplay(exposedRect)
        if exposedRows > 0 {
            terminal.refresh(startRow: startRow, endRow: startRow + exposedRows - 1)
        }
        pendingScrollBlitHits &+= 1
        pendingScrollBlitExposedRows &+= exposedRows
        lastScrollExposedRows = exposedRows
        return true
        #else
        return false
        #endif
    }
    
    public func scroll (toPosition: Double)
    {
        userScrolling = true
        let oldPosition = terminal.buffer.yDisp
        
        let maxScrollback = terminal.buffer.lines.count - terminal.rows
        print ("maxScrollBack: \(maxScrollback)")
        var newScrollPosition = Int (Double (maxScrollback) * toPosition)
        
        if newScrollPosition < 0 {
            newScrollPosition = 0
        }
        if newScrollPosition > maxScrollback {
            newScrollPosition = maxScrollback
        }
        print ("newScrollpsitin: \(newScrollPosition)")
        
        if newScrollPosition != oldPosition {
            scrollTo(row: newScrollPosition)
        }
        userScrolling = false
    }
    
    func scrollTo (row: Int, notifyAccessibility: Bool = true)
    {
        if row != terminal.buffer.yDisp {
            let oldYDisp = terminal.buffer.yDisp
            terminal.buffer.yDisp = row

            let usedBlit = performScrollBlit(from: oldYDisp, to: row)
            if !usedBlit {
                terminal.refresh(startRow: 0, endRow: terminal.rows)
            }

            updateDisplay (notifyAccessibility: notifyAccessibility)
            //selectionView.notifyScrolled(source: terminal)
            terminalDelegate?.scrolled (source: self, position: scrollPosition)
            updateScroller()
            if !usedBlit {
                setNeedsDisplay(frame)
            }
        }
    }
    
    /// Scrolls the content of the terminal one page up
    public func pageUp()
    {
        if terminal.isCurrentBufferAlternate {
            send (EscapeSequences.cmdPageUp)
        } else {
            scrollUp (lines: terminal.rows)
        }
    }
    
    /// Scrolls the content of the terminal one page down
    public func pageDown ()
    {
        if terminal.isCurrentBufferAlternate {
            send (EscapeSequences.cmdPageDown)
        } else {
            scrollDown (lines: terminal.rows)
        }
    }
    
    /// Scrolls up the content of the terminal the specified number of lines
    public func scrollUp (lines: Int)
    {
        let newPosition = max (terminal.buffer.yDisp - lines, 0)
        scrollTo (row: newPosition)
    }
    
    /// Scrolls down the content of the terminal the specified number of lines
    public func scrollDown (lines: Int)
    {
        let newPosition = max (0, min (terminal.buffer.yDisp + lines, terminal.buffer.lines.count - terminal.rows))
        scrollTo (row: newPosition)
    }
      
    func feedPrepare()
    {
        search.invalidate()
        selection.active = false
        startDisplayUpdates()
    }
    
    func feedFinish ()
    {
        suspendDisplayUpdates ()
        queuePendingDisplay()
    }
    
    /// Sends data to the terminal emulator for interpretation, this can be invoked from a background thread
    public func feed (byteArray: ArraySlice<UInt8>)
    {
        feedPrepare()
        terminal.feed (buffer: byteArray)
        feedFinish()
    }
    
    /// Sends data to the terminal emulator for interpretation, this can be invoked from a background thread
    public func feed (text: String)
    {
        feedPrepare()
        terminal.feed (text: text)
        feedFinish()
    }
         
    /**
     * Triggers a resize of the underlying terminal to the desired columsn and rows
     */
    public func resize (cols: Int, rows: Int)
    {
        terminal.resize (cols: cols, rows: rows)
        sizeChanged (source: terminal)
        terminal.softReset()
    }
    
    /**
     * Sends the specified slice of byte arrays to the program running under the terminal emulator
     * - Parameter data: the slice of an array to send to the client
     */
    public func send(data: ArraySlice<UInt8>)
    {
        ensureCaretIsVisible ()
        terminalDelegate?.send (source: self, data: data)
    }
    
    /**
     * Sends the specified string encoded at utf8 to the program running under the terminal emulator
     * - Parameter txt: the string to send to the client
     */
    public func send (txt: String) {
        let array = [UInt8] (txt.utf8)
        send (data: array[...])
    }
    
    /**
     * Sends the specified array of bytes to the program running under the terminal emulator
     * - Parameter bytes: the bytes to send to the client
     */
    public func send (_ bytes: [UInt8]) {
        send (data: (bytes)[...])
    }
    
    func sendKeyUp ()
    {
        send (terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
    }
    
    func sendKeyDown ()
    {
        send (terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
    }
    
    func sendKeyLeft()
    {
        send (terminal.applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
    }
    
    func sendKeyRight ()
    {
        send (terminal.applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
    }
    
    class AppleImage: TerminalImage {
        var image: TTImage
        var pixelWidth: Int
        var pixelHeight: Int
        var col: Int
        
        init (image: TTImage, width: Int, height: Int, onCol: Int) {
            self.image = image
            self.pixelWidth = width
            self.pixelHeight = height
            self.col = onCol
        }
    }
    // Computes the number of columns and rows used by the image
    func computeCellRows (_ size: CGSize) -> (cols: Int, rows: Int) {
        return (cols: Int ((size.width+cellDimension.width-1)/cellDimension.width),
                rows: Int ((size.height+cellDimension.height-1)/cellDimension.height))
    }
    
    public func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let pixelData = NSData(bytes: bytes, length: bytes.count)
        guard let providerRef: CGDataProvider = CGDataProvider(data: pixelData) else {
            return
        }
        guard let cgimage: CGImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: rgbColorSpace, bitmapInfo: bitmapInfo,
                provider: providerRef, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent) else {
            return
        }
        
        let image = TTImage (cgImage: cgimage, size: CGSize (width: width, height: height))
        insertImage (image, width: CGFloat (width) > frame.width ? .percent(100) : .auto, height: .auto, preserveAspectRatio: true)
    }
   
    public func createImage (source: Terminal, data: Data, width widthRequest: ImageSizeRequest, height heightRequest: ImageSizeRequest, preserveAspectRatio: Bool)
    {
        guard let img = TTImage(data: data) else {
            return
        }
        insertImage (img, width: widthRequest, height: heightRequest, preserveAspectRatio: preserveAspectRatio)
    }
    
    // Inserts the specified image at the current buffer position (x, y) using the specified size requests
    // and aspect ratio request.   The insertion is done by adding slices of the image, one per line
    // to the buffer.
    func insertImage (_ image: TTImage, width widthRequest: ImageSizeRequest, height heightRequest: ImageSizeRequest, preserveAspectRatio: Bool)
    {
        let buffer = terminal.buffer
        var img = image
        let displayScale = getImageScale ()
        
        // Converts a size request in a single dimension into an absolute pixel value, where
        // the `dim` is the request, `regionSize` is the available view space, and `imageSize` is
        // the size of the image along the dimension being requested
        func getPixels (fromDim dim: ImageSizeRequest, regionSize: CGFloat, imageSize: CGFloat, cellSize: CGFloat) -> CGFloat {
            switch dim {
            case .auto:
                return imageSize/displayScale
            case .cells(let n):
                return cellSize * CGFloat (n)
            case .pixels(let n):
                return CGFloat (n)
            case .percent(let pct):
                return CGFloat (pct) * 0.01 * regionSize
            }
        }
        
        var width = getPixels (fromDim: widthRequest, regionSize: frame.width, imageSize: img.size.width, cellSize: cellDimension.width)
        var height = getPixels (fromDim: heightRequest, regionSize: frame.height, imageSize: img.size.height, cellSize: cellDimension.height)
        
        if preserveAspectRatio {
            switch (widthRequest, heightRequest) {
            case (.auto, .auto):
                break
            case (_, .auto):
                height = (width * img.size.height) / img.size.width
            case (.auto, _):
                width = (height * img.size.width) / img.size.height
            case (_, _):
                img = scale (image: img, size: CGSize (width: width, height: height))
            }
        }
        
        let rows = Int (ceil (height/cellDimension.height))
        
        let stripeSize = CGSize (width: width, height: cellDimension.height)
        #if os(iOS) || os(visionOS)
        var srcY: CGFloat = 0
        #else
        var srcY: CGFloat = img.size.height
        #endif
        
        let heightRatio = img.size.height/height
        for _ in 0..<rows {
            #if os(macOS)
            srcY -= cellDimension.height * heightRatio
            #endif
            guard let stripe = drawImageInStripe (image: img, srcY: srcY, width: width, srcHeight: cellDimension.height * heightRatio, dstHeight: cellDimension.height, size: stripeSize) else {
                continue
            }
            #if os(iOS) || os(visionOS)
            srcY += cellDimension.height * heightRatio
            #endif
            
            let attachedImage = AppleImage (image: stripe, width: Int (stripeSize.width), height: Int (cellDimension.height), onCol: terminal.buffer.x)
            
            buffer.lines [buffer.y+buffer.yBase].attach(image: attachedImage)

            terminal.updateRange (buffer.y)
            
            // The buffer.x position would have changed depending on the lineFeedMode (LNM)
            // for image rendering, we want the x to remain the same
            let savedX = buffer.x
            terminal.cmdLineFeed()
            buffer.x = savedX
        }
    }
    
    /// Set to true if the selection is active, false otherwise
    public var selectionActive: Bool {
        get {
            selection.active
        }
    }
    
    
    /// Returns the contents of the selection, if active, or nil otherwise
    public func getSelection () -> String?
    {
        if selection.active {
            return selection.getSelectedText()
        }
        return nil
    }
    
    /// Selects the entire buffer
    public func selectAll () {
        selection.selectAll()
    }
    
    /// Clears the selection
    public func selectNone () {
        selection.selectNone()
    }
    
}
#endif
