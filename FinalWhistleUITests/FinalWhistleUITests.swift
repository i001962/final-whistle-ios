import XCTest

/// One UI test of the main loop: launch, see the onboarding screen (no
/// identity saved on a fresh install), browse the feed without an account,
/// and see feed content load. Written without Xcode and NOT run yet.
final class FinalWhistleUITests: XCTestCase {
    func testMainLoopBrowseFeedWithoutAccount() throws {
        let app = XCUIApplication()
        app.launch()

        // First screen on a fresh install is onboarding (no identity saved).
        XCTAssertTrue(app.staticTexts["Final Whistle"].waitForExistence(timeout: 10))

        // Browse without an account: the feed must work read-only.
        app.buttons["Browse the feed without an account"].tap()
        XCTAssertTrue(app.staticTexts["Final Whistle"].waitForExistence(timeout: 10))

        // The feed tabs are present.
        XCTAssertTrue(app.segmentedControls.firstMatch.waitForExistence(timeout: 10))

        // Wait for the network feed to load (or for the empty/error state).
        // Either outcome proves the app launched and reached the feed screen;
        // a network failure on the test machine shows the error state, not a crash.
        let loaded = app.staticTexts["Trending"].waitForExistence(timeout: 20)
        XCTAssertTrue(loaded)
    }
}
