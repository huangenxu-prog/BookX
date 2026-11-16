import XCTest

final class BookXUITests: XCTestCase {
    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BOOKX_UI_TEST_RESET"] = "1"
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
        app.buttons["下一页"].tap()
        app.buttons["下一页"].tap()
        XCTAssertTrue(position.label.hasPrefix("3 /"))
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
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "第一章")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["无法阅读"].exists)
        snapshot("04-epub")
    }
    func testScrollModeTracksReadingAndResumes() {
        let app = launchFresh()
        app.buttons["library-book-阅读测试"].tap()
        XCTAssertTrue(app.staticTexts["reading-position"].waitForExistence(timeout: 15))
        app.buttons["阅读设置"].tap()
        let mode = app.buttons["page-mode-picker"]
        for _ in 0..<3 { if !mode.isHittable { app.swipeUp() } }
        mode.tap()
        app.buttons["上下滚动"].tap()
        app.buttons["完成"].tap()
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
