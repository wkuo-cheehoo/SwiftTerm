#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

@MainActor final class LineLayoutReuseTests: XCTestCase {
    func testRowReuseAndInvalidation() throws {
        _ = NSApplication.shared
        let view = TerminalView(frame:NSRect(x:0,y:0,width:800,height:500))
        view.getTerminal().feed(text:"\u{1b}[?25lfirst row 中文\r\nsecond row")
        view.updateDisplay(notifyAccessibility:false)
        view.prepareTextLayoutsForDraw()
        let b = view.getTerminal().displayBuffer
        let first = view.textLayoutForDraw(row:0,line:b.lines[0],cols:b.cols)
        let second = view.textLayoutForDraw(row:1,line:b.lines[1],cols:b.cols)
        view.getTerminal().feed(text:"\u{1b}[2;1Hchanged second row")
        view.updateDisplay(notifyAccessibility:false)
        view.prepareTextLayoutsForDraw()
        XCTAssertTrue(try XCTUnwrap(first.segments.first).attributedString === XCTUnwrap(view.textLayoutForDraw(row:0,line:b.lines[0],cols:b.cols).segments.first).attributedString)
        XCTAssertFalse(try XCTUnwrap(second.segments.first).attributedString === XCTUnwrap(view.textLayoutForDraw(row:1,line:b.lines[1],cols:b.cols).segments.first).attributedString)
        view.nativeForegroundColor = .systemRed
        XCTAssertTrue(view.textLayouts.isEmpty)
        view.prepareTextLayoutsForDraw()
        _ = view.textLayoutForDraw(row:0,line:b.lines[0],cols:b.cols)
        view.font = .monospacedSystemFont(ofSize:18,weight:.bold)
        XCTAssertTrue(view.textLayouts.isEmpty)
    }

    func testCachedPixelsMatchFreshLayoutAcrossPresentationChanges() throws {
        _ = NSApplication.shared
        let view = TerminalView(frame:NSRect(x:0,y:0,width:800,height:500))
        func compare(_ label:String) throws {
            view.updateDisplay(notifyAccessibility:false)
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:image)
            let cached = try XCTUnwrap(image.representation(using:.png,properties:[:]))
            view.clearTextLayoutCache()
            view.cacheDisplay(in:view.bounds,to:image)
            XCTAssertEqual(cached,try XCTUnwrap(image.representation(using:.png,properties:[:])),label)
            if view.lastTextLayoutSnapshot != nil {
                XCTAssertLessThanOrEqual(view.textLayouts.count,view.getTerminal().rows+1)
            }
        }
        let updates = ["\u{1b}[?25lhello 中文 🌍\r\nsecond row", "\u{1b}[Hhello 中文 🌍", "\u{1b}[2;1Hchanged\u{1b}[K", "\u{1b}[31;1mred bold\u{1b}[0m", "\u{1b}[?5h", "\u{1b}[?5l", "\u{1b}[2J\u{1b}[Hمرحبا", "\u{1b}[2J\u{1b}[H" + String(repeating:"wrap ",count:100), "\u{1b}[2J\u{1b}[H\u{1b}]8;;https://example.com\u{7}link\u{1b}]8;;\u{7}", "\u{1b}[?1049h\u{1b}[?25lalternate", "\u{1b}[?1049l\u{1b}[?25l"]
        for (n,update) in updates.enumerated() { view.getTerminal().feed(text:update); try compare("update \(n)") }
        view.nativeForegroundColor = .systemGreen; try compare("palette")
        view.font = .monospacedSystemFont(ofSize:18,weight:.regular); try compare("font")
        view.selectAll(nil); try compare("selection")
        XCTAssertNil(view.lastTextLayoutSnapshot)
        view.selectNone(); view.frame.size = NSSize(width:700,height:450); try compare("resize")
    }

    func testOptInRepeatedViewportLayout() throws {
        guard ProcessInfo.processInfo.environment["LINE_LAYOUT_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in renderer benchmark") }
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x:0,y:0,width:1000,height:680))
        view.feed(text: "\u{1b}[?25l" + (1...25).map { "row \($0) common terminal output 中文與 emoji 🌍 long segment\r\n" }.joined())
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:bitmap)
        let expected = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        var a = rusage(), b = rusage(); getrusage(RUSAGE_SELF,&a)
        for _ in 0..<200 { view.cacheDisplay(in:view.bounds,to:bitmap) }
        getrusage(RUSAGE_SELF,&b)
        let cpu = Double(b.ru_utime.tv_sec + b.ru_stime.tv_sec - a.ru_utime.tv_sec - a.ru_stime.tv_sec) + Double(b.ru_utime.tv_usec + b.ru_stime.tv_usec - a.ru_utime.tv_usec - a.ru_stime.tv_usec)/1e6
        print("LAYOUT_REUSE cpu=\(cpu)")
        let cachedRows = view.textLayouts.count
        var allocated = malloc_statistics_t(), cleared = malloc_statistics_t()
        malloc_zone_statistics(nil, &allocated)
        view.clearTextLayoutCache()
        malloc_zone_statistics(nil, &cleared)
        print("LAYOUT_STORAGE rows=\(cachedRows) releasedBytes=\(Int64(allocated.size_in_use)-Int64(cleared.size_in_use))")
        XCTAssertEqual(try XCTUnwrap(bitmap.representation(using:.png,properties:[:])),expected)
        try expected.write(to:URL(fileURLWithPath:ProcessInfo.processInfo.environment["LINE_LAYOUT_PNG"] ?? "/tmp/line-layout.png"))
    }
}
#endif
