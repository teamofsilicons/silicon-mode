# Silicon Mode: macOS UI research

Scope: menu bar UX (Hoy), sound design (bencho, plus our six recipes), Liquid Glass, embedded Touch ID, the kiosk overlay, sleep and lid close, the global hotkey, progressive blur, the NameDrop-style entry animation, and lid-angle polling.

Environment: macOS 27.0 (build 26A428), Xcode 27.0 (27A266a), Swift 6.4, MacOSX27.0 SDK, MacBookPro18,1.
`SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`

Throughout this report, "VERIFIED" means one of the following:
- the symbol was grepped in the SDK, or
- the snippet typechecked with `swiftc -typecheck -swift-version 6 -target arm64-apple-macos26.0`, or
- a probe binary ran on this Mac.

Probe sources are in the scratchpad (`.../scratchpad/probe`, `.../scratchpad/snips`, `.../scratchpad/shader`, `.../scratchpad/sfx`). Nothing on the system was changed. I did not call the private clamshell setter in §5.4.

---

## 0. Decisions at a glance

| Area | Decision |
|---|---|
| Menu bar | Use `NSStatusItem` with a custom borderless `NSPanel` whose SwiftUI root uses `.glassEffect`. Do not use `MenuBarExtra(.window)`, which can't be opened programmatically, sized or animated, and can't host Hoy-style faces. The card is 344 pt wide, hangs 8 pt under the icon, and has 24–42 pt radii. |
| Glass | Use the SwiftUI `glassEffect` family, which exists in the macOS 26 SDK and is unchanged in 27. In AppKit, use `NSGlassEffectView`; its `effectIsInteractive` is **new in macOS 27**. Glass in a transparent borderless window **does sample the desktop behind it** (verified: `CABackdropLayer windowServerAware=1`). |
| Touch ID | Use `LAAuthenticationView(context:controlSize:)` plus `evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`. A probe confirmed it works in a **borderless non-activating NSPanel at `.screenSaver` and shielding level, even when the panel isn't key**, and no `coreautha` system sheet appears. Fall back to the PIN on any error. |
| Overlay | Put one `NSPanel` on each `NSScreen`: `[.borderless, .nonactivatingPanel]`, level `.screenSaver` (1000), `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`. The app must be **active** for `presentationOptions` to apply. Cooperative `NSApp.activate()` was **ignored** in the probe; `NSApp.activate(ignoringOtherApps: true)` (deprecated) worked from an accessory app. |
| Sleep | Use `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep)` and, optionally, `kIOPMAssertPreventUserIdleDisplaySleep`. Neither prevents lid-close sleep. There is no *public* non-root way to stay awake with the lid closed. A private, unprivileged selector exists (§5.4) but is risky. |
| Hotkey | Use Carbon `RegisterEventHotKey(kVK_ANSI_S, controlKey\|optionKey)`. It returned `noErr` at runtime and needs no Accessibility permission. |
| Progressive blur | Use the private `CAFilter("variableBlur")` on the `CABackdropLayer` inside an `NSVisualEffectView(.behindWindow)`. A screenshot on macOS 27 **verified** a true progressive blur of the desktop. The public fallback is an alpha-masked `NSVisualEffectView`. |
| Entry animation | Use `TimelineView(.animation)` with `.layerEffect(ShaderLibrary.bumpShockwave(...))`. The shader below compiled with the runtime Metal compiler and rendered correctly offscreen. **Note:** the Xcode **Metal Toolchain is not installed** (`xcodebuild -showComponent MetalToolchain` reports `uninstalled`), so `.metal` files will not build until someone runs `xcodebuild -downloadComponent MetalToolchain`. |
| Sounds | Render procedurally with bencho's voice model (oscillator or filtered noise, exponential envelope, glide). The reference renderer is in Appendix A. It produced all ten WAVs in 0.5 s. |
| Lid angle | Match `VID 0x05AC / PID 0x8104 / PrimaryUsagePage 0x20 / PrimaryUsage 0x8A` (product `"las"`, transport `SPU`). Read with `IOHIDDeviceGetReport(feature, id 1)` and decode `byte1 \| byte2<<8` as whole degrees. Each read takes about 0.5 ms. **No TCC prompt or entitlement is needed** for a non-sandboxed app (verified). |

---

## 1. gethoy.app: menu bar UX teardown

Sources: <https://gethoy.app/>, plus its `assets/hoy.css` and `assets/hoy.js`. The site recreates the app at its own point sizes, and its CSS comments say the values "come from the app's source … not from taste".

### What it is
Hoy is a small-team messenger that puts **your people in the menu bar as faces**. It is built on CloudKit, has no server, and targets macOS, iOS and iPadOS 26+.

### Layout

**The strip (in the menu bar)**
- Faces are 25 pt circles that overlap by 8 pt. The leftmost face sits in front.
- Each face has a 2 pt outline in the background colour, which reads as a knock-out gap over the face behind it.
- The Mac's own menu bar items sit on either side.
- When a face opens, the others part around it on a spring (response 0.46, damping 0.66), and the whole row re-centres.

**The peek**
- When a drop arrives, a small glass pill appears under the face: 26 pt tall, 12 pt horizontal inset, 7 pt below the face. It holds one line, for example a note.
- The pill is clickable. Clicking a code copies it, and a copy glyph morphs into a checkmark for 1.6 s using the SF Symbol replace transition.
- On hover, a 5% ink tint fades in over 120 ms and the pill scales to 1.05 (spring 0.35 / 0.75).

**The card**
- One glass surface, 344 pt wide, hanging 8 pt under the strip.
- Corner radius 42 pt, inner padding 12 pt, an 8 pt gap between the header, thread and composer.
- It opens from the face as `opacity 0→1, scale 0.97→1` over 200 ms easeOut, with the transform origin above the card's top centre (so it reads as growing out of the face).
- Growing into a channel uses spring(0.4, 1.0) ("cardLaunch"). The header appears at once; the thread and composer arrive a beat later.

**The thread**
- Your drops are on the right and theirs on the left.
- A time line appears only on the day's first drop or after an hour's pause.
- The thread is clipped, not scrollable, so the newest drop sits on the bottom edge.
- Reactions and reminders reserve their space ahead of time, so "nothing in the thread moves as they come".

**The composer**
- A glass tile with radius 30 and padding 20.
- A 13.5 pt note field with a 1.5 pt caret.
- Chips are 28 pt circles.
- The "Drop ⏎" pill is 28 pt tall with radius 14. It is grey until there is something to send, then turns accent blue (`#08f` light, `#0091ff` dark).
- The video menu opens upward from its button. It is 204 pt wide with radius 20, 34 pt rows with radius 14, and springs in on a curve of `cubic-bezier(.2,.9,.3,1.06)` over 0.4 s.

### Presence and state

| State | Treatment |
|---|---|
| Active now | A "sonar" ring grows from the face edge to 1.22× in 2.5 s. Opacity peaks at 0.64 at 20% of the cycle. It loops, and the ring is ½ pt thick. |
| Unread | A 6 pt dot with **no number**, together with a wiggle of that face. |
| Open, or a file dragged over the face | A 2 pt ring grows out from under the face on spring(0.42, 0.66). |
| Numbers | Each digit rolls through a blur, upward when counting up and downward when counting down (spring 0.3 / 0.85). |
| Reaction chips | They come in from scale 0.6 on spring(0.3, 0.7). |
| Live transcript | Words sharpen in from a blur, 55 ms apart. |

### Material
- An HUD-material glass.
- A rim gradient at 163°: white 95% → 55% → 28% → 60%.
- Soft lift: `0 2 6 / 4%` plus `0 14 36 -8 / 14%`.
- An inner sheen: inset 26 pt white at 30%.
- In the Pro "ambient theme", the glass glows with a mesh of the channel face's four corner colours.

