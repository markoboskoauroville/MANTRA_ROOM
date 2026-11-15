// Meditation Room (Mantra) for the Mac: the Android Mantra Meditation Room (repo MANTRA_ROOM) in Swift, with its MilkDrop
// visuals, every track in a loop into any output (BlackHole 2ch for a stream) and the picture on the G815's keys.
// Marko, 15.11.2026: "Convert it to Swift and then we have the same meditation app in my Mac ... publish it as a Mac app,
// Meditation 1 ... enable control of the keyboard with the visualization from the meditation app."
//
// Start options (also through the door, Door.swift):
//   open -g -a "Meditation Room (Mantra)" --args --play-loop --output "BlackHole 2ch" --lights --until 11:55 --gain-db -5
import AppKit
import SwiftUI
import WebKit

let VERSION = 19
let APP_NAME = "Meditation Room (Mantra)"

enum Ink {
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
    static let ground = hex(0x0B0B0D)
    static let line = hex(0x2E2E33)
    static let text = hex(0xECECEC)
    static let dim = hex(0x8E8E96)
    static let green = hex(0x33D17A)
    static let grey = hex(0x7A8087)
    static let amber = hex(0xF0A030)
    static let gold = hex(0xD4AF37)          // Earth, the one true colour (chakra-colors.md)
    // the rainbow, left to right (the Android app's RAINBOW7)
    static let rainbow: [Color] = [hex(0xE8364F), hex(0xFF8A2B), hex(0xE9C84A), hex(0x2FB45A), hex(0x38B6EC), hex(0x7B6CF0), hex(0xB58CF0)]
}

struct PressHover: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hot = false
    func body(content: Content) -> some View {
        let on = hot && enabled
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(on ? 0.12 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(on ? 0.55 : 0), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: on)
            .onHover { inside in hot = inside
                if enabled { if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } } }
    }
}

extension View {
    func pressHover() -> some View { modifier(PressHover()) }
    func axButton(_ label: String, id: String, value: String? = nil, _ action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
            .accessibilityValue(value ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
    /// a word that is a button: tap, hover highlight, Accessibility button
    func word(_ label: String, id: String, value: String? = nil, _ action: @escaping () -> Void) -> some View {
        self.pressHover().contentShape(Rectangle()).onTapGesture(perform: action).axButton(label, id: id, value: value, action)
    }
}

/// words laid out in rows that wrap: nothing is cut at the minimum width
struct Flow: Layout {
    var spacing: CGFloat = 12
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 800
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > w { y += row + 6; x = 0; row = 0 }
            x += s.width + spacing; row = max(row, s.height); maxW = max(maxW, x - spacing)
        }
        return CGSize(width: min(w, maxW), height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX && x + s.width > b.maxX { y += row + 6; x = b.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

/// immersive view: the window goes native full screen on its own display, the picture alone; Esc brings it back
final class Immersive: ObservableObject {
    static let shared = Immersive()
    @Published var on = false
    private var hide: Timer?
    private var esc: Any?
    func changed(_ now: Bool) {
        on = now
        hide?.invalidate(); hide = nil
        if let e = esc { NSEvent.removeMonitor(e); esc = nil }
        if now {
            hide = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in NSCursor.setHiddenUntilMouseMoves(true) }
            esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                if e.keyCode == 53 { App.shared.window?.toggleFullScreen(nil); return nil }
                return e
            }
        } else { NSCursor.unhide() }
    }
    static func toggle() { App.shared.window?.toggleFullScreen(nil) }
}

struct Hairline: View { var body: some View { Rectangle().fill(Ink.line).frame(height: 1) } }

func clock(_ s: Double) -> String { let t = max(0, Int(s)); return "\(t / 60):" + String(format: "%02d", t % 60) }

// ---------------------------------------------------------------- the window
struct TopRow: View {
    @AppStorage("onTop") private var onTop = false
    @ObservedObject var ndi = NDISender.shared
    var body: some View {
        ZStack {
            (Text("Meditation Room").fontWeight(.bold) + Text(" (Mantra)").fontWeight(.regular))
                .font(.system(size: 15)).foregroundStyle(Ink.text)
            HStack(spacing: 10) {
                Spacer().frame(width: 64)
                Text("ON").foregroundStyle(Ink.green)
                Text("OFF").foregroundStyle(Ink.grey).word("Off", id: "off") { DispatchQueue.main.async { NSApp.terminate(nil) } }
                Spacer()
                Text("v\(VERSION)").foregroundStyle(Ink.dim)
                Text("NDI").foregroundStyle(ndi.on ? Ink.green : Ink.grey)
                    .word("NDI output", id: "ndi", value: ndi.on ? "on" : "off") { ndi.set(!ndi.on) }
                Text("TOP").foregroundStyle(onTop ? Ink.green : Ink.grey)
                    .word("Top", id: "top", value: onTop ? "on" : "off") { onTop.toggle(); TopRow.float(onTop) }
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.grey)
                    .frame(width: 22, height: 22)
                    .word("Immersive view", id: "immersive") { Immersive.toggle() }
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.grey)
                    .frame(width: 22, height: 22)
                    .word("Close window", id: "close") { App.shared.window?.performClose(nil) }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
        }
        .frame(height: 32)
        .onAppear { DispatchQueue.main.async { TopRow.float(onTop) } }
    }
    static func float(_ on: Bool) { App.shared.window?.level = on ? .floating : .normal; App.shared.enforceOneTitle() }
}

struct VizView: NSViewRepresentable {
    let viz: Viz
    func makeNSView(context: Context) -> WKWebView { viz.web }
    func updateNSView(_ v: WKWebView, context: Context) {}
}

/// a horizontal hairline that fills: progress, or the level of the output
struct Fill: View {
    let value: Double
    var color: Color = Ink.gold
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Ink.line)
                Rectangle().fill(color).frame(width: g.size.width * max(0, min(1, value)))
            }
        }.frame(height: 1)
    }
}

