import Foundation
import AVFoundation
import CoreAudio
import Synchronization
import os

/// UI sounds and the looping panic alarm. Sounds are 48 kHz mono WAVs in Resources/Sounds, synthesised by
/// `scripts/make-sounds.py` (re-run it to change them; see that file for the sound design).
enum UISound: String, CaseIterable, Sendable {
    case countdownStart = "countdown-start"
    /// A countdown tick. Prefer `SoundPlayer.playTick(remaining:)`: the last three seconds get rising ticks.
    case tick
    case enter
    case dismiss
    case unlock
    case wrongPin = "wrong-pin"
    case question
    /// PIN pad key. Rotates through three slightly different clicks so fast typing doesn't machine-gun.
    case keypress
}

/// Plays Silicon Mode's sounds through one `AVAudioEngine`:
///
/// * **UI one-shots**: buffers are decoded on first use and cached; a small pool of player nodes lets sounds
///   overlap (fast PIN typing, a question ping during the enter chime) with ~10 ms latency.
/// * **Panic alarm**: a dedicated real-time loop voice (`PanicVoice`) plays the selected `panic-<id>.wav`
///   seamlessly, with a 150 ms fade-in and a 250 ms fade-out, at the user's panic volume.
///
/// The engine only runs while something is sounding (it stops after a few seconds of silence, so a Mac sitting
/// in Silicon Mode for hours doesn't keep the audio hardware and its IO thread awake) and is rebuilt when the
/// output device or its format changes (`AVAudioEngineConfigurationChange`), resuming an alarm that was playing.
/// Stopping the engine blocks for ~20 ms while the hardware winds down, so it happens on a background queue;
/// the next sound waits for an in-flight stop (rare) before restarting the engine.
///
/// Volume & mute: everything plays through the current default output device and respects the system volume
/// and mute. We deliberately never change system volume or unmute: a muted Mac, or one routed to headphones,
/// gets a silent/private alarm, and the flashing panic visuals still get attention. (Routing the alarm to the
/// built-in speakers / lifting mute is possible with public CoreAudio API, see docs/research/macos-ui.md §2.3,
/// if we ever want an opt-in "Always audible" setting.)
@MainActor
final class SoundPlayer {
    struct PanicSound: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        /// Seconds between the alarm's attention beats. Panic visuals can flash in sync:
        /// beat phase = (now - `panicStartedAt`) mod `beat`.
        var beat: Double = 0.6
    }

    /// Selectable panic sounds (ids map to Resources/Sounds/panic-<id>.wav). Each is a seamless loop.
    nonisolated static let panicSounds: [PanicSound] = [
        PanicSound(id: "klaxon", name: "Klaxon", beat: 0.6),   // horn blasts, 1.2 s loop
        PanicSound(id: "mistake", name: "Uh-oh", beat: 0.6),   // cartoon "uh-oh!", 1.2 s loop
        PanicSound(id: "siren", name: "Siren", beat: 1.6),     // rising/falling wail, 1.6 s loop
        PanicSound(id: "glitch", name: "Glitch", beat: 0.8),   // digital error stutter, 1.6 s loop
    ]

    nonisolated static let panicFadeIn: Double = 0.15
    nonisolated static let panicFadeOut: Double = 0.25
    nonisolated static let sampleRate: Double = 48_000

    /// Every file the app expects in Resources/Sounds (without extension).
    nonisolated static var bundledSoundNames: [String] {
        UISound.allCases.map(\.rawValue) + keypressVariants.dropFirst() + ["tick-3", "tick-2", "tick-1"]
            + panicSounds.map { panicFileName($0.id) }
    }

    /// Master level for UI one-shots (0...1). The panic alarm has its own volume.
    var uiVolume: Float = 1 {
        didSet { settleStop(); graph?.uiMixer.outputVolume = uiVolume }
    }

    /// True while the panic alarm (not a settings preview) is sounding or fading in.
    var isPanicPlaying: Bool { panicMode == .alarm }
    /// Whether the audio engine (and so the output device) is currently running. Diagnostics.
    var isEngineRunning: Bool { stopIssued ? false : (graph?.engine.isRunning ?? false) }
    /// Whether the panic voice is producing sound right now (as last reported by the audio thread).
    var isPanicAudible: Bool { graph.map { !$0.voice.isSilent } ?? false }
    /// When the sounding alarm's loop last started from its first sample (for syncing panic visuals to `beat`);
    /// nil when no alarm is playing.
    var panicStartedAt: Date? { panicMode == .alarm ? loopStartedAt : nil }

    private static let log = Logger(subsystem: "ai.tos.mode", category: "sound")
    nonisolated private static let keypressVariants = ["keypress", "keypress-2", "keypress-3"]
    private static let poolSize = 6
    private static let idleTimeout: Double = 4

    private let directory: URL?
    private let offline: Bool
    private let format = AVAudioFormat(standardFormatWithSampleRate: SoundPlayer.sampleRate, channels: 1)!
    private var graph: Graph?
    private var buffers: [String: AVAudioPCMBuffer] = [:]   // never evicted: PanicVoice reads loop samples in place
    private var missing: Set<String> = []
    private var keypressIndex = 0

    private enum PanicMode { case off, alarm, preview }
    private var panicMode: PanicMode = .off
    private var panicLoopName: String?
    private var panicGain: Float = 0
    private var loopStartedAt: Date?
    private var idleTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// Engine stops run here (they block while the audio hardware winds down).
    private let engineControl = DispatchQueue(label: "ai.tos.mode.sound.engine", qos: .utility)
    /// A background stop was issued and hasn't been waited for: drain `engineControl` before touching
    /// the engine or its players again.
    private var stopIssued = false

    /// - Parameters:
    ///   - soundsDirectory: where the WAVs live; defaults to the app bundle's Resources/Sounds.
    ///   - offlineRendering: test mode. The engine renders into memory (`renderOffline(frames:)`) instead of to
    ///     the audio hardware, so the player can be exercised headlessly.
    init(soundsDirectory: URL? = nil, offlineRendering: Bool = false) {
        directory = soundsDirectory
        offline = offlineRendering
    }

    // MARK: UI sounds

    func play(_ sound: UISound) {
        switch sound {
        case .keypress:
            keypressIndex = (keypressIndex + 1) % Self.keypressVariants.count
            playOneShot(Self.keypressVariants[keypressIndex])
        default:
            playOneShot(sound.rawValue)
        }
    }

    /// Countdown tick for the whole seconds still remaining: 3, 2 and 1 climb towards the enter chord;
    /// anything else plays the plain tick.
    func playTick(remaining: Int) {
        playOneShot((1...3).contains(remaining) ? "tick-\(remaining)" : UISound.tick.rawValue)
    }

    /// Decode every sound now (≈1.5 MB) so the first play of each doesn't touch the disk. Optional.
    func preload() {
        for name in Self.bundledSoundNames { _ = buffer(named: name) }
    }

    /// Build the graph and start the output once, silently, while nothing is on screen. The first start
    /// of an engine (graph, IO unit, output device) holds the main thread for 150–350 ms; paying it here
    /// keeps it off the countdown's and the entry's first frames. The idle check stops the engine again a
    /// few seconds later; restarting a built engine on the same device is quick.
    func warmUp() {
        guard !offline, panicMode == .off else { return }
        _ = ensureRunning()
    }

    // MARK: Panic

    /// Start (or keep) the looping alarm. Unknown ids fall back to the first panic sound, so it always sounds.
    func startPanic(soundID: String, volume: Double) {
        let name = resolvedPanicName(soundID)
        guard let loop = loopRef(named: name), let g = ensureRunning() else { return }
        previewTask?.cancel()
        let gain = Self.gain(forVolume: volume)
        // Re-use a loop that's still audible (e.g. stop → start while it fades out) instead of restarting it.
        let restart = panicLoopName != name || g.voice.isSilent
        g.voice.play(loop: restart ? loop : nil, gain: gain, fade: Self.panicFadeIn)
        if restart || loopStartedAt == nil { loopStartedAt = Date() }
        panicMode = .alarm
        panicLoopName = name
        panicGain = gain
    }

    /// Fade the alarm (or a preview) out over 250 ms — or at once (e.g. right before sleep, so
    /// nothing can resume it on wake).
    func stopPanic(immediate: Bool = false) {
        previewTask?.cancel()
        guard panicMode != .off else { return }
        panicMode = .off
        guard let g = graph else { return }
        g.voice.stop(fade: immediate ? 0.005 : Self.panicFadeOut, from: panicGain)
        scheduleIdleCheck()
    }

    /// Change the volume of a sounding alarm/preview (e.g. the settings slider moved). 0...1.
    func setPanicVolume(_ volume: Double) {
        guard panicMode != .off, let g = graph else { return }
        let gain = Self.gain(forVolume: volume)
        g.voice.setGain(gain, ramp: 0.08)
        panicGain = gain
    }

    /// Play one loop of a panic sound (at least 1.2 s), then fade out. Calling it again for the same sound while
    /// it plays only updates the volume and extends it, so it can follow a slider. Ignored during a real alarm.
    func preview(panicSoundID: String, volume: Double) {
        guard panicMode != .alarm else { return }
        let name = resolvedPanicName(panicSoundID)
        guard let loop = loopRef(named: name), let g = ensureRunning() else { return }
        let gain = Self.gain(forVolume: volume)
        let frames = max(loop.count, Int(1.2 * Self.sampleRate))
        let continuing = panicMode == .preview && panicLoopName == name && !g.voice.isSilent
        g.voice.play(loop: continuing ? nil : loop, gain: gain, fade: continuing ? 0.06 : 0.02,
                     stopAfter: frames, stopFade: Self.panicFadeOut)
        if !continuing { loopStartedAt = Date() }
        panicMode = .preview
        panicLoopName = name
        panicGain = gain
        previewTask?.cancel()
        if !offline {
            let seconds = Double(frames) / Self.sampleRate + Self.panicFadeOut + 0.05
            previewTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, self.panicMode == .preview else { return }
                self.panicMode = .off
                self.scheduleIdleCheck()
            }
        }
    }

    // MARK: Engine

    @MainActor private final class Graph {
        let engine = AVAudioEngine()
        let uiMixer = AVAudioMixerNode()
        let players: [AVAudioPlayerNode]
        var busyUntil: [TimeInterval]
        let voice: PanicVoice
        let panicNode: AVAudioSourceNode
        let device: AudioDeviceID
        var observer: (any NSObjectProtocol)?

        init(format: AVAudioFormat, offline: Bool, poolSize: Int) throws {
            if offline {
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            }
            device = offline ? 0 : SoundPlayer.defaultOutputDevice()
            voice = PanicVoice(sampleRate: format.sampleRate)
            panicNode = voice.makeNode(format: format)
            players = (0..<poolSize).map { _ in AVAudioPlayerNode() }
            busyUntil = Array(repeating: 0, count: poolSize)
            let main = engine.mainMixerNode
            engine.attach(uiMixer)
            engine.attach(panicNode)
            for p in players {
                engine.attach(p)
                engine.connect(p, to: uiMixer, format: format)
            }
            engine.connect(uiMixer, to: main, format: format)
            engine.connect(panicNode, to: main, format: format)
            main.outputVolume = 1
            engine.prepare()
        }
    }

    /// Waits for a background engine stop to finish (usually long done; at most ~20 ms).
    private func settleStop() {
        guard stopIssued else { return }
        engineControl.sync {}
        stopIssued = false
    }

    /// Builds the graph if needed and makes sure the engine runs. Returns nil if audio output is unavailable.
    private func ensureRunning() -> Graph? {
        settleStop()
        // A stopped engine may still point at an output device that is no longer the default: rebuild.
        if let g = graph, !offline, !g.engine.isRunning, g.device != Self.defaultOutputDevice() {
            teardown()
        }
        if graph == nil {
            do {
                let g = try Graph(format: format, offline: offline, poolSize: Self.poolSize)
                g.uiMixer.outputVolume = uiVolume
                if !offline {
                    g.observer = NotificationCenter.default.addObserver(
                        forName: .AVAudioEngineConfigurationChange, object: g.engine, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.engineConfigurationChanged() }
                    }
                }
                graph = g
            } catch {
                Self.log.error("audio graph failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard let g = graph else { return nil }
        if !g.engine.isRunning {
            do {
                try g.engine.start()
            } catch {
                Self.log.error("audio engine failed to start: \(error.localizedDescription, privacy: .public)")
                teardown()
                return nil
            }
        }
        scheduleIdleCheck()
        return g
    }

    private func teardown() {
        settleStop()
        guard let g = graph else { return }
        if let o = g.observer { NotificationCenter.default.removeObserver(o) }
        g.engine.stop()
        graph = nil
    }

    /// The output device or its format changed (headphones, AirPods, display audio…). The engine has stopped
    /// itself; rebuild it on the new output and keep a sounding alarm going there.
    private func engineConfigurationChanged() {
        Self.log.info("audio configuration changed; rebuilding the engine")
        let resume = panicMode == .alarm ? panicLoopName : nil
        teardown()
        if panicMode == .preview { panicMode = .off }
        guard let name = resume, let loop = loopRef(named: name), let g = ensureRunning() else { return }
        g.voice.play(loop: loop, gain: panicGain, fade: 0.03)
        loopStartedAt = Date()
    }

    private func scheduleIdleCheck(after delay: Double = SoundPlayer.idleTimeout) {
        guard !offline else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if !self.suspendIfIdle(), self.isEngineRunning { self.scheduleIdleCheck(after: 2) }
        }
    }

    /// Stops the engine (letting the audio hardware idle) if nothing is sounding. The stop itself runs on a
    /// background queue, off the main thread. The next sound restarts the engine, which costs a few ms once.
    /// Returns true if a stop was started.
    @discardableResult
    func suspendIfIdle() -> Bool {
        guard !stopIssued, let g = graph, g.engine.isRunning else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard panicMode == .off, g.voice.isSilent, !g.busyUntil.contains(where: { $0 > now }) else { return false }
        let handle = EngineHandle(engine: g.engine, players: g.players)
        stopIssued = true
        engineControl.async {
            for p in handle.players { p.stop() }
            handle.engine.stop()
        }
        return true
    }

    /// The engine and its players, handed to the stop queue. Nothing else touches them until that stop is
    /// settled (`settleStop()` runs first in every path that uses the engine).
    private final class EngineHandle: @unchecked Sendable {
        let engine: AVAudioEngine
        let players: [AVAudioPlayerNode]
        init(engine: AVAudioEngine, players: [AVAudioPlayerNode]) { self.engine = engine; self.players = players }
    }

    private func playOneShot(_ name: String) {
        guard let buffer = buffer(named: name), let g = ensureRunning() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // An idle player if there is one, else the one that frees up first (cut short: only under heavy overlap).
        let i = g.busyUntil.firstIndex(where: { $0 <= now })
            ?? g.busyUntil.indices.min(by: { g.busyUntil[$0] < g.busyUntil[$1] })!
        let node = g.players[i]
        if g.busyUntil[i] > now { node.stop() }
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        node.play()   // no-op if already playing; required after the engine was stopped and restarted
        g.busyUntil[i] = now + Double(buffer.frameLength) / Self.sampleRate + 0.05
    }

    // MARK: Buffers

    private func resolvedPanicName(_ id: String) -> String {
        let known = Self.panicSounds.contains { $0.id == id } ? id : Self.panicSounds[0].id
        return Self.panicFileName(known)
    }

    nonisolated private static func panicFileName(_ id: String) -> String { "panic-\(id)" }

    private func loopRef(named name: String) -> PanicVoice.LoopRef? {
        guard let b = buffer(named: name), let data = b.floatChannelData, b.frameLength > 0 else { return nil }
        return PanicVoice.LoopRef(samples: UnsafePointer(data[0]), count: Int(b.frameLength))
    }

    private func buffer(named name: String) -> AVAudioPCMBuffer? {
        if let b = buffers[name] { return b }
        guard !missing.contains(name) else { return nil }
        do {
            guard let url = Self.url(for: name, in: directory) else { throw SoundError.missing(name) }
            let b = try Self.decode(url, to: format)
            buffers[name] = b
            return b
        } catch {
            missing.insert(name)
            Self.log.error("sound \(name, privacy: .public) unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private enum SoundError: Error { case missing(String), unreadable, conversion }

    nonisolated private static func url(for name: String, in directory: URL?) -> URL? {
        if let directory {
            let u = directory.appendingPathComponent("\(name).wav")
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        return Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "wav")
    }

    /// Reads a whole file as float32 in `format` (48 kHz mono), converting if the file differs.
    nonisolated private static func decode(_ url: URL, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw SoundError.unreadable
        }
        try file.read(into: raw)
        if raw.format.sampleRate == format.sampleRate && raw.format.channelCount == format.channelCount {
            return raw
        }
        guard let converter = AVAudioConverter(from: raw.format, to: format) else { throw SoundError.conversion }
        let capacity = AVAudioFrameCount(Double(raw.frameLength) * format.sampleRate / raw.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw SoundError.conversion }
        let source = Once(raw)
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if let b = source.take() { status.pointee = .haveData; return b }
            status.pointee = .endOfStream
            return nil
        }
        if let conversionError { throw conversionError }
        return out
    }

    /// Hands its value out exactly once (input for AVAudioConverter's pull block).
    private final class Once: @unchecked Sendable {
        private var value: AVAudioPCMBuffer?
        init(_ value: AVAudioPCMBuffer) { self.value = value }
        func take() -> AVAudioPCMBuffer? { defer { value = nil }; return value }
    }

    // MARK: Helpers

    /// Slider position (0...1) → amplitude. Squared, so the slider feels even (half way ≈ -12 dB).
    nonisolated static func gain(forVolume volume: Double) -> Float {
        let v = Float(min(max(volume, 0), 1))
        return v * v
    }

    nonisolated static func defaultOutputDevice() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : 0
    }

    // MARK: Diagnostics & tests

    /// Decodes every bundled sound and describes it (name, length, peak) or the error. A debug aid that also
    /// backs the headless test harness; touches no audio hardware.
    nonisolated static func audit(soundsDirectory: URL? = nil) -> [String] {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        return bundledSoundNames.map { name in
            guard let url = url(for: name, in: soundsDirectory) else { return "MISSING \(name).wav" }
            do {
                let b = try decode(url, to: format)
                let n = Int(b.frameLength)
                var peak: Float = 0
                if let d = b.floatChannelData?[0] { for i in 0..<n { peak = max(peak, abs(d[i])) } }
                let db = 20 * log10(max(Double(peak), 1e-9))
                return String(format: "ok %@ %d frames %.0f ms peak %.1f dBFS", name, n, Double(n) / sampleRate * 1000, db)
            } catch {
                return "ERROR \(name).wav: \(error)"
            }
        }
    }

    /// Offline-rendering mode only: renders the next `frames` frames of the mix (mono).
    func renderOffline(frames: Int) -> [Float] {
        guard offline, let g = ensureRunning() else { return [] }
        let chunk = AVAudioFrameCount(4096)
        guard let buf = AVAudioPCMBuffer(pcmFormat: g.engine.manualRenderingFormat, frameCapacity: chunk) else { return [] }
        var out: [Float] = []
        out.reserveCapacity(frames)
        while out.count < frames {
            let n = AVAudioFrameCount(min(Int(chunk), frames - out.count))
            guard (try? g.engine.renderOffline(n, to: buf)) == .success, let d = buf.floatChannelData?[0] else { break }
            out.append(contentsOf: UnsafeBufferPointer(start: d, count: Int(buf.frameLength)))
        }
        return out
    }
}