### Why it feels good
- Every motion is a real SwiftUI spring rather than a tween.
- Nothing shifts layout: space is reserved ahead of time.
- Signals are tiny and calm: a dot, a ring, a peek.
- Direct manipulation everywhere: hold a face to talk, drop a file onto a face.
- One glass surface, not nested cards.
- It honours reduced motion.

### What to steal for Silicon Mode
- **Agents as faces in the status item**: provider marks or mascots, overlapping, with a sonar ring while working and a dot plus wiggle when they need you.
- **A peek pill** under the icon for the newest agent question, clickable to answer.
- **A 344 pt glass card**: agent list on top, the selected agent's thread (last 5–10 events) in the middle, and an answer composer (Hoy's composer) at the bottom.
- **Hold-to-talk** to answer an agent by voice, with words sharpening in from a blur.
- **Rolling digits** for counts like "3 need you / 2 working".
- Reuse the spring table directly:

```swift
// Hoy's springs as SwiftUI (response, dampingFraction)
extension Animation {
  static let cardLaunch = Animation.spring(response: 0.40, dampingFraction: 1.00)
  static let part       = Animation.spring(response: 0.46, dampingFraction: 0.66)
  static let ring       = Animation.spring(response: 0.42, dampingFraction: 0.66)
  static let digit      = Animation.spring(response: 0.30, dampingFraction: 0.85)
  static let chip       = Animation.spring(response: 0.30, dampingFraction: 0.70)
  static let hoverLift  = Animation.spring(response: 0.35, dampingFraction: 0.75)
}
```

---

## 2. Sound

### 2.1 bencho.dev/sounds: the approach

bencho describes itself as "182 sounds for UI interactions … **synthesised in the browser**". There are no audio files. Everything is Web Audio, rendered live or through an `OfflineAudioContext` into a 44.1 kHz, 16-bit mono WAV for download. The engine is `/assets/sound-6qabUvCG.js`.

**The voice model**

Each sound is an array of *partials*:

```
{ hz, to?, glide?(ms), ms, at?(ms), gain, atk?(ms), lin?, wave?: sine|triangle|square, cut?(Hz), noise?: lowpass|bandpass, q? }
```

- **Oscillator partial**: `OscillatorNode(wave)`, an optional exponential frequency ramp `hz→to` over `glide` (or the whole duration), then an optional lowpass at `cut`.
- **Noise partial**: a 2 s looping white-noise buffer through a `BiquadFilter(noise)` at `hz` (also gliding), with `Q=q`. For a lowpass, `q` is in dB, so `-3` means no resonance.
- **Envelope**: `1e-4 →` (exponential, or linear if `lin`) `gain` over `min(atk, 0.6·ms)`, then exponential decay to `1e-4` at `ms`.
- **Gains** are small (0.005–0.07) because many partials are summed.

**Design patterns** (decoded from the presets)

| Pattern | How it's built | Examples |
|---|---|---|
| Struck bar / bell | Partials at ratio **1 : 2.756 : 5.404** (free-free bar modes), relative gain about 1 : 0.3 : 0.1, decays about 1 : 0.48 : 0.3, plus a 5 ms lowpass-noise "contact" click. | `attention`: 880 / 2428.8 / 4752 Hz; `mechSuccess`, `warning` |
| Mallet pitch drop | Every partial starts **+9% sharp** and glides to pitch in 15 ms, with a soft linear attack of about 110 ms. | `pressSuccess` |
| Clicks | 3–8 ms band-passed noise bursts (Q 1–8) layered with a 15–40 ms sine blip that glides down. | `mechTap`, `glint`, `tink` |
| Errors | A **downward glide** (`bubbleError` 349→262 Hz in 140 ms), a low tritone or minor stack (`pressError` 120 / 240 / 570 Hz), or a tiny triangle `buzz` (344→239 Hz, 24 ms). | |
| Swells | Band-pass noise sweeps (`count`: 700→1400 Hz with Q 1.2, plus 2000→3200 Hz, over 600 ms, linear 150 ms attack). | |

Each sound page states its intent in one line, for example Glint: "A bright, glassy tick that lasts about 30 milliseconds … around 2.3kHz, so it reads as crisp without being sharp".

### 2.2 Our six sounds

The renderer is in Appendix A. It uses the same voice model at 48 kHz, 16-bit mono, and peak-normalises each file.

- Partials are written as `type f0→f1 (glide) @start dur gain atk`.
- "Bar(f)" means three sines at f×{1, 2.756, 5.404} with gains ×{1, .30, .10} and durations ×{1, .5, .27}.
- Measured results: panic peak −1 dBFS / RMS −12; the others peak −3 to −6 dBFS.

**A. Panic alarm, "mistake" (`panic_loop.wav`, 1200 ms, seamless loop)**

The sound is a two-note "uh-oh" figure at 0 ms, repeated at 600 ms. The second note is a tritone below the first and sags by a semitone, which is the classic "wrong" interval. A 28 Hz amplitude modulation adds roughness, which reads as urgent without being shrill.