struct Cell<V: View>: View {
    let label: String
    @ViewBuilder var value: V
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.dim)
            value.font(.system(size: 13, weight: .bold, design: .monospaced))
        }
    }
}

struct Root: View {
    @ObservedObject var player: Player
    @ObservedObject var lights: Lights
    @ObservedObject var viz: Viz
    @ObservedObject var captions = Captions.shared
    @ObservedObject var immersive = Immersive.shared

    var body: some View {
        window
    }

    /// the picture alone; a click = the next visualization
    var picture: some View {
        VizView(viz: viz)
            .overlay(Color.clear.contentShape(Rectangle()).onTapGesture { viz.next() }
                .axButton("Next visualization", id: "visual-click") { viz.next() })
    }

    var window: some View {
        VStack(spacing: 0) {
            if !immersive.on { TopRow(); Hairline() }
            picture.frame(minHeight: immersive.on ? 0 : 220)      // the same view in both states: the web view stays attached
            if !immersive.on { Hairline(); controls.padding(.horizontal, 18).padding(.vertical, 12) }
        }
        .background(immersive.on ? Color.black : Ink.ground)
        .foregroundStyle(Ink.text)
        .ignoresSafeArea(.container, edges: .top)
    }

    var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            // SOUND: one button that changes its word, then NEXT
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(player.playing ? "STOP" : "PLAY LOOP").foregroundStyle(player.playing ? Ink.amber : Ink.green)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .word(player.playing ? "Stop" : "Play loop", id: "play-loop", value: player.playing ? "playing" : "stopped") {
                        if player.playing { player.until = nil; player.stop() } else { player.play(player.index) } }
                Text("NEXT").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Ink.text)
                    .word("Next", id: "next") { player.next() }
                Text("\(player.index + 1) / \(TRACKS.count)").font(.system(size: 13, design: .monospaced)).foregroundStyle(Ink.dim)
                HStack(spacing: 6) {
                    Text(player.track.element).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.rainbow[player.index % Ink.rainbow.count])
                    if !player.track.style.isEmpty {
                        Text("·").foregroundStyle(Ink.dim)
                        // a click switches Indian Raga <-> Mantra Voice (same element), the loop keeps that style
                        Text(player.track.style.uppercased()).font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Ink.rainbow[player.index % Ink.rainbow.count])
                            .word(player.track.style == "Mantra Voice" ? "Switch to Indian Raga" : "Switch to Mantra Voice", id: "style-toggle",
                                  value: player.track.style) { player.toggleStyle() }
                    }
                }.fixedSize()
                Spacer(minLength: 8)
                Text("\(clock(player.pos)) / \(clock(player.dur))").font(.system(size: 13, design: .monospaced)).foregroundStyle(Ink.dim)
            }
            Fill(value: player.dur > 0 ? player.pos / player.dur : 0)

            // OUTPUTS: every device is a word; tick as many as you like, the sound plays on all of them together
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("OUTPUTS").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.dim)
                    Fill(value: Double(player.level), color: Ink.green).frame(width: 90)
                }
                Flow(spacing: 18) {
                    ForEach(Devices.outputs(), id: \.self) { d in
                        Text((player.isOn(d) ? "● " : "○ ") + d.name).font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(player.isOn(d) ? Ink.green : Ink.grey).fixedSize()
                            .word(d.name, id: "output-" + d.uid, value: player.isOn(d) ? "on" : "off") { player.toggle(d) }
                    }
                }
            }

            Flow(spacing: 24) {
                Cell(label: "GAIN") {
                    HStack(spacing: 6) {
                        Text("−").word("Gain down", id: "gain-down") { player.setGain(player.gainDb - 1) }
                        Text(String(format: "%+.0f dB", player.gainDb)).fixedSize()
                        Text("+").word("Gain up", id: "gain-up") { player.setGain(player.gainDb + 1) }
                    }
                }
                Cell(label: "DUCK") {
                    Text(player.duckOn ? (player.ducking ? "ON · DUCKING" : "ON") : "OFF").fixedSize().foregroundStyle(player.duckOn ? Ink.green : Ink.grey)
                        .word("Duck under the voice", id: "duck", value: player.duckOn ? "on" : "off") { player.setDuck(!player.duckOn) }
                }
                Cell(label: "PEAK") { Text(player.peakDb > -100 ? String(format: "%.1f dBFS", player.peakDb) : "—").fixedSize() }
                Cell(label: "STOPS AT") {
                    HStack(spacing: 6) {
                        Text(player.until.map { d in let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) } ?? "—").fixedSize()
                        if player.until != nil {
                            Text("CLEAR").foregroundStyle(Ink.grey).word("Clear the stop time", id: "until-clear") { player.until = nil }
                        }
                    }
                }
            }

            Hairline()
            Flow(spacing: 24) {
                Cell(label: "KEYBOARD LIGHTS") {
                    Text(lights.on ? "ON" : "OFF").foregroundStyle(lights.on ? Ink.green : Ink.grey)
                        .word("Keyboard lights", id: "lights", value: lights.on ? "on" : "off") { lights.set(!lights.on) }
                }
                Cell(label: "SHOWS") {
                    HStack(spacing: 4) {
                        ForEach(["meditation", "patterns", "both"], id: \.self) { m in
                            if m != "meditation" { Text("|").foregroundStyle(Ink.dim) }
                            Text(m.uppercased()).fixedSize().foregroundStyle(lights.mode == m ? Ink.green : Ink.grey)
                                .word("Lights show " + m, id: "lights-" + m, value: lights.mode == m ? "on" : "off") { lights.setMode(m) }
                        }
                    }
                }
                Cell(label: "G815") {
                    Text(lights.on ? (lights.error.isEmpty ? (lights.pattern.isEmpty ? "\(lights.way) · \(Int(lights.fps.rounded())) fps · \(lights.sent) frames" : "pattern \(lights.pattern)") : lights.error) : "—")
                        .foregroundStyle(lights.error.isEmpty ? Ink.text : Ink.amber).fixedSize()
                }
                Cell(label: "VISUAL") {
                    HStack(spacing: 6) {
                        Text("‹").word("Previous style", id: "style-prev") { viz.prev() }
                        Text(viz.styleName.isEmpty ? "—" : viz.styleName).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
                        Text("›").word("Next style", id: "style-next") { viz.next() }
                        Text("AUTO").foregroundStyle(viz.auto ? Ink.green : Ink.grey)
                            .word("Auto style", id: "style-auto", value: viz.auto ? "on" : "off") { viz.setAuto(!viz.auto) }
                    }
                }
            }
            Hairline()
            Flow(spacing: 24) {
                Cell(label: "TEXT") {
                    Text(captions.textOn ? "ON" : "OFF").foregroundStyle(captions.textOn ? Ink.green : Ink.grey)
                        .word("Melting text", id: "text", value: captions.textOn ? "on" : "off") { captions.setText(!captions.textOn) }
                }
                Cell(label: "PRE-SHOW") {
                    Text(captions.preOn ? "ON" : "OFF").foregroundStyle(captions.preOn ? Ink.green : Ink.grey)
                        .word("Pre-show", id: "preshow", value: captions.preOn ? "on" : "off") { captions.setPre(!captions.preOn) }
                }
                Cell(label: "LIVE STREAM STARTS") {
                    HStack(spacing: 8) {
                        Text("−5").foregroundStyle(Ink.grey).word("Five minutes earlier", id: "preshow-earlier") { captions.shift(minutes: -5) }
                        Text(captions.preUntil.map { d in let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) } ?? "—").fixedSize()
                        Text("+5").foregroundStyle(Ink.grey).word("Five minutes later", id: "preshow-later") { captions.shift(minutes: 5) }
                    }
                }
            }
            if !player.note.isEmpty {
                Text(player.note).font(.system(size: 12)).foregroundStyle(Ink.amber)
            }
        }
    }
}

