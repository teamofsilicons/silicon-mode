import XCTest

/// End-to-end checks against the live cell, driven from the CLI (see docs/IOS.md):
///
///   TEST_RUNNER_SM_DEEPLINK="ai.tos.mode://auth/callback#access_token=…" \
///     xcodebuild test … -only-testing:SiliconModeUITests/SignInFlowUITests/testSignInThroughDeepLink
///
/// The session is delivered through the real custom-scheme deep link (system open → SpringBoard
/// "Open in Silicon Mode?" → `.onOpenURL`). Tests skip when no deep link is provided.
@MainActor
final class SignInFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSignInThroughDeepLink() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["SM_DEEPLINK"].flatMap(URL.init(string:)),
                                 "set TEST_RUNNER_SM_DEEPLINK")
        let app = XCUIApplication()
        // The app ignores sign-in links it didn't ask for; debug builds accept one under this flag.
        app.launchArguments += ["-SMAcceptDeepLinkSignIn"]
        app.launch()
        XCUIDevice.shared.system.open(link)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 15) { open.tap() }
        // Signed in: the tab bar shows up with Now.
        XCTAssertTrue(app.tabBars.buttons["Now"].waitForExistence(timeout: 40) || app.buttons["Now"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A sign-in link nobody asked for (no Sign in tap, no test flag) must not sign the phone in.
    /// Run signed out; uses a junk session so nothing real is at stake.
    func testUnrequestedSignInLinkIsIgnored() throws {
        guard ProcessInfo.processInfo.environment["SM_SIGNED_OUT"] != nil else {
            throw XCTSkip("set TEST_RUNNER_SM_SIGNED_OUT=1 on a signed-out simulator")
        }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Sign in with Silicon Accounts"].waitForExistence(timeout: 20))
        XCUIDevice.shared.system.open(URL(string: "ai.tos.mode://auth/callback#access_token=junk&refresh_token=csr_junk&expires_at=9999999999")!)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 15) { open.tap() }
        let notice = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'started on this iPhone'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Sign in with Silicon Accounts"].exists)
    }

    /// Opens the first agent's detail sheet (screenshot attached to the result bundle).
    func testAgentDetailSheet() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-SMScroll", "agents", "-SMScrollDelay", "4"]
        if let mac = ProcessInfo.processInfo.environment["SM_MAC"] { app.launchArguments += ["-selectedMac", mac] }
        if ProcessInfo.processInfo.environment["SM_DEMO"] != nil { app.launchArguments += ["-SMDemo", "YES"] }
        app.launch()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Working'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        row.tap()
        let header = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Recent events'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "agent-detail"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Signs out from Settings (revokes the cell session) and lands on the sign-in screen.
    func testSignOut() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-SMTab", "settings"]
        app.launch()
        let signOut = app.buttons["Sign out"].firstMatch
        if !signOut.waitForExistence(timeout: 30) {
            app.swipeUp()
        }
        for _ in 0..<4 where !signOut.isHittable { app.swipeUp() }
        signOut.tap()
        let confirm = app.sheets.buttons["Sign out"].firstMatch.exists ? app.sheets.buttons["Sign out"].firstMatch
            : app.buttons.matching(identifier: "Sign out").element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.buttons["Sign in with Silicon Accounts"].waitForExistence(timeout: 30))
    }

    /// Taps the first option of the first pending question and waits for the "Sent" state.
    func testAnswerFirstQuestion() throws {
        let label = ProcessInfo.processInfo.environment["SM_OPTION"] ?? "Allow once"
        let app = XCUIApplication()
        app.launchArguments += ["-SMScroll", "questions", "-SMScrollDelay", "4"]
        if let mac = ProcessInfo.processInfo.environment["SM_MAC"] { app.launchArguments += ["-selectedMac", mac] }
        app.launch()
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 40), "no '\(label)' option on screen")
        button.tap()
        let sent = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sent'")).firstMatch
        let done = app.staticTexts["Done"]
        XCTAssertTrue(sent.waitForExistence(timeout: 30) || done.exists, "answer was not acknowledged")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