| t (ms) | Partial |
|---|---|
| 0–130 | square 900→880 Hz (15 ms glide), gain .50, atk 3 ms, flat hold 55% of the duration then exponential decay, lowpass 3.5 kHz, AM 28 Hz depth 0.3 |
| 0–130 | saw at the same pitch ×1.0035 (chorus detune), gain .30, lowpass 3.5 kHz |
| 0–130 | sine at half pitch (450→440), gain .25 |
| 150–430 | the same three-layer stack at **622.25→587.33 Hz** (D#5→D5, glide over the full 280 ms), gain .55 |
| 0 and 150 | noise, bandpass 2.2 kHz, Q 1.2, 8 ms, gain .5 (attack transient) |
| 600–1030 | the whole figure repeated |
| 1030–1200 | silence |

- The loop boundary falls in silence, so it is click-free.
- Play it with `AVAudioPlayer.numberOfLoops = -1`.
- Visual sync: flash at 0 and 600 ms, two flashes per 1.2 s (1.7 Hz). Stay at or below 3 flashes per second (WCAG 2.3.1) and avoid saturated full-screen red.

**B. Countdown tick (`tick_5…tick_1.wav`, 58 ms each)**

Step `s` = 0 for "5" through 4 for "1". The multiplier `m = 2^(s/12)` raises each tick by a semitone, which builds tension.

| Partial |
|---|
| noise, bandpass 3200·m Hz, Q 1.5, 6 ms, gain .6, atk 0.5 ms (the click) |
| sine 1760·m → 1320·m Hz (12 ms glide), 38 ms, gain .35, atk 1 ms (the glassy body) |
| triangle 420·m → 380·m Hz, 32 ms, lowpass 1.8 kHz, gain .25 (the woody knock) |

Normalise to −6 dBFS, so the ticks stay quieter than the events. At 0, play the enter sound instead of a sixth tick.

**C. Enter Silicon Mode: whoosh, impact, chime (`enter_silicon.wav`, 1750 ms)**

The impact at 320 ms lines up with the shader's `tBang = 0.32` s (§8).

| t (ms) | Partial |
|---|---|
| 0–380 | noise, **bandpass sweep 400→3200 Hz** (exponential), Q 1.0, **linear attack 300 ms** to gain .5, then fast decay (the suction whoosh) |
| 0–360 | sine 180→520 Hz, linear attack 300 ms, gain .12 (a rising undertone) |
| 320–480 | sine 110→55 Hz (90 ms glide), gain .6, atk 2 ms (the sub "bump") |
| 320–365 | noise, lowpass 1.2 kHz, 45 ms, gain .35 (impact body) |
| 330–1730 | Bar(**659.25 Hz** E5), 1400 ms, gain .45; every partial starts +9% sharp and settles in 25 ms |
| 400–1600 | Bar(**987.77 Hz** B5, a fifth above), 1200 ms, gain .32, same +9% drop |
| 380–700 | glitter: sines at 7050, 9290, 7950, 9380, 6740 and 10050 Hz, starting at 380, 410, 470, 520, 560 and 640 ms, lasting 60, 40, 50, 70, 90 and 60 ms, gain .05, atk 2 ms |

Normalise to −3 dBFS.

**D. Unlock success (`unlock_success.wav`, 790 ms)**

The physical "latch" is followed by a rising open-fifth arpeggio.

| t (ms) | Partial |
|---|---|
| 0–5 | noise, bandpass 2.4 kHz, Q 3, gain .4 (the latch click) |
| 0–120 | triangle 330→620 Hz, atk 30 ms, lowpass 1.4 kHz, gain .12 (lift) |
| 0 / 75 / 150 | Bar 783.99 (160 ms, gain .40) / Bar 1174.66 (200 ms, .40) / Bar **1567.98** (620 ms, .45), atk 3 ms |
| 155–455 | sine 3135.96 Hz (octave sparkle), gain .06, atk 8 ms |

Normalise to −3 dBFS.

**E. Wrong-PIN buzz (`wrong_pin.wav`, 220 ms)**

Two low, rough pulses. A 9 Hz beat between 155 and 164 Hz makes them read as "nope".

| t (ms) | Partial |
|---|---|
| 0–90, 110–200 | square 155→140 Hz, lowpass 900 Hz, atk 3 ms, gain .50 then .42 |
| 0–90, 110–200 | square 164→148 Hz, lowpass 900 Hz, gain .40 then .34 |
| 0–70, 110–180 | sine 80→60 Hz, gain .5, atk 2 ms (thump) |

- Pair it with the dots shaking: `x(t) = 12·e^(−t/0.12)·sin(2π·8t)` pt over 400 ms.
- Also call `NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)`. The haptic is only felt if a finger is on the trackpad.

**F. Question arrived (`question_ping.wav`, 760 ms)**

A friendly two-note glass ping that ends with an upward "?" inflection.

| t (ms) | Partial |
|---|---|
| 0–5 | noise, lowpass 3 kHz, gain .25 |
| 0–180 | Bar 880 Hz (A5), gain .35 |
| 90–740 | Bar **1318.51 Hz** (E6), gain .50, every partial gliding up from 1290 Hz in 25 ms |

Normalise to −4 dBFS.

### 2.3 Playback notes

- **One-shots.** Preload every file into an `AVAudioEngine` with `AVAudioPlayerNode` and `AVAudioPCMBuffer`s; this is the lowest-latency option and lets sounds overlap. `NSSound` is fine for menu bar sounds.
- **Panic.** Use a dedicated `AVAudioPlayer` that has had `prepareToPlay()` called when Silicon Mode is entered, so the first sample plays within milliseconds of the angle trigger.
- **Panic must reach the room.** If headphones or AirPods are the default output, nobody near the laptop hears the alarm. Offer a setting "Panic on built-in speakers": find the device whose `kAudioDevicePropertyTransportType == kAudioDeviceTransportTypeBuiltIn` and set it on the engine's output unit.
- **Muted Macs.** Optionally lift mute and volume during panic with `kAudioDevicePropertyMute` and `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, which are public CoreAudio API and need no permission. Restore both afterwards. All symbols were grepped in the SDK.

---

## 3. Liquid Glass (SwiftUI + AppKit)

### 3.1 Symbols confirmed in the SDK

| Symbol | Where | Availability |
|---|---|---|
| `View.glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape())` | SwiftUICore.swiftinterface L3064 | macOS 26.0 |
| `struct Glass`: `.regular`, `.clear`, `.identity`, `.tint(Color?)`, `.interactive(Bool = true)` | L7245–7256 | 26.0 |
| `GlassEffectContainer(spacing: CGFloat? = nil, content:)` | L11523 | 26.0 |
| `View.glassEffectID(_:in: Namespace.ID)` | L22411 | 26.0 |
| `View.glassEffectUnion(id:namespace:)` | L12644 | 26.0 |
| `View.glassEffectTransition(_:)` with `.matchedGeometry`, `.materialize`, `.identity` | L3498–3512 | 26.0 |
| `ButtonStyle.glass`, `.glass(_ glass: Glass)`, `.glassProminent` | SwiftUI.swiftinterface L1472–1476, L4458 | 26.0 (`GlassButtonStyle.init(_ glass:)` is **26.1**) |
| `scrollEdgeEffectStyle(_:for:)`, `backgroundExtensionEffect()` | L15926, L15832 | 26.0 |
| `MenuBarExtra(isInserted:content:label:)`, `.menuBarExtraStyle(.window)` | L2092, L5975, L21780 | 13.0 |
| `NSGlassEffectView` (`contentView`, `cornerRadius`, `tintColor`, `style: .regular/.clear`) | AppKit `NSGlassEffectView.h` | 26.0 |
| `NSGlassEffectView.effectIsInteractive` | same header | **27.0** (new) |
| `NSGlassEffectContainerView` (`contentView`, `spacing`) | same header | 26.0 |

I grepped every `macOS 27` annotation in the SwiftUI and SwiftUICore interfaces. There are **no new glass APIs in 27** beyond the AppKit `effectIsInteractive`.

### 3.2 Snippets (verified, Swift 6 typecheck)

```swift
struct AgentStrip: View {
  @Namespace private var ns
  @State private var expanded = false
  var body: some View {
    GlassEffectContainer(spacing: 12) {                 // shapes within 12pt blend/morph
      HStack(spacing: 8) {
        Image(systemName: "sparkles")
          .frame(width: 36, height: 36)
          .glassEffect(.regular.interactive(), in: .circle)      // apply glassEffect AFTER appearance modifiers
          .glassEffectID("orb", in: ns)
        if expanded {
          Text("3 agents need you")
            .padding(.horizontal, 14).frame(height: 36)
            .glassEffect(.regular.tint(.orange.opacity(0.35)).interactive(), in: .capsule)
            .glassEffectID("label", in: ns)
            .glassEffectTransition(.matchedGeometry)   // morphs out of the orb
        }
      }
    }
    .onTapGesture { withAnimation(.spring(response: 0.46, dampingFraction: 0.66)) { expanded.toggle() } }
  }
}

