// Player.swift: the sound. The thirteen tracks of the Android app (the guide, then each element in the natural order,
// Mantra Voice and Indian Raga), played natively with AVAudioEngine into the output chosen here (BlackHole 2ch for the
// stream) without touching the Mac's default output (the ADAM D3V stays the system's). A tap on the mixer keeps the
// last 1024 samples of each channel for the visualizer and the level for the meter.
import AVFoundation
import CoreAudio
import AudioToolbox
import Foundation

struct Track: Hashable {
    let file: String        // the name in android/app/src/main/assets/web/audio
    let element: String     // "Earth · A"
    let style: String       // "Mantra Voice" | "Indian Raga" | ""
    var title: String { style.isEmpty ? element : "\(element) · \(style)" }
}

let ELEMENTS: [(String, String)] = [("earth", "Earth · A"), ("water", "Water · U"), ("fire", "Fire · I"),
                                    ("air", "Air · O"), ("ether", "Ether · A-U-I-O"), ("aum", "OM")]
let TRACKS: [Track] = [Track(file: "guide.mp3", element: "The guide", style: "")]
    + ELEMENTS.flatMap { (id, name) in [Track(file: "\(id)-voice.ogg", element: name, style: "Mantra Voice"),
                                        Track(file: "\(id)-raga.ogg", element: name, style: "Indian Raga")] }

struct OutDev: Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

enum Devices {
    static func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                        _ value: inout T) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr
    }
    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
        var s: Unmanaged<CFString>? = nil
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr, let v = s else { return "" }
        return v.takeRetainedValue() as String
    }
    static func outputChannels(_ id: AudioDeviceID) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                           mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    /// the system's own private aggregates (made for a process) are not outputs to choose
    static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t) == noErr, t == kAudioDeviceTransportTypeAggregate else { return false }
        return string(id, kAudioDevicePropertyDeviceUID).hasPrefix("CADefaultDeviceAggregate") || string(id, kAudioObjectPropertyName).isEmpty
    }
    /// every device that can play sound, in the order CoreAudio gives them
    static func outputs() -> [OutDev] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { outputChannels($0) > 0 && !string($0, kAudioObjectPropertyName).hasPrefix("CADefaultDeviceAggregate") && !isPrivateAggregate($0) }
            .map { OutDev(id: $0, name: string($0, kAudioObjectPropertyName), uid: string($0, kAudioDevicePropertyDeviceUID)) }
    }
    static func defaultOutput() -> OutDev? {
        var id = AudioDeviceID(0)
        guard prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &id)
        else { return nil }
        return outputs().first { $0.id == id }
    }
    /// a device by a word of its name ("BlackHole" finds "BlackHole 2ch"), exact name first
    static func find(_ word: String) -> OutDev? {
        let all = outputs(), w = word.lowercased()
        return all.first { $0.name.lowercased() == w } ?? all.first { $0.name.lowercased().contains(w) } ?? all.first { $0.uid == word }
    }
}

/// Where the songs are: the repository's own copy on this Mac (nothing downloaded), else a cache filled once from the
/// public repository (each file once, on the Download Monitor: the Mac is on a 4G SIM).
enum Songs {
    static let repoDir = NSHomeDirectory() + "/Developer/MANTRA_ROOM/android/app/src/main/assets/web/audio"
    static let cacheDir = NSHomeDirectory() + "/Library/Application Support/Meditation Room (Mantra)/tracks"
    static let raw = "https://raw.githubusercontent.com/markoboskoauroville/MANTRA_ROOM/main/android/app/src/main/assets/web/audio/"