// ---------------------------------------------------------------- the app
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let shared = App()
    let player = Player()
    let lights = Lights()
    let viz = Viz()
    var window: NSWindow?
    private var activity: NSObjectProtocol?
    private var refresh: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        menu()
        viz.player = player; viz.lights = lights
        Door.shared.player = player; Door.shared.lights = lights; Door.shared.viz = viz
        Door.shared.start()
        NDISender.shared.viz = viz
        makeWindow()
        // the visual keeps running and the stream keeps going with the window behind others (no App Nap)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "playing the meditation loop and the keyboard lights")
        refresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.viz.refresh(); Captions.shared.poll() }
        Songs.fetchMissing(progress: { [weak self] m in self?.player.note = m }) { [weak self] left in
            self?.player.note = left == 0 ? "" : "\(left) songs could not be downloaded"
            self?.arguments()
        }
        Updater.checkAtStart()
    }

    func arguments() {
        let a = CommandLine.arguments
        func val(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        let outs = a.enumerated().filter { $0.element == "--output" && $0.offset + 1 < a.count }.compactMap { Devices.find(a[$0.offset + 1]) }
        if !outs.isEmpty { player.setOutputs(outs) }      // --output may be given more than once
        if let g = val("--gain-db").flatMap(Double.init) { player.setGain(g) }
        if let u = val("--until") { player.until = untilDate(u) }
        if a.contains("--lights") { lights.set(true) }
        if a.contains("--no-lights") { lights.set(false) }
        if let m = val("--lights-mode") { lights.setMode(m) }
        if let u = val("--preshow-until"), let d = untilDate(u) { Captions.shared.setPre(true, until: d) }
        if a.contains("--no-text") { Captions.shared.setText(false) }
        if a.contains("--ndi") || NDISender.wantsOn { NDISender.shared.set(true) }
        if a.contains("--play-loop") { player.play(val("--from").flatMap(Int.init).map { $0 - 1 } ?? 0) }
    }

    func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = APP_NAME
        w.titleVisibility = .hidden
        w.tabbingMode = .disallowed
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.isRestorable = false                    // never reopen in native full screen (immersive); it starts as a window
        w.backgroundColor = NSColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1)
        w.contentMinSize = NSSize(width: 860, height: 520)
        w.contentView = NSHostingView(rootView: Root(player: player, lights: lights, viz: viz))
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("MeditationRoomMain")
        window = w
        enforceOneTitle(w)
        w.orderFront(nil)
        DispatchQueue.main.async { self.enforceOneTitle(w) }
    }

    /// ONE TITLE ONLY (Marko 15.11.2026: "don't repeat this bug"). The app draws its own title (TopRow); the system title
    /// stays hidden in every state: creation, key, resize, full screen, TOP. Called from all of them; also blanks any
    /// title text field AppKit keeps in the title bar (the faded echo). MANTRA_MANIFEST modules/one-title-only.md.
    func enforceOneTitle(_ w: NSWindow? = nil) {
        guard let w = w ?? window else { return }
        w.title = APP_NAME                      // kept for Mission Control and Accessibility, never drawn
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        func walk(_ v: NSView) {
            if v === w.contentView { return }   // the app's own title lives inside; do not touch it
            if let t = v as? NSTextField, t.stringValue == APP_NAME { t.isHidden = true; t.alphaValue = 0 }
            v.subviews.forEach(walk)
        }
        if let frame = w.contentView?.superview { walk(frame) }
    }
    func windowDidBecomeKey(_ n: Notification) { enforceOneTitle() }
    func windowDidResignKey(_ n: Notification) { enforceOneTitle() }
    func windowDidResize(_ n: Notification) { enforceOneTitle() }
    func windowDidEnterFullScreen(_ n: Notification) { enforceOneTitle(); Immersive.shared.changed(true) }
    func windowDidExitFullScreen(_ n: Notification) { enforceOneTitle(); Immersive.shared.changed(false) }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }   // ✕ closes the window, the sound goes on
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); return true
    }
    func applicationWillTerminate(_ n: Notification) {
        if lights.on { lights.set(false); Thread.sleep(forTimeInterval: 0.3) }    // OFF leaves the keys to G815 Lights
    }

    private func menu() {
        let m = NSMenu(), item = NSMenuItem(), sub = NSMenu()
        sub.addItem(withTitle: "Quit \(APP_NAME)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = sub; m.addItem(item); NSApp.mainMenu = m
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = App.shared
        app.run()
    }
}
