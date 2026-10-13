#if os(macOS)
import AppKit

/// Last text-only display update, bounded to the viewport rather than scrollback.
/// This suppresses redundant *invalidation*, never parsing or an AppKit redraw.
struct TextDisplaySnapshot: Equatable {
    struct Cell: Equatable {
        let character: Character
        let width: Int8
        let attribute: Attribute
        let payload: UInt16
    }
    struct Row: Equatable {
        let line: BufferLine
        let generation: UInt64
        let cells: [Cell]
        var cacheable: Bool = true
        static func ==(lhs: Self, rhs: Self) -> Bool { lhs.cacheable == rhs.cacheable && lhs.cells == rhs.cells }
    }
    let buffer: Buffer
    let bounds: CGRect
    let columns: Int
    let firstRow: Int
    let reverse: Bool
    let blink: Bool
    let bright: Bool
    let customGlyphs: Bool
    let antiAliasGlyphs: Bool
    let cells: [Row]
    func samePresentation(as rhs: Self) -> Bool {
        let lhs = self
        return lhs.buffer === rhs.buffer && lhs.bounds == rhs.bounds && lhs.columns == rhs.columns
            && lhs.firstRow == rhs.firstRow && lhs.reverse == rhs.reverse && lhs.blink == rhs.blink
            && lhs.bright == rhs.bright && lhs.customGlyphs == rhs.customGlyphs
            && lhs.antiAliasGlyphs == rhs.antiAliasGlyphs
    }
    static func ==(lhs: Self, rhs: Self) -> Bool {
        lhs.samePresentation(as: rhs) && lhs.cells == rhs.cells
    }
}

extension TerminalView {
    func clearTextLayoutCache() {
        lastTextLayoutSnapshot = nil
        textLayouts.removeAll(keepingCapacity: false)
    }

    /// Keep only layouts for unchanged rows of this text-only viewport. Complex
    /// presentation uses the original path, and no scrollback is cached.
    func prepareTextLayoutsForDraw() {
        guard let snapshot = textDisplaySnapshot(layoutOnly: true) else {
            clearTextLayoutCache(); return
        }
        if let previous = lastTextLayoutSnapshot, previous.samePresentation(as: snapshot) {
            textLayouts = textLayouts.filter { row, _ in
                let offset = row - snapshot.firstRow
                return offset >= 0 && offset < snapshot.cells.count && offset < previous.cells.count
                    && snapshot.cells[offset] == previous.cells[offset]
            }
        } else {
            textLayouts.removeAll(keepingCapacity: false)
        }
        lastTextLayoutSnapshot = snapshot
    }

    func textLayoutForDraw(row: Int, line: BufferLine, cols: Int) -> ViewLineInfo {
        guard let snapshot = lastTextLayoutSnapshot,
              row >= snapshot.firstRow, row < snapshot.firstRow + snapshot.cells.count,
              snapshot.cells[row - snapshot.firstRow].cacheable else {
            return buildAttributedString(row: row, line: line, cols: cols)
        }
        if let cached = textLayouts[row] { return cached }
        let layout = buildAttributedString(row: row, line: line, cols: cols)
        textLayouts[row] = layout
        return layout
    }

    func textDisplaySnapshot(layoutOnly: Bool = false) -> TextDisplaySnapshot? {
        let buffer = terminal.displayBuffer
        // Complex presentation keeps the existing renderer path. This is a cache
        // admission bound, not a terminal size or content limit.
        guard !selection.active, !commandActive, linkHighlightRange == nil, bidiHostPolicy == .respectTerminal,
              terminal.kittyGraphicsState.placementsByKey.isEmpty,
              buffer.rows > 0, buffer.cols > 0, buffer.rows <= 256,
              buffer.cols <= 65536 / buffer.rows else { return nil }
        let start = buffer.yDisp, end = min(buffer.lines.count, start + buffer.rows + 1)
        guard start >= 0, end > start else { return nil }
        var rows: [TextDisplaySnapshot.Row] = []
        rowLoop: for row in start..<end {
            let line = buffer.lines[row]
            // Wrapped/BiDi paragraphs may depend on cells outside this viewport.
            // Exclude the complete wrapped paragraph, including its first row.
            let continues = row + 1 < buffer.lines.count && buffer.lines[row + 1].isWrapped
            guard !line.isWrapped, !continues, line.bidiState == .default,
                  line.renderMode == .single, line.images?.isEmpty != false else {
                guard layoutOnly else { return nil }
                rows.append(.init(line: line, generation: line.generation, cells: [], cacheable: false))
                continue
            }
            let screenRow = row - start
            if let old = layoutOnly ? lastTextLayoutSnapshot : lastTextDisplaySnapshot, old.buffer === buffer,
               old.firstRow == start, screenRow < old.cells.count,
               old.cells[screenRow].cacheable, old.cells[screenRow].line === line,
               old.cells[screenRow].generation == line.generation {
                rows.append(old.cells[screenRow]); continue
            }
            var cells: [TextDisplaySnapshot.Cell] = []
            for cell in line.getData() {
                let character = terminal.getCharacter(for:cell)
                guard !cell.hasPayload,
                      !character.unicodeScalars.contains(where:{ TerminalBidi.isRTLTrigger($0.value) }) else {
                    guard layoutOnly else { return nil }
                    rows.append(.init(line: line, generation: line.generation, cells: [], cacheable: false))
                    continue rowLoop
                }
                cells.append(.init(character:character,width:cell.width,attribute:cell.attribute,payload:cell.payload.code))
            }
            rows.append(.init(line:line,generation:line.generation,cells:cells))
        }
        return .init(buffer:buffer,bounds:bounds,columns:buffer.cols,
                     firstRow:start,reverse:terminal.reverseColors,blink:textBlinkVisible,
                     bright:useBrightColors,customGlyphs:customBlockGlyphs,antiAliasGlyphs:antiAliasCustomBlockGlyphs,cells:rows)
    }
}
#endif
