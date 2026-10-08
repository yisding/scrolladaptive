// Permission to use, copy, modify, and/or distribute this software for
// any purpose with or without fee is hereby granted.
//
// THE SOFTWARE IS PROVIDED “AS IS” AND THE AUTHOR DISCLAIMS ALL
// WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES
// OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE
// FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY
// DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
// AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT
// OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

// scrolladaptive
//
// Workaround for UTM/Virtualization.framework trackpad stalls in macOS guests.
// Filters out empty scroll events and animates a hidden window while you're
// scrolling to keep the compositor alive. Run it inside the guest, not the host.
//
// Install (builds, then starts at login):
//   ./install.sh
//
// Build only:
//   swiftc -O -target arm64-apple-macosx13.0 scrolladaptive.swift \
//     -o build/scrolladaptive
//
// This needs Accessibility permission because its session event tap can drop
// events. On first run it asks for permission and waits until it's granted.
// The tap runs on its own run-loop thread. AppKit/Core Animation stay on the
// main thread.
//
// Context: https://github.com/utmapp/UTM/issues/7531

import AppKit
import CoreGraphics
import Foundation
import QuartzCore

private let surfaceUpdateRate = 30.0
private let permissionPollSeconds = 1.0
private let inactivityDelaySeconds = 0.5
private let inactivityDelayNanoseconds =
  UInt64((inactivityDelaySeconds * 1_000_000_000).rounded())

private let deltaFields: [CGEventField] = [
  .scrollWheelEventDeltaAxis1,
  .scrollWheelEventDeltaAxis2,
  .scrollWheelEventDeltaAxis3,
  .scrollWheelEventPointDeltaAxis1,
  .scrollWheelEventPointDeltaAxis2,
  .scrollWheelEventPointDeltaAxis3,
  .scrollWheelEventFixedPtDeltaAxis1,
  .scrollWheelEventFixedPtDeltaAxis2,
  .scrollWheelEventFixedPtDeltaAxis3,
]

private final class NonKeyWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class ColorView: NSView {
  let colorLayer = CALayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    colorLayer.isOpaque = true
    colorLayer.backgroundColor = NSColor.black.cgColor
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func makeBackingLayer() -> CALayer {
    colorLayer
  }
}

private struct CompositorStats {
  var starts: UInt64 = 0
  var updates: UInt64 = 0
  var activeNanoseconds: UInt64 = 0
}

@MainActor
private final class CompositorKeepalive {
  private static let size: CGFloat = 1
  private static let colors = (
    NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.18, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.16, green: 0.06, blue: 0.10, alpha: 1).cgColor
  )

  private let view: ColorView
  private let window: NSWindow
  private var surfaceUpdateTimer: DispatchSourceTimer?
  private var isActive = false
  private var useAlternateColor = false
  private var activeStartedAtNanoseconds: UInt64 = 0
  private var stats = CompositorStats()

  init() {
    let size = Self.size
    let frame = NSRect(x: 0, y: 0, width: size, height: size)
    let view = ColorView(frame: frame)
    let window = NonKeyWindow(
      contentRect: frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    window.backgroundColor = .black
    window.isOpaque = true
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.orderOut(nil)
    self.view = view
    self.window = window
  }

  // Put it behind the menu bar. The guest's resolution changes whenever the UTM
  // window is resized, so this runs on every start rather than once.
  private func moveBehindMenuBar() {
    guard let screen = NSScreen.screens.first else { return }
    let size = Self.size
    window.setFrameOrigin(
      NSPoint(x: screen.frame.maxX - size - 1, y: screen.frame.maxY - size - 1)
    )
  }

  func start() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !isActive else { return }

    isActive = true
    stats.starts &+= 1
    activeStartedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    moveBehindMenuBar()
    window.orderFrontRegardless()
    updateSurface()

    let interval = max(1, Int((1_000_000_000 / surfaceUpdateRate).rounded()))
    let surfaceUpdateTimer = DispatchSource.makeTimerSource(queue: .main)
    surfaceUpdateTimer.schedule(
      deadline: .now() + .nanoseconds(interval),
      repeating: .nanoseconds(interval),
      leeway: .milliseconds(3)
    )
    surfaceUpdateTimer.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.isActive else { return }
        self.updateSurface()
      }
    }
    self.surfaceUpdateTimer = surfaceUpdateTimer
    surfaceUpdateTimer.resume()
  }

  private func updateSurface() {
    stats.updates &+= 1
    useAlternateColor.toggle()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    view.colorLayer.backgroundColor = useAlternateColor ? Self.colors.0 : Self.colors.1
    view.colorLayer.setNeedsDisplay()
    CATransaction.commit()
  }

  func stop() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard isActive else { return }
    surfaceUpdateTimer?.cancel()
    surfaceUpdateTimer = nil
    window.orderOut(nil)
    let now = DispatchTime.now().uptimeNanoseconds
    stats.activeNanoseconds &+= now &- activeStartedAtNanoseconds
    activeStartedAtNanoseconds = 0
    isActive = false
  }

  func stopAndSnapshot() -> CompositorStats {
    dispatchPrecondition(condition: .onQueue(.main))
    stop()
    return stats
  }
}