    static func url(_ t: Track) -> URL? {
        for d in [repoDir, cacheDir] {
            let p = d + "/" + t.file
            if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }
    static var missing: [Track] { TRACKS.filter { url($0) == nil } }

    /// downloads what is missing, one file at a time; `done` on the main queue with the count still missing
    static func fetchMissing(progress: @escaping (String) -> Void, done: @escaping (Int) -> Void) {
        let todo = missing
        guard !todo.isEmpty else { done(0); return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            for t in todo {
                let dest = cacheDir + "/" + t.file, part = dest + ".part"
                DispatchQueue.main.async { progress("downloading \(t.file)") }
                let id = "meditation-room-" + t.file.replacingOccurrences(of: ".", with: "-")
                run("/usr/bin/python3", [NSHomeDirectory() + "/Developer/DOWNLOAD_MONITOR/dlmon.py", "add", id,
                                         "--name", "Meditation Room (Mantra): \(t.file)", "--want-mb", "5", "--file", part,
                                         "--info", "a song of the meditation app, fetched once"])
                // curl -C - resumes a broken download (workflow-interface.md §5)
                if run("/usr/bin/curl", ["-sfL", "-C", "-", "-o", part, raw + t.file]) {
                    _ = try? FileManager.default.moveItem(atPath: part, toPath: dest)
                }
            }
            let left = missing.count
            DispatchQueue.main.async { done(left) }
        }
    }
    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: exe) || exe.hasSuffix("python3") else { return false }
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }
}

/// One output device: its own engine and player node, fed the same file as every other lane. The AUHAL of the engine is
/// pointed at the device; the Mac's default output is never touched.
final class Lane {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let dev: OutDev
    private var format: AVAudioFormat? = nil
    init(_ d: OutDev, gainDb: Double) {
        dev = d
        engine.attach(node)
        if let unit = engine.outputNode.audioUnit {
            var id = d.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        engine.mainMixerNode.outputVolume = Float(pow(10, gainDb / 20))
        let f = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        engine.connect(node, to: engine.mainMixerNode, format: f)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        format = f
    }
    func connect(_ f: AVAudioFormat) {
        guard format == nil || format!.sampleRate != f.sampleRate || format!.channelCount != f.channelCount else { return }
        let running = engine.isRunning
        if running { engine.stop() }
        engine.connect(node, to: engine.mainMixerNode, format: f)
        format = f
        if running { try? engine.start() }
    }
    func setGain(_ db: Double) { engine.mainMixerNode.outputVolume = Float(pow(10, db / 20)) }
    func halt() { node.stop(); if engine.isRunning { engine.stop() } }
}

final class Player: ObservableObject {
    @Published var playing = false
    @Published var index = 0
    @Published var pos: Double = 0
    @Published var dur: Double = 0
    @Published var level: Float = 0               // the output's peak, 0...1, for the meter
    @Published var peakDb: Double = -120          // the loudest sample of the last second, dBFS (after the gain)
    @Published var outputs: [OutDev] = []         // every device ticked: the sound plays on all of them together
    @Published var gainDb: Double = UserDefaults.standard.object(forKey: "gainDb") as? Double ?? 0
    @Published var until: Date? = nil
    @Published var note = ""
    @Published var styleLock: String = UserDefaults.standard.string(forKey: "styleLock") ?? ""   // "" = both styles in the loop
    @Published var played = 0                     // tracks started since launch (evidence of the loop)

    /// the first ticked device (the one the picture and the position are read from)
    var output: OutDev? { outputs.first }

    private var lanes: [Lane] = []
    private var observers: [NSObjectProtocol] = []
    private var startAt: Double = 0               // the position in the file where the segment began
    private var gen = 0
    private let lock = NSLock()
    private var ringL = [Float](repeating: 0, count: 1024), ringR = [Float](repeating: 0, count: 1024)
    private var peakHold: Float = 0, peakAt = Date()
    private var clock: Timer? = nil
    var onStop: (() -> Void)? = nil

    init() {
        let d = UserDefaults.standard
        var names = d.stringArray(forKey: "outputs") ?? []
        if names.isEmpty, let one = d.string(forKey: "output") { names = [one] }
        var devs: [OutDev] = []
        for n in names { if let x = Devices.find(n), !devs.contains(x) { devs.append(x) } }
        if devs.isEmpty, let def = Devices.defaultOutput() { devs = [def] }
        build(devs)
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.everyQuarter() }
        RunLoop.main.add(clock!, forMode: .common)
    }