// Fused segmented control + buttons
GlassEffectContainer(spacing: 8) {
  HStack(spacing: 4) {
    ForEach(["Agents", "Logs", "Ask"], id: \.self) { Button($0) {}.buttonStyle(.glass).glassEffectUnion(id: "seg", namespace: ns) }
    Button("Unlock") {}.buttonStyle(.glassProminent)
    Button("Later") {}.buttonStyle(.glass(.clear))     // .glass(_:) builds on 26.0; GlassButtonStyle.init(_:) is 26.1
  }
}
```

```swift
// AppKit
let glass = NSGlassEffectView()
glass.style = .regular                 // or .clear (more transparent, needs a dimming layer for legibility)
glass.cornerRadius = 24
glass.tintColor = NSColor.systemOrange.withAlphaComponent(0.18)
if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
glass.contentView = NSHostingView(rootView: content)     // only contentView is guaranteed to sit inside the glass
let container = NSGlassEffectContainerView(); container.spacing = 12; container.contentView = glass
```

Apple's guidance: use **one container per cluster**, keep the number of on-screen glass effects low, and remember that `glassEffectID` and `glassEffectTransition` only act during hierarchy changes. See [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).

### 3.3 Glass over the desktop (verified)

A probe walked the layer tree of an `NSGlassEffectView` placed in a **transparent borderless `NSWindow`**. It found:

```
CABackdropLayer filters=[glassBackground] windowServerAware=1 groupName=SwiftUI:…
```

So glass in our panels and overlay **refracts the real desktop** behind them. For comparison, `NSVisualEffectView(.behindWindow)` is `CABackdropLayer [sdrNormalize, gaussianBlur, colorSaturate] windowServerAware=1`.

### 3.4 MenuBarExtra(.window) vs a custom panel

`WindowMenuBarExtraStyle` is "a popover-like window" with no customisation API: no way to open or close it programmatically, no control over size, arrow or animation, and no custom status-item view. `isInserted` only toggles the status item.

On macOS 26.0 there was also a bug where `.onHover` didn't fire on `List` rows inside it. It was [reported fixed in 26.1](https://developer.apple.com/forums/thread/802313).

Because we need the hotkey to open it, Hoy-style faces in the bar, and Hoy's grow-from-icon animation, use the custom panel:

```swift
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.addSubview(NSHostingView(rootView: FacesStrip()))   // or item.button.image for v1
final class MenuPanel: NSPanel {                                  // shown under item.button.window.frame
  override var canBecomeKey: Bool { true }                         // composer text field needs key
  init() { super.init(contentRect: .init(x: 0, y: 0, width: 344, height: 420),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
           isOpaque = false; backgroundColor = .clear; hasShadow = true; level = .popUpMenu
           collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient] }
}
// root: content.glassEffect(.regular, in: .rect(cornerRadius: 28)); open with scale .97→1 + opacity, anchor .top
// dismiss: NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) — mouse monitors need no AX permission
```

---

## 4. Embedded Touch ID: LocalAuthenticationEmbeddedUI

### 4.1 API in the SDK

`LocalAuthenticationEmbeddedUI.framework/Headers/LAAuthenticationView.h` is available on macOS 12+ (macOS only):
- `initWithContext:(LAContext*)` and `initWithContext:controlSize:(NSControlSize)`
- "When `evaluatePolicy` or `evaluateAccessControl` is called on this context, the UI will be presented using this view rather than using the standard authentication alert."
- Supported policies: `…WithBiometrics`, `…WithCompanion`, `…WithBiometricsOrCompanion`, and `…DeviceOwnerAuthentication`. The last one is only a convenience and **fails if biometrics/watch are unavailable**; it does **not** fall back to a password.
- "This view is non-textual … The reason for the authentication must be apparent from the surrounding UI."

There is also a SwiftUI form, `LocalAuthenticationView` (macOS 13+), in the cross-import overlay `_LocalAuthentication_SwiftUI`, which you get by importing SwiftUI and LocalAuthentication together:
- `LocalAuthenticationView("Touch ID to exit", reason: Text(…)) { result in … }` creates its own context and evaluates `deviceOwnerAuthenticationWithBiometricsOrCompanion`.
- `LocalAuthenticationView("…", context: ctx)` is the form to use with your own `evaluatePolicy` call.

Relevant errors in `LAError.h`:

| Code | Meaning |
|---|---|
| `-14` `LAErrorInvalidDimensions` | The embedded view's size is invalid. Give it a real frame, at least 32×32. |
| `-1004` `notInteractive` | |
| `-8` `biometryLockout` | |
| `-1` `authenticationFailed` | |
| `-9` `appCancel` | |
| `-4` `systemCancel` | |

### 4.2 Probe results on this Mac

Setup: a borderless `.nonactivatingPanel` `NSPanel`, an accessory activation policy, and an `LAAuthenticationView(context:controlSize:.large)` at 60×60. The probe called `evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` and then `invalidate()` after 2.5 s.

| Case | Result |
|---|---|
| level `.screenSaver`, app active, panel key | waited for a finger; ended with `-9` "Invalidated by client"; **no `coreautha` window on screen** |
| level `.screenSaver`, panel **not key** | same (waited, no system sheet) |
| level `CGShieldingWindowLevel()` (2147483628), key | same |
| Control: no embedded view | a `coreautha` system prompt window appeared |

Conclusion: the embedded view replaces the system sheet in a borderless screen-saver-level window, and it does not require key status. I could not test the success path because there was no finger.

### 4.3 Recommended flow (verified typecheck)

```swift
struct TouchIDWell: NSViewRepresentable {
  let context: LAContext
  func makeNSView(context ctx: Context) -> LAAuthenticationView { LAAuthenticationView(context: context, controlSize: .large) }
  func updateNSView(_ v: LAAuthenticationView, context: Context) {}
}
struct UnlockView: View {
  @State private var la = LAContext()
  var onUnlock: () -> Void
  var body: some View {
    TouchIDWell(context: la).id(ObjectIdentifier(la))   // view is bound to ONE context: new context ⇒ new view
      .frame(width: 64, height: 64)
      .task(id: ObjectIdentifier(la)) {
        do { try await la.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Exit Silicon Mode"); onUnlock() }
        catch let e as LAError where e.code == .authenticationFailed { la = LAContext() }   // re-arm
        catch { /* lockout / not enrolled / -1007 → hide the well, PIN only */ }
      }
  }
}
```

- **Start evaluation only while the view is on screen.** Re-arm on `didChangeScreenParameters` and after a wake.
- **Lockout.** After 5 bad fingers the error is `biometryLockout`; Touch ID then needs the account password, which we don't want, so switch to the PIN.
- **Enrollment changes.** Persist `la.domainState.biometry.stateHash` (macOS 15+; it replaces the deprecated `evaluatedPolicyDomainState`) at setup, and disable Touch ID unlock if the hash changes, because someone may have added a finger.
- **Fallback.** Keep the PIN path always visible. A PIN-free "fingerprint only" mode should require `canEvaluatePolicy` to be true.
- **Known regression to guard.** On macOS 27 betas, attaching a context to `LocalAuthenticationView` made `evaluatePolicy` fail with `-1007` "Caller is not Apple signed" (FB23262713). It was [reported fixed in beta 3](https://developer.apple.com/forums/thread/835885), and the probe above saw no `-1007`. Still, treat `-1007` as "embedded Touch ID unavailable: PIN only".

---

## 5. Kiosk overlay, focus, sleep and lid close

### 5.1 Window

```swift
final class ShieldPanel: NSPanel {
  override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true }
  init(screen: NSScreen) {
    super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
    level = .screenSaver               // 1000. Shielding = 2147483628 (CGShieldingWindowLevel()); AssistiveTechHigh = 1500
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false; backgroundColor = .clear; hasShadow = false; isMovable = false
    hidesOnDeactivate = false; isReleasedWhenClosed = false; animationBehavior = .none
    setFrame(screen.frame, display: true)
  }
}
```

- Use **one panel per `NSScreen`**, and rebuild them on `NSApplication.didChangeScreenParametersNotification`.
- `.canJoinAllSpaces` plus `.fullScreenAuxiliary` lets the panel float over other apps' full-screen Spaces.
- `.stationary` keeps it fixed during Mission Control. `.ignoresCycle` keeps it out of Cmd-`.
- **Level.** `.screenSaver` covers the menu bar, Dock and full-screen apps but stays under assistive tech such as Zoom and VoiceOver. Avoid the shielding level in normal use, because system alerts (for example low battery, or a TCC prompt) would be hidden beneath it and the user could be stuck.
- **`CGCaptureAllDisplays`.** It exists, but it changes display modes and blocks other apps from adapting. Don't use it.

### 5.2 presentationOptions: rules and behaviour

