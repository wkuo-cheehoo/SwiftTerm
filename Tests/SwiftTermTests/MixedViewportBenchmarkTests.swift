#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

@MainActor final class MixedViewportBenchmarkTests: XCTestCase {
    final class DrawProbe: TerminalView {
        var draws = 0
        override func draw(_ rect: NSRect) { draws += 1; super.draw(rect) }
    }
    func testRepeatedSimpleRowsBesideComplexText() async throws {
        guard ProcessInfo.processInfo.environment["MIXED_VIEWPORT_BENCH"] == "1" else { throw XCTSkip("Opt-in renderer benchmark") }
        _ = NSApplication.shared
        let window = FixtureWindow(contentRect:NSRect(x:0,y:0,width:800,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let view = DrawProbe(frame:NSRect(x:0,y:0,width:800,height:500))
        window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        let terminal = view.getTerminal()
        terminal.feed(text:"\u{1b}[?25lunchanged first row\r\nمرحبا\r\nthird row")
        view.updateDisplay(notifyAccessibility:false); try await Task.sleep(for:.milliseconds(150)); window.displayIfNeeded()
        view.draws = 0
        var before = rusage(), after = rusage(), invalidations = 0
        getrusage(RUSAGE_SELF,&before)
        for _ in 0..<100 {
            try await Task.sleep(for:.milliseconds(25))
            terminal.feed(text:"\u{1b}[Hunchanged first row")
            view.updateDisplay(notifyAccessibility:false)
            if view.needsDisplay { invalidations += 1 }
            window.displayIfNeeded()
        }
        getrusage(RUSAGE_SELF,&after)
        func cpuSeconds(_ usage: rusage) -> Double {
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec)/1e6
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec)/1e6
            return user + system
        }
        let cpu = cpuSeconds(after) - cpuSeconds(before)
        print("MIXED_VIEWPORT updates=100 invalidations=\(invalidations) draws=\(view.draws) cpuSeconds=\(cpu)")
    }
}
@MainActor private final class FixtureWindow: NSWindow {
 override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
  super.init(contentRect:contentRect,styleMask:styleMask,backing:backing,defer:flag); animationBehavior = .none
 }
}
#endif
