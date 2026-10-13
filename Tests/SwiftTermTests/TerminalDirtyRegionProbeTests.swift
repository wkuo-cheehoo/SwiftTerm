#if os(macOS)
import AppKit
@testable import SwiftTerm
import XCTest

@MainActor final class TerminalDirtyRegionProbeTests: XCTestCase {
    final class Counter: AccessibilityService {
        var count = 0
        override func invalidate() { count += 1 }
    }
    func testIdenticalPixelsDoNotSuppressAccessibilityInvalidation() {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x:0,y:0,width:800,height:500))
        let counter = Counter()
        view.accessibility = counter
        view.getTerminal().feed(text: "\u{1b}[?25lhello")
        view.updateDisplay(notifyAccessibility:true)
        XCTAssertEqual(counter.count,1)
        view.needsDisplay = false
        view.getTerminal().feed(text: "\u{1b}[Hhello")
        view.updateDisplay(notifyAccessibility:true)
        XCTAssertEqual(counter.count,2,"Redraw suppression must preserve requested accessibility updates")
    }

    final class Probe: TerminalView {
        var areas: [CGFloat] = []
        override func draw(_ rect: NSRect) { areas.append(rect.width * rect.height); super.draw(rect) }
    }
    func testPresentationChangesStillRedraw() async throws {
        _ = NSApplication.shared
        let window = FixtureWindow(contentRect:NSRect(x:100,y:100,width:1000,height:680),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let view = Probe(frame:NSRect(x:0,y:0,width:1000,height:680))
        window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        var invalidated = false
        // Assert renderer invalidation synchronously; WindowServer presentation
        // timing is not the contract under test. Pixel drawing is covered below.
        func flush() {
            view.updateDisplay(notifyAccessibility: false)
            invalidated = view.needsDisplay
            view.needsDisplay = false
        }
        view.feed(text:"\u{1b}[?25l" + (1...100).map { "line \($0) 中文 🌍\r\n" }.joined())
        flush()
        view.scroll(toPosition:0.5); flush()
        view.areas = []
        view.feed(text:"\u{1b}[12;1Hvisible changed line\u{1b}[K")
        flush(); XCTAssertTrue(invalidated,"Visible historical overlap must repaint")
        view.scroll(toPosition:1); flush()
        view.areas = []
        view.nativeForegroundColor = .systemRed
        flush(); XCTAssertTrue(invalidated,"Palette changes must repaint unchanged text")
        view.areas = []
        view.font = .monospacedSystemFont(ofSize:19,weight:.regular)
        flush(); XCTAssertTrue(invalidated,"Font changes must repaint")
        view.areas = []
        view.needsDisplay = true
        flush(); XCTAssertTrue(invalidated,"Explicit invalidation must repaint")
        view.areas = []
        view.feed(text:"\u{1b}[2J\u{1b}[Hnew screen")
        flush(); XCTAssertTrue(invalidated,"Clearing must repaint")
        view.feed(text:"\u{1b}[2J\u{1b}[H\u{1b}]8;;https://example.com\u{7}link\u{1b}]8;;\u{7}")
        flush(); XCTAssertNil(view.textDisplaySnapshot(),"Explicit links keep highlighting updates")
        view.feed(text:"\u{1b}[2J\u{1b}[Hمرحبا")
        flush(); XCTAssertNil(view.textDisplaySnapshot(),"BiDi keeps its dependency-aware path")
    }

    func testFixedCadenceDirtyRegions() async throws {
        _ = NSApplication.shared
        for mode in ["idle", "single", "scrollback", "same-screen", "changed-screen"] {
            let window = FixtureWindow(contentRect:NSRect(x:100,y:100,width:1000,height:680),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            let view = Probe(frame:NSRect(x:0,y:0,width:1000,height:680))
            view.disableFullRedrawOnAnyChanges = false
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            view.feed(text:"\u{1b}[?25l" + (1...100).map { "line \($0): fixed content 中文 emoji 🌍 a long enough line\r\n" }.joined())
            try await Task.sleep(for:.milliseconds(150))
            window.displayIfNeeded()
            if mode == "scrollback" { view.scroll(toPosition:0.0); try await Task.sleep(for:.milliseconds(100)); window.displayIfNeeded() }
            func pixels() throws -> Data {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
                view.cacheDisplay(in:view.bounds,to:bitmap)
                return try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            }
            if mode == "same-screen" { view.feed(text:"\u{1b}[H" + (1...25).map { "line \($0) value 0 中文 🌍\u{1b}[K\r\n" }.joined()); try await Task.sleep(for:.milliseconds(100)); window.displayIfNeeded() }
            let b = view.getTerminal().displayBuffer
            print("VIEWPORT mode=\(mode) yBase=\(b.yBase) yDisp=\(b.yDisp) rows=\(b.rows)")
            let beforePixels = try pixels()
            view.areas = []
            var before = rusage(), after = rusage()
            getrusage(RUSAGE_SELF,&before)
            for n in 0..<100 {
                if mode == "single" || mode == "scrollback" {
                    view.feed(text:"\u{1b}[12;1Hupdated line \(n) 中文 🌍\u{1b}[K")
                } else if mode != "idle" {
                    let value = mode == "same-screen" ? 0 : n
                    view.feed(text:"\u{1b}[H" + (1...25).map { "line \($0) value \(value) 中文 🌍\u{1b}[K\r\n" }.joined())
                }
                try await Task.sleep(for:.milliseconds(25))
                window.displayIfNeeded()
            }
            getrusage(RUSAGE_SELF,&after)
            let cpu = Double(after.ru_utime.tv_sec + after.ru_stime.tv_sec - before.ru_utime.tv_sec - before.ru_stime.tv_sec) + Double(after.ru_utime.tv_usec + after.ru_stime.tv_usec - before.ru_utime.tv_usec - before.ru_stime.tv_usec)/1_000_000
            print("DIRTY_REGION_PROBE mode=\(mode) draws=\(view.areas.count) viewportEquivalents=\(view.areas.reduce(0,+)/(1000*680)) cpu=\(cpu)")
            if ["idle","scrollback","same-screen"].contains(mode) { XCTAssertTrue(view.areas.isEmpty) } else { XCTAssertFalse(view.areas.isEmpty) }
            let identical = try pixels() == beforePixels
            print("PIXEL_PROBE mode=\(mode) unchanged=\(identical)")
            if ["idle","scrollback","same-screen"].contains(mode) { XCTAssertTrue(identical) }
            window.orderOut(nil)
        }
    }
}

@MainActor private final class FixtureWindow: NSWindow {
 override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) { super.init(contentRect:contentRect,styleMask:styleMask,backing:backing,defer:flag); animationBehavior = .none }
}
#endif