Apple's rules ([docs](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct)):
- `autoHideDock` and `hideDock` are mutually exclusive; so are `autoHideMenuBar` and `hideMenuBar`.
- `hideMenuBar` requires `hideDock`.
- `autoHideMenuBar` requires `hideDock` or `autoHideDock`.
- `disableProcessSwitching`, `disableForceQuit`, `disableSessionTermination` and `disableMenuBarTransparency` each require `hideDock` or `autoHideDock`.
- `autoHideToolbar` requires both `fullScreen` and `autoHideMenuBar`.
- An invalid combination **raises `NSInvalidArgumentException`**.

New in macOS 27 (`NSApplication.h`): `NSApplicationPresentationDisableScreenCornerInteractions = 1<<15`, "Disable screen corner interactions when the application is frontmost". It requires `.autoHideDock` or `.hideDock`. Use it to kill Hot Corners while locked.

Probe from an accessory (`LSUIElement`-like) app:

```
set while inactive          -> system options = 0         (stored, not applied)
NSApp.activate()            -> isActive=false, system = 0 (cooperative activation refused: another app frontmost)
NSApp.activate(ignoringOtherApps: true) -> isActive=true, system = 506 (all requested flags live)
```

So the options **apply only while our app is active**, and the deprecated `activate(ignoringOtherApps:)` is currently the reliable way to take activation from a background trigger (lid angle or hotkey). Lock recipe:

```swift
NSApp.activate(ignoringOtherApps: true)
var o: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar, .disableAppleMenu, .disableProcessSwitching,
                                            .disableForceQuit, .disableSessionTermination, .disableHideApplication]
if #available(macOS 27.0, *) { o.insert(.disableScreenCornerInteractions) }
NSApp.presentationOptions = o
mainScreenPanel.makeKeyAndOrderFront(nil)
```

**Keeping key focus for the PIN**
- Re-assert focus on `NSApplication.didResignActiveNotification` and `NSWorkspace.didActivateApplicationNotification` by activating again and calling `makeKey`.
- Capture digits with `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`, or SwiftUI `.focusable()` with `.onKeyPress`.
- **Ordering.** Apply the lock options only after the one-minute grace window, since the spec says Silicon Mode is dismissible before then.
- **What the lock can't stop.** Ctrl-Cmd-Q (lock screen), Touch ID power-off, and Fast User Switching still work. That is fine: agents keep running.

### 5.3 Preventing sleep (IOPMLib.h, verified)

```swift
var id = IOPMAssertionID(0)
IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                            "Silicon Mode: agents running" as CFString, &id)   // "caffeinate" toggle
IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, …, "Silicon Mode face on screen" as CFString, &id2)
// release: IOPMAssertionRelease(id)
```

- `PreventUserIdleSystemSleep`. Per the header: "The system may still sleep for **lid close**, Apple menu, low battery …".
- `PreventUserIdleDisplaySleep` keeps the face on screen and also implies no idle system sleep.
- `NoIdleSleepAssertion` and `NoDisplaySleepAssertion` are **deprecated since 10.7**. `PreventSystemSleep` is "not supported in any OS X releases".
- Assertions show up in `pmset -g assertions` under our name.

### 5.4 Lid close (clamshell)

**Reading lid state (public, no root)**
- `IOPMrootDomain` properties `AppleClamshellState` and `AppleClamshellCausesSleep` (`IOPM.h` `kAppleClamshell*Key`).
- When I checked, this Mac read `AppleClamshellCausesSleep = No` from `ioreg` and from the Swift helper below. That happens, for example, in clamshell mode with an external display.
- Register `IOServiceAddInterestNotification` on the root domain for `kIOPMMessageClamshellStateChange` (bits `kClamshellStateBit`, `kClamshellSleepBit`).

**What actually happens when the lid closes**
- When `CausesSleep` is true, closing the lid starts a non-abortable sleep: `kIOMessageSystemWillSleep`.
- An app can only **delay** that sleep, by withholding `IOAllowPowerChange`, and "the sleep will continue anyway after a 30 second timeout". Don't use that.
- So **panic has to fire from the angle trigger** (`angle < 0.9 × siliconAngle`) while the lid is still open enough for the display and speakers to work.
- Suppress replay on wake with `NSWorkspace.willSleepNotification` and `didWakeNotification`.

**Ways to keep running with the lid closed**

1. **Public, no root:** none.
2. **User-run:** `sudo pmset -a disablesleep 1` (and `0` to undo). It is global and persistent. A laptop in a bag will not sleep, which is a thermal risk.
3. **Privileged helper:** an `SMAppService.daemon` (the user approves it in Login Items; admin required) toggles `disablesleep` only while Silicon Mode is active, with a watchdog that restores it.
4. **Private and unprivileged:** `IOConnectCallScalarMethod` on the `IOPMrootDomain` user client, selector **12 `kPMSetClamshellSleepState`**.
   - In current xnu `RootDomainUserClient.cpp` this selector has **no privilege check**, unlike the neighbouring selectors, which check `kIOClientPrivilegeAdministrator`.
   - It sets the global `kClamshellSleepDisablePowerd` bit. That bit **is not reset when the client closes**, so you must always clear it, and powerd may clear it itself on power-source changes. This matches Amphetamine's note that closed-display sessions fail when power is connected or disconnected.
   - **Not exercised here** (it would change system state). Snippet, typechecked:

```swift
func setClamshellSleepDisabled(_ disabled: Bool) -> kern_return_t {   // PRIVATE — gate behind an explicit opt-in
  let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain")); defer { IOObjectRelease(svc) }
  var conn: io_connect_t = 0
  guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return KERN_FAILURE }
  defer { IOServiceClose(conn) }
  var input: UInt64 = disabled ? 1 : 0
  return IOConnectCallScalarMethod(conn, 12 /* kPMSetClamshellSleepState */, &input, 1, nil, nil)
}
func clamshellCausesSleep() -> Bool? {   // public read
  let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain")); defer { IOObjectRelease(svc) }
  return IORegistryEntryCreateCFProperty(svc, kAppleClamshellCausesSleepKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
}
```

---

## 6. Global hotkey ctrl+option+S (verified at runtime: `RegisterEventHotKey` → `0`)

Carbon hot keys need **no Accessibility or Input Monitoring permission**.

