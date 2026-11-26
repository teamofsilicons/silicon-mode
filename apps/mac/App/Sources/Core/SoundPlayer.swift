import Foundation
import AVFoundation

/// UI sounds and the looping panic alarm. Sounds are WAVs in Resources/Sounds
/// (rendered by `scripts/make-sounds.py`).
enum UISound: String, CaseIterable {
    case countdownStart = "countdown-start"
    case tick
    case enter
    case dismiss
    case unlock
    case wrongPin = "wrong-pin"
    case question
    case keypress
}

@MainActor
final class SoundPlayer {
    struct PanicSound: Identifiable, Hashable { let id: String; let name: String }

    /// Selectable panic sounds (ids map to Resources/Sounds/panic-<id>.wav).
    static let panicSounds: [PanicSound] = [
        PanicSound(id: "klaxon", name: "Klaxon"),
    ]

    func play(_ sound: UISound) {}
    func preview(panicSoundID: String, volume: Double) {}
    func startPanic(soundID: String, volume: Double) {}
    func stopPanic() {}
}
