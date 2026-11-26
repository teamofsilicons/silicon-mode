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
