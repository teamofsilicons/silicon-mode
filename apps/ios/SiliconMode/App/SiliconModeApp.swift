import SwiftUI

@main
struct SiliconModeApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Theme.installAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { await store.bootstrap() }
                .onOpenURL { store.handle(url: $0) }
        }
        .onChange(of: scenePhase) { _, phase in store.scenePhaseChanged(phase) }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("appearance") private var appearance = 0

    var body: some View {
        ZStack {
            switch store.auth {
            case .unknown:
                Theme.background.ignoresSafeArea()
            case .signedOut:
                SignInView()
                    .transition(.opacity)
            case .signedIn:
                MainTabs()
                    .transition(.asymmetric(insertion: .scale(scale: 1.03).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(Theme.Motion.slow, value: store.auth)
        .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
        .tint(Theme.accent)
    }
}

struct MainTabs: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.tab) {
            Tab("Now", systemImage: "sparkles", value: AppTab.now) {
                NowView()
            }
            .badge(store.pendingQuestionCount)
            Tab("Patterns", systemImage: "square.grid.3x3.fill", value: AppTab.stats) {
                StatsView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
