import SwiftUI
import AuthenticationServices

/// Signed-out welcome: the Mac closing into Silicon Mode, and one button.
struct SignInView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            AuroraBackground(palette: Aurora.night, speed: 0.8)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
                    let t = SnapshotClock.time(tl.date)
                    // The lid eases between open and Silicon Mode, over and over.
                    let cycle = (sin(t * 0.5) + 1) / 2
                    HingeGlyph(angle: 62 + 46 * cycle, siliconAngle: 62, state: cycle < 0.35 ? .active : .off,
                               agents: [.init(color: Color(hex: "E8A184"), needsYou: false),
                                        .init(color: Theme.Night.accent, needsYou: false),
                                        .init(color: Color(hex: "5FD3AE"), needsYou: false),
                                        .init(color: Theme.Night.warning, needsYou: true)],
                               t: t, night: true)
                }
                .frame(width: 300, height: 230)
                .scaleEffect(appeared ? 1 : 0.86)
                .opacity(appeared ? 1 : 0)

                VStack(spacing: 12) {
                    Text("Silicon Mode")
                        .allo(44, .semibold, display: true)
                        .foregroundStyle(LinearGradient(colors: [Theme.Night.lavender, Theme.Night.peach],
                                                        startPoint: .leading, endPoint: .trailing))
                    Text("Your agents, in your pocket.")
                        .allo(19, .medium)
                        .foregroundStyle(Theme.Night.foreground)
                }
                .offset(y: appeared ? 0 : 16)
                .opacity(appeared ? 1 : 0)

                VStack(alignment: .leading, spacing: 14) {
                    feature("laptopcomputer", "Know when your Mac is in Silicon Mode — and if someone's closing it.")
                    feature("hand.raised.fill", "Answer agent questions and permissions from anywhere.")
                    feature("square.grid.3x3.fill", "See your patterns: every hour, every day.")
                }
                .padding(.top, 30)
                .padding(.horizontal, 8)
                .offset(y: appeared ? 0 : 24)
                .opacity(appeared ? 1 : 0)

                Spacer(minLength: 24)

                VStack(spacing: 14) {
                    if let err = store.signInError {
                        Text(err)
                            .allo(14, .medium)
                            .foregroundStyle(Theme.Night.danger)
                            .multilineTextAlignment(.center)
                            .transition(.blurReplace)
                    }
                    Button(action: signIn) {
                        HStack(spacing: 10) {
                            if store.isSigningIn {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            Text(store.isSigningIn ? "Signing in…" : "Sign in with Silicon Accounts")
                                .allo(17, .semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.Night.accent.mix(with: Color(hex: "3460F0"), by: 0.45))
                    .controlSize(.extraLarge)
                    .disabled(store.isSigningIn)
                    Text("Use the same account as Silicon Mode on your Mac.")
                        .allo(13)
                        .foregroundStyle(Theme.Night.muted)
                }
                .padding(.bottom, 12)
                .opacity(appeared ? 1 : 0)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
        }
        .environment(\.colorScheme, .dark)
        .animation(Theme.Motion.slow, value: store.signInError)
        .onAppear {
            withAnimation(reduceMotion ? .none : .spring(duration: 0.9, bounce: 0.2).delay(0.1)) { appeared = true }
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Theme.Night.lavender, Theme.Night.peach], startPoint: .top, endPoint: .bottom))
                .frame(width: 34, height: 34)
                .glassEffect(.clear, in: .circle)
            Text(text)
                .allo(15)
                .foregroundStyle(Theme.Night.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
            Spacer(minLength: 0)
        }
    }

    private func signIn() {
        store.beginSignIn()
        Task {
            do {
                let url = try await webAuth.authenticate(using: SignIn.url,
                                                         callback: .customScheme(SignIn.callbackScheme),
                                                         preferredBrowserSession: .shared,
                                                         additionalHeaderFields: [:])
                await store.finishSignIn(SignIn.parse(url))
            } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
                store.endSignIn(error: nil)
            } catch {
                store.endSignIn(error: error.localizedDescription)
            }
        }
    }
}