/// The panic alarm's real-time loop voice, rendered by an `AVAudioSourceNode`: seamless looping and
/// sample-accurate fades (no zipper noise, no clicks when starting, stopping or switching sounds).
///
/// The main actor posts commands through a mutex that the render thread only *tries* to take (it never blocks;
/// if busy it keeps the previous command for one more buffer). Playback state below "render thread" is touched
/// by the render thread alone. Loop samples are read in place from buffers `SoundPlayer` keeps alive forever.
final class PanicVoice: @unchecked Sendable {
    struct LoopRef: @unchecked Sendable, Equatable {
        let samples: UnsafePointer<Float>
        let count: Int
    }

    private struct Command: Sendable {
        var loop: LoopRef?
        var generation: UInt64 = 0      // bump → fade the current loop down (4 ms), then restart `loop` from 0
        var target: Float = 0
        var step: Float = 1              // gain change per sample towards `target`
        var deadlineGeneration: UInt64 = 0
        var deadlineFrames = -1          // ≥ 0: after this many frames, fade to 0 with `deadlineStep`
        var deadlineStep: Float = 1
    }

    private let command = Mutex(Command())
    private let silent = Atomic<Bool>(true)
    private let sampleRate: Double

    // render thread
    private var cmd = Command()
    private var active: LoopRef?
    private var seenGeneration: UInt64 = 0
    private var seenDeadline: UInt64 = 0
    private var deadlineAt = -1
    private var frame = 0
    private var position = 0
    private var gain: Float = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// True once the voice has faded to silence (or was never started).
    var isSilent: Bool { silent.load(ordering: .acquiring) }

