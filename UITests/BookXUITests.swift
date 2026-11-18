import XCTest

final class BookXUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launchFresh(scrollMode: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BOOKX_UI_TEST_RESET"] = "1"
        if scrollMode { app.launchEnvironment["BOOKX_UI_TEST_SCROLL"] = "1" }
        let bundle = Bundle(for: Self.self)
        if let url = bundle.url(forResource: "ordered", withExtension: "epub") {
            app.launchEnvironment["BOOKX_UI_TEST_EPUB"] = try? Data(contentsOf: url).base64EncodedString()
        } else { XCTFail("Missing EPUB test fixture") }
        app.launch()
        XCTAssertTrue(app.buttons["library-book-阅读测试"].waitForExistence(timeout: 30))
        return app
    }
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testTXTReadResumeAcrossRelaunch() {
        let app = launchFresh()
        snapshot("01-library")
        app.buttons["library-book-阅读测试"].tap()
        let position = app.staticTexts["reading-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 15))
        app.swipeLeft()
        app.swipeLeft()
        XCTAssertFalse(position.label.hasPrefix("1 /"))
        let saved = position.label
        snapshot("02-reader")
        app.buttons["返回"].tap()
        app.buttons["tab-shelf"].tap()
        XCTAssertTrue(app.buttons["continue-reading"].waitForExistence(timeout: 5))
        snapshot("03-bookshelf")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "BOOKX_UI_TEST_RESET")
        app.launch()
        XCTAssertTrue(app.buttons["continue-reading"].waitForExistence(timeout: 10))
        app.buttons["continue-reading"].tap()
        XCTAssertTrue(position.waitForExistence(timeout: 15))
        XCTAssertEqual(position.label, saved)
    }
    func testEPUBImportAndRead() {
        let app = launchFresh()
        let epub = app.buttons["library-book-测试书"]
        XCTAssertTrue(epub.waitForExistence(timeout: 20))
        epub.tap()
        XCTAssertTrue(app.staticTexts["reading-position"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["reading-position"].label.isEmpty)
        XCTAssertFalse(app.staticTexts["无法阅读"].exists)
        snapshot("04-epub")
    }
    func testScrollModeTracksReadingAndResumes() {
        let app = launchFresh(scrollMode: true)
        app.buttons["library-book-阅读测试"].tap()
        XCTAssertTrue(app.staticTexts["reading-position"].waitForExistence(timeout: 15))
        for _ in 0..<4 { app.swipeUp() }
        let position = app.staticTexts["reading-position"]
        let saved = position.label
        XCTAssertFalse(saved.hasPrefix("1 /"))
        app.buttons["返回"].tap()
        app.buttons["tab-shelf"].tap()
        app.buttons["continue-reading"].tap()
        XCTAssertTrue(position.waitForExistence(timeout: 15))
        XCTAssertEqual(position.label, saved)
    }
}