macOS 15 blocks hot keys whose *only* modifiers are Option or Option+Shift in **sandboxed** apps, failing with `-9868` ([forum](https://developer.apple.com/forums/thread/763878)). Ctrl+Opt is unaffected; in the non-sandboxed probe even Option-only returned `0`.

```swift
import Carbon.HIToolbox
@MainActor final class HotKey {
  static let shared = HotKey(); var onPress: (() -> Void)?
  private var ref: EventHotKeyRef?; private var handler: EventHandlerRef?
  func register(keyCode: UInt32 = UInt32(kVK_ANSI_S), modifiers: UInt32 = UInt32(controlKey | optionKey)) -> OSStatus {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let s = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var hk = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hk)
      if hk.signature == OSType(0x534C4D44) /* 'SLMD' */ { DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.shared.onPress?() } } }
      return noErr
    }, 1, &spec, nil, &handler)
    guard s == noErr else { return s }
    return RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x534C4D44), id: 1), GetApplicationEventTarget(), 0, &ref)
  }
  func unregister() { if let ref { UnregisterEventHotKey(ref) }; ref = nil }
}
```

The handler fires while our app is in the background. Then call `NSApp.activate(ignoringOtherApps: true)` (§5.2).

---

## 7. Progressive blur from the top edge

| Option | Blurs the desktop behind? | Quality | Cost and risk |
|---|---|---|---|
| SwiftUI stacked `.blur(radius:)` with gradient masks | No (own content only) | OK | Cheap |
| `.scrollEdgeEffectStyle(.soft)` (26+) | No (scroll content only) | System look | Public |
| `NSVisualEffectView(.behindWindow)` + `maskImage` gradient | Yes | Fades blur *opacity*, not radius, so the middle shows a ghosted sharp-plus-blurred mix | Public, cheap |
| Metal `.layerEffect` variable-radius blur (Variablur, Glur) | No (own content), unless you capture the screen, which needs Screen Recording permission | Excellent | Public; screen capture is not acceptable here |
| **Private `CAFilter("variableBlur")` on the `CABackdropLayer` of `NSVisualEffectView(.behindWindow)`** | **Yes** | **True progressive radius, smooth** | Private API, so feature-detect |

**Recommendation:** the private variable blur, with the alpha-masked `NSVisualEffectView` as fallback.

Verified on macOS 27:
- `CAFilter` exists and `filterTypes` includes `variableBlur`.
- `CABackdropLayer` exists.
- A 700×400 test window over the desktop produced a heavy blur at the top that eased to sharp at the bottom (checked by screenshot, then deleted).

This is the macOS analogue of [nikstar/VariableBlur](https://github.com/nikstar/VariableBlur) (iOS) and of [MaterialView](https://github.com/OskarGroth/MaterialView)'s use of `CABackdropLayer.windowServerAware`.

```swift
final class ProgressiveBlurView: NSVisualEffectView {
  var maxRadius: CGFloat = 40
  override init(frame: NSRect) { super.init(frame: frame); blendingMode = .behindWindow; state = .active; material = .fullScreenUI; wantsLayer = true }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { [weak self] in self?.apply() } } // backdrop exists only after attach
  static func mask(_ h: Int = 256) -> CGImage {        // alpha 1 at top → 0 at bottom, smoothstep
    var px = [UInt8](repeating: 0, count: h * 4)
    for y in 0..<h { let t = Double(y) / Double(h - 1); px[y * 4 + 3] = UInt8((1 - t * t * (3 - 2 * t)) * 255) }
    return CGContext(data: &px, width: 1, height: h, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
  }
  private func apply() {
    func find(_ l: CALayer?) -> CALayer? { guard let l else { return nil }
      if String(describing: type(of: l)) == "CABackdropLayer" { return l }; return l.sublayers?.lazy.compactMap(find).first }
    guard let backdrop = find(layer),
          let cls = NSClassFromString("CAFilter") as? NSObject.Type,
          let f = cls.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?.takeUnretainedValue() as? NSObject
    else { maskImage = NSImage(cgImage: Self.mask(), size: bounds.size); return }   // public fallback
    f.setValue(maxRadius, forKey: "inputRadius"); f.setValue(Self.mask(), forKey: "inputMaskImage"); f.setValue(true, forKey: "inputNormalizeEdges")
    backdrop.filters = [f]
    backdrop.superlayer?.sublayers?.filter { $0 !== backdrop }.forEach { $0.isHidden = true }   // drop tint/chameleon layers
  }
}
```

**Countdown layout**
- Put it in a panel per screen covering the top ~45% of the screen, at `.statusBar` or `.screenSaver` level, `.nonactivatingPanel` so focus isn't stolen.
- The blur fades out downward. The timer sits centred in the blurred band, and the "Do not enter Silicon Mode" button (`.buttonStyle(.glass)`) is in the top-right.
- Animate `inputRadius` from 0 to 40 over about 300 ms on appear, and fade the numbers with Hoy's digit roll.

---

## 8. NameDrop-style "bump" entry animation

### 8.1 What NameDrop looks like (iOS 17), frame by frame

There is no official spec. This is assembled from Apple's demos and press descriptions ([TapSmart](https://www.tapsmart.com/tips-and-tricks/ios17-namedrop/), [Creative Bloq](https://www.creativebloq.com/news/ios-17-namedrop)).

1. **Approach (about 0–300 ms).** A soft white-cyan **glow blooms at the top edge** around the Dynamic Island. The wallpaper near the top is **pulled toward it**: a pinch or suction stretch with slight blur, as if liquid were drawn into the island.
2. **Contact, the "bang" (about 300 ms).** A bright flash at the contact point, with a haptic. A **shockwave ring** leaves the top-centre: a thin luminous rim with faint prismatic fringes that expands and decelerates. Content under the ring is **refracted**, displaced radially like a water lens. A weaker echo ring follows.
3. **Reveal (about 0.35–1.0 s).** Behind the wave the other person's **Contact Poster** fills the screen, emerging from the top. The ring reaches the bottom edge and fades, and the glow dies away.
4. **Settle.** The poster settles with a slight spring and the action buttons fade in.

For Silicon Mode, the origin is the **top-centre of each display**, the camera notch. That ties the motion to the lid hinge: "the Mac bumped into Silicon Mode". The face is revealed inside the ring, while outside the ring the progressively blurred desktop is still visible.

### 8.2 Shader (`SiliconBump.metal`)

Verified: it compiled with `MTLDevice.makeLibrary(source:)` (MSL 3.1, `[[stitchable]]` accepted), and a Metal harness rendered frames at t = 0.30, 0.42, 0.60, 0.85 and 1.40 s that showed the expected glow → flash, then refractive reveal bubble → expanding lens ring → full reveal.

```metal
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 bumpShockwave(float2 pos, SwiftUI::Layer layer,
                                     float2 origin, float2 size, float t, half4 tint) {
    const float tBang = 0.32;                       // = 320 ms impact in enter_silicon.wav
    float2 d = pos - origin; float dist = length(d);
    float2 dir = dist > 0.001 ? d / dist : float2(0.0, 1.0);
    float diag = length(size);
    // 1) gather: suction toward origin
    float gather = smoothstep(0.0, tBang, t) * (1.0 - smoothstep(tBang, tBang + 0.10, t));
    float2 s = pos + dir * (26.0 * gather * exp(-dist / (0.16 * diag)));
    // 2) primary ring (decelerating, widening, decaying) — derivative-of-gaussian = lens refraction
    float ts = max(t - tBang, 0.0), on1 = step(tBang, t);
    float r1 = diag * 0.62 * (1.0 - exp(-2.4 * ts)), w1 = 24.0 + 70.0 * ts;
    float x1 = (dist - r1) / w1, ring1 = exp(-4.0 * x1 * x1) * on1;
    s += dir * 24.0 * exp(-2.2 * ts) * (-2.0 * x1) * ring1;
    // 3) echo ring 120 ms later
    float ts2 = max(t - tBang - 0.12, 0.0), on2 = step(tBang + 0.12, t);
    float r2 = diag * 0.50 * (1.0 - exp(-2.4 * ts2));
    float x2 = (dist - r2) / (18.0 + 45.0 * ts2), ring2 = exp(-4.0 * x2 * x2) * on2;
    s += dir * 9.0 * exp(-3.0 * ts2) * (-2.0 * x2) * ring2;
    // 4) chromatic split on the rim
    float ca = 3.0 * ring1 * exp(-2.0 * ts);
    half4 g = layer.sample(s);
    half4 c = half4(layer.sample(s + dir * ca).r, g.g, layer.sample(s - dir * ca).b, g.a);
    // 5) reveal inside the ring (soft edge); fully revealed by ~1.6 s
    float reveal = max(on1 * (1.0 - smoothstep(r1 - w1 * 0.3, r1 + w1 * 0.6, dist)), smoothstep(0.9, 1.3, ts));
    c *= half(reveal);
    // 6) light: bloom during gather, flash at bang, bright rim
    float bloom = smoothstep(0.0, tBang, t) * exp(-dist / 110.0) * (1.0 - smoothstep(tBang, tBang + 0.55, t));
    float flash = exp(-dist / 260.0) * exp(-14.0 * ts) * on1;
    float rim   = 0.55 * ring1 * exp(-1.6 * ts) + 0.18 * ring2 * exp(-3.0 * ts2);
    c += tint * half(saturate(bloom * 0.9 + flash * 0.8 + rim));   // premultiplied add
    return c;
}
```

### 8.3 SwiftUI driver (verified typecheck)

```swift
struct BumpReveal<Content: View>: View {
  let start: Date; let origin: CGPoint           // origin = CGPoint(x: width/2, y: 0)
  @ViewBuilder var content: Content
  var body: some View {
    TimelineView(.animation) { tl in
      let t = Float(tl.date.timeIntervalSince(start))
      GeometryReader { geo in
        content.layerEffect(ShaderLibrary.bumpShockwave(.float2(origin), .float2(geo.size), .float(t),
                                                        .color(.init(red: 0.75, green: 0.9, blue: 1))),
                            maxSampleOffset: CGSize(width: 64, height: 64),   // ≥ max displacement (~26+24+3)
                            isEnabled: t < 1.8)                               // then render plain
      }
    }
  }
}
```

**Choreography**
- At t = 0, play `enter_silicon.wav`.
- At t = 0.32 s:
  - fire `NSHapticFeedbackManager…perform(.levelChange…)`;
  - start the face's own entrance: scale 0.94 → 1 on spring(0.5, 0.72), blur 12 → 0;
  - fade the countdown blur band out over 400 ms.
- The face layer must be **opaque** (or have its own background) so that it fully covers the blurred desktop once revealed.
- **Build prerequisite:** run `xcodebuild -downloadComponent MetalToolchain` once. It is currently `uninstalled`, and without it `.metal` files won't compile. The alternative is to compile the source at runtime and use `ShaderLibrary(url:)`.

---

## 9. Lid angle sensor (verified on this MacBookPro18,1)

**Device and report format**
- The `IOHIDManager` match `VID 0x05AC, PID 0x8104` returns **4 interfaces**: `gyro`, `als-temp` and `accel` (PrimaryUsagePage 0xFF00), plus `las` (PrimaryUsagePage **0x20**, PrimaryUsage **0x8A**, transport `SPU`).
- If you match on `"UsagePage"/"Usage"` instead (as LidAngleSensor does), `Set.first` returned **`als-temp`** in one run, and its reads fail with `0xE00002C7`. **Match on `kIOHIDPrimaryUsagePageKey`/`kIOHIDPrimaryUsageKey`** and assert `Product == "las"`.
- Report: `IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, &buf, &len)` gives `len = 3`, `[0x01, lo, hi]`, angle = `lo | hi<<8` in **whole degrees** (the element is 9 bits, logical range 0…360). It read 98 at test time.
- Cost: 300 reads at **≈0.53 ms per read**. The device's `ReportInterval` is 8000 µs (125 Hz). The input-report callback delivered only about 1 report per second while the lid was still, so **poll**. 10 Hz is enough for stability detection; use 30–60 Hz inside Silicon Mode for panic.

**Permissions**
- `IOHIDManagerOpen` and `IOHIDDeviceOpen` with `kIOHIDOptionsTypeNone` (non-seizing) succeeded. Reads worked even though `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` returned `1` (denied).
- So **Input Monitoring is not required**, and a non-sandboxed, hardened-runtime app needs **no entitlement**.
- If the app is ever sandboxed, Apple DTS says `com.apple.security.device.usb` replaces the deprecated `com.apple.security.device.hid` ([forum](https://developer.apple.com/forums/thread/127670)). That is untested for SPU devices. Recommendation: ship non-sandboxed (Developer ID).

**Logic hints**
- "Stable" = max − min ≤ 2° over 1.0 s.
- Panic = `angle < 0.9 × siliconAngle` **and** velocity < −15°/s (rejects slow drift), with a 3-sample confirm (~60 ms at 50 Hz).
- After sleep and wake, ignore the first 1 s of samples.

```swift
let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104,
                                  kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
let dev = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)!.first!; IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
var r = [UInt8](repeating: 0, count: 8); var len = CFIndex(8)
if IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, &r, &len) == kIOReturnSuccess, len >= 3 { let deg = Int(r[2]) << 8 | Int(r[1]) }
```

Reference: [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor), cloned in refs. Its README says M1/M2 is unsupported, but this M1 Pro 16" works.

---

## 10. Open risks

1. **Activation.** `activate(ignoringOtherApps:)` is deprecated (macOS 14). If a future OS no-ops it, lock options won't apply when triggered in the background. Re-test on every macOS update. The fallback is to start the lock on the user's first click or keypress in our panel.
2. **The private APIs** (`CAFilter variableBlur`, the `CABackdropLayer` walk, and clamshell selector 12) can break silently. Feature-detect and fall back. Selector 12 persists globally: always reset it, including on crash (use a launchd or helper watchdog).
3. **Lid-close sleep can't be prevented publicly.** Panic must fire before the hall-sensor close (exact angle unknown) while the display and speakers still work. Measure the angle at which `AppleClamshellState` flips on this hardware.
4. **The Metal toolchain is missing**, so the first `.metal` build fails until someone downloads it.
5. **Embedded Touch ID.** I verified that the view arms and shows no system sheet, but not that a real finger unlocks. Do a manual check. Guard the `-1007` beta regression.
6. **Flashing.** Keep panic flashes at or below 3 Hz (WCAG 2.3.1), and offer "reduce flashing" that follows `accessibilityDisplayShouldReduceMotion`.
7. **Overlay level.** System alerts at or below the screen-saver level can hide under the lock. Watch for this in QA.
8. **Audio routing.** With headphones connected, panic is inaudible to bystanders unless it is forced to the built-in speakers.

---

## Appendix A: reference SFX renderer (stdlib Python, verified)

Run `python3 -I render_sfx.py OUTDIR`. It writes 48 kHz mono 16-bit WAVs: `panic_loop` (1200 ms), `tick_5..1` (58 ms), `enter_silicon` (1750 ms), `unlock_success` (790 ms), `wrong_pin` (220 ms) and `question_ping` (760 ms). The tested copy is at `<scratchpad>/sfx/render_sfx.py`.

```python
#!/usr/bin/env python3
import math, random, struct, sys, wave
SR = 48000; random.seed(7)
def osc(kind, ph):
    p = ph % 1.0
    return {'sine': math.sin(2*math.pi*p), 'triangle': 4*abs(p-.5)-1, 'square': 1.0 if p < .5 else -1.0, 'saw': 2*p-1}[kind]
class Biquad:  # RBJ cookbook; lowpass/highpass q<=0 is WebAudio-style dB
    def __init__(s, kind, q): s.k, s.q, s.z, s.f = kind, q, [0.0]*4, None
    def set(s, f):
        if s.f is not None and abs(f-s.f) < .5: return
        s.f = f; w = 2*math.pi*min(f, SR*.45)/SR; cw, sw = math.cos(w), math.sin(w); q = s.q
        if s.k in ('lowpass', 'highpass') and q is not None and q <= 0: q = 10**(q/20)
        q = q or .7071; a = sw/(2*q)
        b = {'lowpass': [(1-cw)/2, 1-cw, (1-cw)/2], 'highpass': [(1+cw)/2, -(1+cw), (1+cw)/2]}.get(s.k, [a, 0, -a])
        a0 = 1+a; s.b = [x/a0 for x in b]; s.a = [-2*cw/a0, (1-a)/a0]
    def __call__(s, x):
        x1, x2, y1, y2 = s.z; y = s.b[0]*x+s.b[1]*x1+s.b[2]*x2-s.a[0]*y1-s.a[1]*y2; s.z = [x, x1, y, y1]; return y
def render(voices, total_ms=None, peak_db=-1.0, loop=False):
    end = max(v.get('at', 0)+v['ms'] for v in voices); n = int(SR*(total_ms or end+20)/1000); buf = [0.0]*n
    for v in voices:
        s0, ln = int(SR*v.get('at', 0)/1000), int(SR*v['ms']/1000)
        f0 = v['hz']; f1 = v.get('to', f0); gl = v.get('glide', v['ms'])/1000; g = v.get('gain', .05)
        atk = min(v.get('atk', 4), v['ms']*.6)/1000; hold = v.get('hold', 0)/1000; dur = v['ms']/1000
        filt = Biquad(v['noise'], v.get('q')) if 'noise' in v else None
        lp = Biquad('lowpass', None) if 'cut' in v else None
        if lp: lp.set(v['cut'])
        am = v.get('am'); ph = 0.0
        for i in range(ln):
            t = i/SR; f = f0*(f1/f0)**min(t/gl, 1.0) if f1 != f0 else f0
            if t < atk: e = g*(t/atk) if v.get('lin') else 1e-4*(g/1e-4)**(t/atk)
            elif t < atk+hold: e = g
            else: e = g*(1e-4/g)**((t-atk-hold)/max(dur-atk-hold, 1e-6))
            if filt: filt.set(f); x = filt(random.uniform(-1, 1))
            else: ph += f/SR; x = osc(v.get('wave', 'sine'), ph)
            if lp: x = lp(x)
            if am: x *= 1-am[1]*(.5+.5*math.cos(2*math.pi*am[0]*t))
            j = (s0+i) % n if loop else s0+i
            if j < n: buf[j] += x*e
    if not loop:
        for k in range(min(12, n)): buf[k] *= k/12
        for k in range(min(96, n)): buf[n-1-k] *= k/96
    s = 10**(peak_db/20)/max(1e-9, max(abs(x) for x in buf)); return [x*s for x in buf]
def bar(hz, at, ms, gain, atk=3, glide_from=None):   # struck bar 1 : 2.756 : 5.404
    out = []
    for r, gm, dm in ((1, 1, 1), (2.756, .30, .5), (5.404, .10, .27)):
        v = dict(hz=hz*r, ms=ms*dm, at=at, gain=gain*gm, atk=atk)
        if glide_from: v.update(hz=glide_from*r, to=hz*r, glide=25)
        out.append(v)
    return out
def tick(step):
    m = 2**(step/12)
    return [dict(noise='bandpass', hz=3200*m, q=1.5, ms=6, gain=.6, atk=.5),
            dict(hz=1760*m, to=1320*m, glide=12, ms=38, gain=.35, atk=1),
            dict(wave='triangle', hz=420*m, to=380*m, ms=32, gain=.25, atk=1, cut=1800)]
def panic_figure(at):
    def tone(hz, to, a, ms, g, glide=None): return [
        dict(wave='square', hz=hz, to=to, glide=glide or ms, at=a, ms=ms, gain=g, atk=3, hold=ms*.55, cut=3500, am=(28, .3)),
        dict(wave='saw', hz=hz*1.0035, to=to*1.0035, glide=glide or ms, at=a, ms=ms, gain=g*.6, atk=3, hold=ms*.55, cut=3500),
        dict(hz=hz/2, to=to/2, glide=glide or ms, at=a, ms=ms, gain=g*.5, atk=3, hold=ms*.55)]
    return (tone(900, 880, at, 130, .5, glide=15) + tone(622.25, 587.33, at+150, 280, .55)
            + [dict(noise='bandpass', hz=2200, q=1.2, at=at+o, ms=8, gain=.5, atk=.5) for o in (0, 150)])
SOUNDS = {
  'panic_loop': (panic_figure(0)+panic_figure(600), dict(total_ms=1200, peak_db=-1.0)),
  **{f'tick_{5-s}': (tick(s), dict(peak_db=-6.0)) for s in range(5)},
  'enter_silicon': ([dict(noise='bandpass', hz=400, to=3200, q=1.0, ms=380, gain=.5, atk=300, lin=True),
                     dict(hz=180, to=520, ms=360, gain=.12, atk=300, lin=True),
                     dict(hz=110, to=55, glide=90, at=320, ms=160, gain=.6, atk=2),
                     dict(noise='lowpass', hz=1200, q=-3, at=320, ms=45, gain=.35, atk=1)]
                    + bar(659.25, 330, 1400, .45, glide_from=659.25*1.09) + bar(987.77, 400, 1200, .32, glide_from=987.77*1.09)
                    + [dict(hz=f, at=a, ms=d, gain=.05, atk=2) for f, a, d in
                       ((7050, 380, 60), (9290, 410, 40), (7950, 470, 50), (9380, 520, 70), (6740, 560, 90), (10050, 640, 60))],
                    dict(peak_db=-3.0)),
  'unlock_success': ([dict(noise='bandpass', hz=2400, q=3, ms=5, gain=.4, atk=.5),
                      dict(wave='triangle', hz=330, to=620, ms=120, gain=.12, atk=30, cut=1400)]
                     + bar(783.99, 0, 160, .4) + bar(1174.66, 75, 200, .4) + bar(1567.98, 150, 620, .45)
                     + [dict(hz=3135.96, at=155, ms=300, gain=.06, atk=8)], dict(peak_db=-3.0)),
  'wrong_pin': ([dict(wave='square', hz=155, to=140, at=a, ms=90, gain=g, atk=3, cut=900) for a, g in ((0, .5), (110, .42))]
                + [dict(wave='square', hz=164, to=148, at=a, ms=90, gain=g*.8, atk=3, cut=900) for a, g in ((0, .5), (110, .42))]
                + [dict(hz=80, to=60, at=a, ms=70, gain=.5, atk=2) for a in (0, 110)], dict(peak_db=-3.0)),
  'question_ping': ([dict(noise='lowpass', hz=3000, q=-3, ms=5, gain=.25, atk=.5)]
                    + bar(880, 0, 180, .35) + bar(1318.51, 90, 650, .5, glide_from=1290), dict(peak_db=-4.0)),
}
if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    for name, (voices, kw) in SOUNDS.items():
        data = render(voices, loop=name.endswith('_loop'), **kw)
        with wave.open(f'{out}/{name}.wav', 'wb') as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
            w.writeframes(b''.join(struct.pack('<h', int(max(-1, min(1, x))*32767)) for x in data))
```

## Sources

- Hoy: https://gethoy.app/ (with `/assets/hoy.css` and `/assets/hoy.js`)
- bencho: https://bencho.dev/sounds, https://bencho.dev/sounds/glint, `/assets/sound-6qabUvCG.js`
- Apple, Liquid Glass: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
- Apple, presentation options: https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct
- Apple, WindowMenuBarExtraStyle: https://developer.apple.com/documentation/swiftui/windowmenubarextrastyle
- Apple, LocalAuthenticationEmbeddedUI: https://developer.apple.com/documentation/localauthenticationembeddedui
- Forums: 759212 (LAAuthenticationView without the prompt), 835885 (macOS 27 beta `-1007`), 802313 (MenuBarExtra hover on Tahoe), 763878 (Sequoia Option hot keys), 127670 (HID entitlement)
- WWDC26 session 322, "Compose advanced graphics effects with SwiftUI" (`layerEffect`, `TimelineView`): https://developer.apple.com/videos/play/wwdc2026/322/
- xnu: `apple-oss-distributions/xnu` `iokit/Kernel/RootDomainUserClient.cpp`, `IOPMrootDomain.cpp`, `IOPMLibDefs.h` (selector 12)
- Variable-blur references: nikstar/VariableBlur, OskarGroth/MaterialView, cyrilzakka/NameDrop, the dkun7944 AirDrop shader gist
- Amphetamine Closed-Display Mode: App Store listing and techpp.com coverage
- SDK headers and interfaces, as cited inline (`$SDK/...`)