    /// Fade to `gain`. A non-nil `loop` (re)starts that loop from its first sample; nil keeps the current one.
    func play(loop: LoopRef?, gain target: Float, fade: Double, stopAfter frames: Int? = nil, stopFade: Double = 0.25) {
        let step = Float(Double(max(target, 0.01)) / max(fade * sampleRate, 1))
        let stopStep = Float(Double(max(target, 0.01)) / max(stopFade * sampleRate, 1))
        command.withLock { c in
            if let loop {
                c.loop = loop
                c.generation &+= 1
            }
            c.target = target
            c.step = step
            c.deadlineGeneration &+= 1
            c.deadlineFrames = frames ?? -1
            c.deadlineStep = stopStep
        }
        silent.store(false, ordering: .releasing)
    }

    func setGain(_ target: Float, ramp: Double) {
        command.withLock { c in
            c.step = Float(Double(max(abs(target - c.target), 0.01)) / max(ramp * sampleRate, 1))
            c.target = target
            c.deadlineStep = max(c.deadlineStep, Float(Double(max(target, 0.01)) / (0.25 * sampleRate)))
        }
    }

    func stop(fade: Double, from level: Float) {
        let step = Float(Double(max(level, 0.01)) / max(fade * sampleRate, 1))
        command.withLock { c in
            c.target = 0
            c.step = step
            c.deadlineGeneration &+= 1
            c.deadlineFrames = -1
        }
    }

