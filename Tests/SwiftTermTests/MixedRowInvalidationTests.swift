#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

@MainActor final class MixedRowInvalidationTests: XCTestCase {
    func testMixedRowsOnlyInvalidateChangedOrComplexRows() throws {
        _ = NSApplication.shared
        let view = TerminalView(frame:NSRect(x:0,y:0,width:800,height:500))
        let terminal = view.getTerminal()
        terminal.feed(text:"\u{1b}[?25lunchanged\r\nمرحبا\r\nthird")
        XCTAssertEqual(view.textRedrawRange(0...2),0...2)
        XCTAssertNil(view.textRedrawRange(0...0))
        XCTAssertEqual(view.textRedrawRange(0...2),1...1)
        terminal.feed(text:"\u{1b}[3;1Hchanged")
        XCTAssertEqual(view.textRedrawRange(0...2),1...2)
        terminal.feed(text:"\u{1b}[2;1H\u{1b}[Kplain")
        XCTAssertEqual(view.textRedrawRange(1...1),1...1)
        XCTAssertNil(view.textRedrawRange(0...2))
    }
    func testWrappedParagraphAndPresentationChangesKeepDamage() throws {
        _ = NSApplication.shared
        let view = TerminalView(frame:NSRect(x:0,y:0,width:800,height:500))
        let terminal = view.getTerminal()
        terminal.feed(text:"\u{1b}[?25l" + String(repeating:"w",count:terminal.cols+4) + "\r\nstable")
        _ = view.textRedrawRange(0...2)
        XCTAssertEqual(view.textRedrawRange(0...2),0...1)
        XCTAssertNil(view.textRedrawRange(2...2))
        terminal.feed(text:"\u{1b}[?5h")
        XCTAssertEqual(view.textRedrawRange(0...2),0...2)
        view.selectAll(nil)
        XCTAssertEqual(view.textRedrawRange(2...2),2...2)
        view.selectNone()
        XCTAssertEqual(view.textRedrawRange(2...2),2...2)
    }
    final class DamageProbe: TerminalView {
        var damage: [NSRect] = []
        override func setNeedsDisplay(_ rect: NSRect) { damage.append(rect); super.setNeedsDisplay(rect) }
    }
    func testExplicitDamageIsNotSuppressedAndParserStillUpdates() async throws {
        _ = NSApplication.shared
        let view = DamageProbe(frame:NSRect(x:0,y:0,width:800,height:500))
        let window = FixtureWindow(contentRect:view.bounds,styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        let terminal = view.getTerminal()
        terminal.feed(text:"\u{1b}[?25lsame\r\nمرحبا")
        view.updateDisplay(notifyAccessibility:false)
        try await Task.sleep(for:.milliseconds(150)); window.displayIfNeeded()
        // Window attachment can resize the terminal after its first snapshot.
        terminal.feed(text:"\u{1b}[Hsame")
        view.updateDisplay(notifyAccessibility:false); window.displayIfNeeded()
        view.needsDisplay = false; view.damage = []
        terminal.feed(text:"\u{1b}[Hsame")
        view.updateDisplay(notifyAccessibility:false)
        XCTAssertTrue(view.damage.isEmpty)
        XCTAssertEqual(terminal.displayBuffer.x,4)
        view.damage = []; view.needsDisplay = true
        terminal.feed(text:"\u{1b}[Hsame")
        view.updateDisplay(notifyAccessibility:false)
        XCTAssertFalse(view.damage.isEmpty)
    }
}
@MainActor private final class FixtureWindow: NSWindow {
 override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
  super.init(contentRect:contentRect,styleMask:styleMask,backing:backing,defer:flag); animationBehavior = .none
 }
}
#endif