private struct TapStats {
  var events: UInt64 = 0
  var passed: UInt64 = 0
  var dropped: UInt64 = 0
  var disableCount: UInt64 = 0
}

// The event tap and its inactivity timer run on one private thread. Startup waits
// until that thread is ready, and shutdown waits until it has stopped. Swift
// cannot verify those handoffs, so this conformance must be unchecked.
private final class TapController: @unchecked Sendable {
  private let startKeepalive: @Sendable () -> Void
  private let stopKeepalive: @Sendable () -> Void
  private let ready = DispatchSemaphore(value: 0)
  private let stopped = DispatchSemaphore(value: 0)
  private var runLoop: CFRunLoop?
  private var tap: CFMachPort?
  private var inactivityTimer: Timer?
  private var lastContinuousScrollEventNanoseconds: UInt64 = 0
  private var startupError: String?
  private var stats = TapStats()

  init(
    startKeepalive: @escaping @Sendable () -> Void,
    stopKeepalive: @escaping @Sendable () -> Void
  ) {
    self.startKeepalive = startKeepalive
    self.stopKeepalive = stopKeepalive
  }

  func start() -> String? {
    let thread = Thread { [weak self] in
      self?.runTap()
    }
    thread.name = "scrolladaptive.event-tap"
    thread.qualityOfService = .userInitiated
    thread.start()
    ready.wait()
    return startupError
  }

  private func runTap() {
    autoreleasepool {
      let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
      guard
        let tap = CGEvent.tapCreate(
          tap: .cgSessionEventTap,
          place: .headInsertEventTap,
          options: .defaultTap,
          eventsOfInterest: mask,
          callback: tapCallback,
          userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
      else {
        startupError =
          "Could not create an active session event tap. Grant Accessibility permission."
        ready.signal()
        return
      }

      let runLoop = CFRunLoopGetCurrent()
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
      self.tap = tap
      self.runLoop = runLoop
      CFRunLoopAddSource(runLoop, source, .commonModes)
      CGEvent.tapEnable(tap: tap, enable: true)
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [ready] in
        ready.signal()
      }
      CFRunLoopRun()

      inactivityTimer?.invalidate()
      inactivityTimer = nil
      CGEvent.tapEnable(tap: tap, enable: false)
      CFRunLoopRemoveSource(runLoop, source, .commonModes)
      self.tap = nil
      stopped.signal()
    }
  }

  func stopAndSnapshot() -> TapStats {
    guard let runLoop else { return stats }
    CFRunLoopStop(runLoop)
    CFRunLoopWakeUp(runLoop)
    stopped.wait()
    self.runLoop = nil
    return stats
  }

  fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      stats.disableCount &+= 1
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

    stats.events &+= 1
    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    guard isContinuous else {
      stats.passed &+= 1
      return Unmanaged.passUnretained(event)
    }
    recordContinuousScrollEvent()