    /// Nonisolated on purpose: the render block must not inherit main-actor isolation.
    func makeNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] isSilence, _, frameCount, bufferList in
            render(Int(frameCount), bufferList, isSilence)
            return noErr
        }
    }

    private func render(_ n: Int, _ bufferList: UnsafeMutablePointer<AudioBufferList>,
                        _ isSilence: UnsafeMutablePointer<ObjCBool>) {
        if let c = command.withLockIfAvailable({ $0 }) { cmd = c }
        if cmd.deadlineGeneration != seenDeadline {
            seenDeadline = cmd.deadlineGeneration
            deadlineAt = cmd.deadlineFrames >= 0 ? frame + cmd.deadlineFrames : -1
        }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = buffers.first, let raw = first.mData else { return }
        let out = raw.assumingMemoryBound(to: Float.self)
        let count = min(n, Int(first.mDataByteSize) / MemoryLayout<Float>.size)
        let switchStep = Float(1 / (0.004 * sampleRate))
        var g = gain, pos = position, f = frame, loop = active
        var target: Float = 0
        for i in 0..<count {
            var step = cmd.step
            target = cmd.target
            if seenGeneration != cmd.generation {
                if g > 0 {
                    target = 0
                    step = switchStep
                } else {
                    seenGeneration = cmd.generation
                    loop = cmd.loop
                    pos = 0
                }
            }
            if deadlineAt >= 0, f >= deadlineAt {
                target = 0
                step = cmd.deadlineStep
            }
            if g < target { g = min(target, g + step) } else if g > target { g = max(target, g - step) }
            if g > 0, let l = loop {
                out[i] = l.samples[pos] * g
                pos += 1
                if pos >= l.count { pos = 0 }
            } else {
                out[i] = 0
            }
            f += 1
        }
        for b in buffers.dropFirst() {
            if let d = b.mData { memcpy(d, raw, min(Int(b.mDataByteSize), count * MemoryLayout<Float>.size)) }
        }
        gain = g
        position = pos
        frame = f
        active = loop
        let quiet = g == 0 && target == 0 && seenGeneration == cmd.generation
        isSilence.pointee = ObjCBool(quiet)
        silent.store(quiet, ordering: .releasing)
    }
}