    // ---------------------------------------------------------------- the output devices
    /// one lane per device; the tap for the picture and the meter sits on the first lane
    private func build(_ devs: [OutDev]) {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        if let old = lanes.first { old.engine.mainMixerNode.removeTap(onBus: 0) }
        for l in lanes { l.halt() }
        lanes = devs.map { Lane($0, gainDb: gainDb) }
        outputs = devs
        if let main = lanes.first {
            main.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in self?.take(buf) }
        }
        for l in lanes {
            observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: l.engine, queue: .main) { [weak self] _ in
                self?.recover()
            })
        }
    }
    private func save() {
        UserDefaults.standard.set(outputs.map(\.name), forKey: "outputs")
    }
    /// plays into exactly these devices from now on (the Mac's default output is never changed)
    func setOutputs(_ ds: [OutDev]) {
        var devs: [OutDev] = []
        for d in ds where !devs.contains(d) { devs.append(d) }
        if devs.isEmpty { note = "at least one output stays on"; return }
        let was = playing, at = pos
        gen += 1
        build(devs)
        save()
        if was { play(index, from: at) }
    }
    /// one device only (as before)
    func setOutput(_ d: OutDev) { setOutputs([d]) }
    func isOn(_ d: OutDev) -> Bool { outputs.contains(d) }
    func toggle(_ d: OutDev) {
        if isOn(d) { setOutputs(outputs.filter { $0 != d }) } else { setOutputs(outputs + [d]) }
    }
    func setGain(_ db: Double) {
        gainDb = max(-30, min(6, db))
        UserDefaults.standard.set(gainDb, forKey: "gainDb")
        for l in lanes { l.setGain(gainDb) }
    }
    private func recover() {
        // a device changed under an engine (a sample rate, BlackHole reset): the same devices and place again
        guard playing else { return }
        let at = pos
        note = "the output changed; continuing"
        let devs = outputs.map { o in Devices.find(o.uid) ?? Devices.find(o.name) ?? o }
        gen += 1
        build(devs)
        play(index, from: at)
    }

    // ---------------------------------------------------------------- playing
    func playLoop(from i: Int? = nil) { play(i ?? (playing ? index : index), from: 0) }

    func play(_ i: Int, from: Double = 0) {
        let n = (i % TRACKS.count + TRACKS.count) % TRACKS.count
        let t = TRACKS[n]
        guard let url = Songs.url(t) else { note = "\(t.file) is not on this Mac yet"; return }
        gen += 1; let g = gen
        for l in lanes { l.node.stop() }
        do {
            var failed: [String] = []
            var started: [Lane] = []
            var dur = 0.0, start0 = 0.0
            for (k, lane) in lanes.enumerated() {
                do {
                    let f = try AVAudioFile(forReading: url)       // each lane reads the file on its own
                    lane.connect(f.processingFormat)
                    let rate = f.processingFormat.sampleRate
                    let start = AVAudioFramePosition(max(0, min(from, Double(f.length) / rate - 0.5)) * rate)
                    let count = AVAudioFrameCount(max(1, f.length - start))
                    if k == 0 {
                        lane.node.scheduleSegment(f, startingFrame: start, frameCount: count, at: nil,
                                                  completionCallbackType: .dataPlayedBack) { [weak self] _ in
                            DispatchQueue.main.async { guard let s = self, s.gen == g, s.playing else { return }; s.advance() }
                        }
                        dur = Double(f.length) / rate; start0 = Double(start) / rate
                    } else {
                        lane.node.scheduleSegment(f, startingFrame: start, frameCount: count, at: nil, completionHandler: nil)
                    }
                    if !lane.engine.isRunning { try lane.engine.start() }
                    started.append(lane)
                } catch {
                    if k == 0 { throw error }
                    failed.append(lane.dev.name)
                    NSLog("[Room] %@ cannot play: %@", lane.dev.name, error.localizedDescription)
                }
            }
            if started.count == 1 { started[0].node.play() }
            else {                                                  // all lanes begin on the same host time
                let at = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.2))
                for l in started { l.node.play(at: at) }
            }
            index = n; startAt = start0; self.dur = dur; pos = startAt
            playing = true; played += 1; note = failed.isEmpty ? "" : "no sound on: " + failed.joined(separator: ", ")
            NSLog("[Room] play %d %@ from %.1f s on %d outputs", n, t.title, startAt, started.count)
            Captions.shared.trackStarted(t, from: startAt)
        } catch {
            note = "cannot play \(t.file): \(error.localizedDescription)"
            NSLog("[Room] %@", note)
            playing = false
        }
    }
    /// the next track; once a style is chosen (styleLock) the other style is skipped, the guide and OM-less tracks stay
    private func following() -> Int {
        var n = (index + 1) % TRACKS.count
        for _ in 0..<TRACKS.count where !styleLock.isEmpty && !TRACKS[n].style.isEmpty && TRACKS[n].style != styleLock {
            n = (n + 1) % TRACKS.count
        }
        return n
    }
    func next() { play(following()) }
    /// a click on the style word: Indian Raga <-> Mantra Voice of the same element, from the start, and the loop keeps that style
    func toggleStyle() {
        let cur = TRACKS[index].style
        guard !cur.isEmpty else { return }
        let other = cur == "Mantra Voice" ? "Indian Raga" : "Mantra Voice"
        styleLock = other
        UserDefaults.standard.set(other, forKey: "styleLock")
        let e = TRACKS[index].element
        if let j = TRACKS.firstIndex(where: { $0.element == e && $0.style == other }) { play(j) }
    }
    func stop() {
        gen += 1
        for l in lanes { l.node.stop(); if l.engine.isRunning { l.engine.pause() } }
        playing = false; pos = 0; level = 0
        lock.lock(); for i in 0..<1024 { ringL[i] = 0; ringR[i] = 0 }; lock.unlock()
        onStop?()
    }
    private func advance() {
        if let u = until, Date() >= u { NSLog("[Room] until reached"); until = nil; stop(); return }
        play(following())
    }
    private func everyQuarter() {
        if playing, let node = lanes.first?.node, let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t), p.sampleRate > 0 {
            pos = startAt + Double(p.sampleTime) / p.sampleRate
            Captions.shared.tick(pos: pos)
        }
        if let u = until, Date() >= u {
            NSLog("[Room] until %@ reached: stop", "\(u)")
            until = nil
            if playing { stop() }
        }
        lock.lock(); let pk = peakHold; let age = Date().timeIntervalSince(peakAt); lock.unlock()
        level = playing ? min(1, pk) : 0
        if age > 1 { peakDb = pk > 0 ? 20 * log10(Double(pk)) : -120; lock.lock(); peakHold = 0; peakAt = Date(); lock.unlock() }
    }

    // ---------------------------------------------------------------- the samples, for the picture
    private func take(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength), c = Int(buf.format.channelCount)
        guard n > 0 else { return }
        NDISender.shared.audio(buf)
        let l = ch[0], r = c > 1 ? ch[1] : ch[0]
        var pk: Float = 0
        lock.lock()
        let k = min(n, 1024)
        if k < 1024 { ringL.removeFirst(k); ringR.removeFirst(k) } else { ringL.removeAll(keepingCapacity: true); ringR.removeAll(keepingCapacity: true) }
        for i in (n - k)..<n { ringL.append(l[i]); ringR.append(r[i]); pk = max(pk, abs(l[i]), abs(r[i])) }
        peakHold = max(peakHold, pk)
        lock.unlock()
    }
    /// the last 1024 samples of each channel as butterchurn's bytes (128 = silence), base64
    func bytes() -> (String, String) {
        lock.lock(); let l = ringL, r = ringR; lock.unlock()
        func enc(_ a: [Float]) -> String {
            var d = [UInt8](repeating: 128, count: 1024)
            for i in 0..<min(1024, a.count) { d[i] = UInt8(max(0, min(255, Int((a[i] * 128).rounded()) + 128))) }
            return Data(d).base64EncodedString()
        }
        return (enc(l), enc(r))
    }

    var track: Track { TRACKS[index] }
}

/// "11:55" → the next time the clock says so (today, or tomorrow if it has passed)
func untilDate(_ s: String) -> Date? {
    let p = s.split(separator: ":").compactMap { Int($0) }
    guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
    let cal = Calendar.current
    guard var d = cal.date(bySettingHour: p[0], minute: p[1], second: 0, of: Date()) else { return nil }
    if d <= Date() { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
    return d
}