    if isEmptyScrollEvent(event) {
      stats.dropped &+= 1
      return nil
    }
    stats.passed &+= 1
    return Unmanaged.passUnretained(event)
  }

  private func recordContinuousScrollEvent() {
    lastContinuousScrollEventNanoseconds = DispatchTime.now().uptimeNanoseconds
    guard inactivityTimer == nil else {
      // The existing timer will use the new timestamp when it fires.
      return
    }

    startKeepalive()
    scheduleInactivityCheck(afterNanoseconds: inactivityDelayNanoseconds)
  }

  private func scheduleInactivityCheck(afterNanoseconds delayNanoseconds: UInt64) {
    let delay = TimeInterval(delayNanoseconds) / 1_000_000_000
    let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
      self?.inactivityTimerFired(timer)
    }
    inactivityTimer = timer
    RunLoop.current.add(timer, forMode: .common)
  }

  private func inactivityTimerFired(_ timer: Timer) {
    guard timer === inactivityTimer else { return }
    inactivityTimer = nil

    let now = DispatchTime.now().uptimeNanoseconds
    let elapsed = now &- lastContinuousScrollEventNanoseconds
    if elapsed < inactivityDelayNanoseconds {
      scheduleInactivityCheck(afterNanoseconds: inactivityDelayNanoseconds - elapsed)
    } else {
      stopKeepalive()
    }
  }

  // Only called for continuous (trackpad) events.
  private func isEmptyScrollEvent(_ event: CGEvent) -> Bool {
    guard
      event.getIntegerValueField(.scrollWheelEventScrollPhase)
        == CGScrollPhase.changed.rawValue,
      event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        == CGMomentumScrollPhase.none.rawValue
    else {
      return false
    }
    return deltaFields.allSatisfy { event.getDoubleValueField($0) == 0 }
  }
}

private nonisolated let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let controller = Unmanaged<TapController>.fromOpaque(userInfo).takeUnretainedValue()
  return controller.handle(type: type, event: event)
}

private let application = NSApplication.shared
application.setActivationPolicy(.accessory)

private let compositor = MainActor.assumeIsolated { CompositorKeepalive() }
private let tapController = TapController(
  startKeepalive: {
    DispatchQueue.main.async {
      compositor.start()
    }
  },
  stopKeepalive: {
    DispatchQueue.main.async {
      compositor.stop()
    }
  }
)

private func log(_ message: String) {
  FileHandle.standardError.write(Data("scrolladaptive: \(message)\n".utf8))
}

private func isVirtualMachine() -> Bool {
  var value: Int32 = 0
  var size = MemoryLayout<Int32>.size
  return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
}

private func isAccessibilityTrusted(prompt: Bool) -> Bool {
  // The value of kAXTrustedCheckOptionPrompt. Swift 6 rejects the global itself
  // because it's declared as a mutable var.
  let key = "AXTrustedCheckOptionPrompt"
  return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

private func arm() {
  if let error = tapController.start() {
    log(error)
    exit(1)
  }
  log("armed. Press Ctrl-C for statistics.")
}

// Wait for Accessibility permission instead of exiting, so a first run from a
// LaunchAgent doesn't need a restart after the user grants it. The main run loop
// keeps the timer alive until it invalidates itself.
private func armWhenTrusted() {
  if isAccessibilityTrusted(prompt: true) {
    arm()
    return
  }
  log(
    "waiting for Accessibility permission. Enable scrolladaptive in System Settings > "
      + "Privacy & Security > Accessibility."
  )
  Timer.scheduledTimer(withTimeInterval: permissionPollSeconds, repeats: true) { timer in
    guard isAccessibilityTrusted(prompt: false) else { return }
    timer.invalidate()
    MainActor.assumeIsolated { arm() }
  }
}

if !isVirtualMachine() {
  log(
    "warning: this Mac doesn't look like a virtual machine. scrolladaptive is meant to "
      + "run inside a macOS guest."
  )
}

@MainActor
private func finish(signalName: String) -> Never {
  let tapStats = tapController.stopAndSnapshot()
  let compositorStats = compositor.stopAndSnapshot()
  let activeSeconds = Double(compositorStats.activeNanoseconds) / 1_000_000_000
  let dropPercent =
    tapStats.events == 0
    ? 0
    : 100 * Double(tapStats.dropped) / Double(tapStats.events)
  FileHandle.standardError.write(
    Data(
      String(
        format:
          "scrolladaptive: %@; tap=%llu passed=%llu dropped=%llu (%.2f%%) disabled=%llu; CA starts=%llu updates=%llu active=%.2fs\n",
        signalName,
        tapStats.events,
        tapStats.passed,
        tapStats.dropped,
        dropPercent,
        tapStats.disableCount,
        compositorStats.starts,
        compositorStats.updates,
        activeSeconds
      ).utf8
    )
  )
  exit(0)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
private let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruptSource.setEventHandler {
  MainActor.assumeIsolated { finish(signalName: "SIGINT") }
}
interruptSource.resume()
private let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminateSource.setEventHandler {
  MainActor.assumeIsolated { finish(signalName: "SIGTERM") }
}
terminateSource.resume()

armWhenTrusted()
application.run()
