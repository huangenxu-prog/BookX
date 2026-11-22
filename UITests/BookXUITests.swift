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
    private func closeReader(_ app: XCUIApplication) {
        let back = app.buttons["返回"]
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: back)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 10), .completed)
        let statusBar = app.statusBars.firstMatch
        if statusBar.exists {
            XCTAssertGreaterThanOrEqual(back.frame.minY, statusBar.frame.maxY,
                                        "Reader controls must not overlap the system status bar")
        }
        app.buttons["返回"].tap()
        // The reader is a full-screen presentation. Wait for its dismissal
        // before interacting with the underlying shelf tab; otherwise the
        // tap can be consumed by the departing modal.
        let readerClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["返回"]
        )
        let dismissalResult = XCTWaiter.wait(for: [readerClosed], timeout: 15)
        if dismissalResult != .completed {
            print("BOOKX_DISMISS_DIAGNOSTIC: reader back still exists after close")
            print("BOOKX_DISMISS_DIAGNOSTIC: " + app.debugDescription)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Reader-dismissal-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(dismissalResult, .completed)
        XCTAssertFalse(app.staticTexts["reading-position"].exists)
        XCTAssertTrue(app.buttons["tab-shelf"].isHittable)
    }
    func testTXTReadResumeAcrossRelaunch() {
        let app = launchFresh()
        snapshot("01-library")
        app.buttons["library-book-阅读测试"].tap()
        let position = app.staticTexts["reading-position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 15))
        app.swipeLeft()
        app.swipeLeft()
        XCTAssertFalse(position.label.hasPrefix("1 /"))
        let saved = position.label
        snapshot("02-reader")
        closeReader(app)
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
    func testReadAloudEntryInCurlReaderMenu() {
        let app = launchFresh()
        app.buttons["library-book-阅读测试"].tap()
        XCTAssertTrue(app.staticTexts["reading-position"].waitForExistence(timeout: 15))
        let menus = app.buttons.matching(identifier: "阅读功能")
        XCTAssertTrue(menus.firstMatch.waitForExistence(timeout: 10),
                      "Reading menu must exist in the native page-curl reader")
        if let visible = menus.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            visible.tap()
        } else {
            // UIPageViewController retains off-screen sheet controls, which can
            // win the first accessibility match even while the visible header
            // is tappable. Tap the physical mirrored header position instead.
            let back = app.buttons["返回"].firstMatch
            XCTAssertTrue(back.isHittable)
            let point = app.coordinate(withNormalizedOffset: CGVector(
                dx: (app.frame.width - back.frame.midX) / app.frame.width,
                dy: back.frame.midY / app.frame.height))
            point.tap()
        }
        snapshot("06-read-aloud-menu")
        let entry = app.buttons["开始听书"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10),
                      "Start read-aloud must appear in the opened reading menu")
        XCTAssertTrue(app.buttons["听书音色"].exists,
                      "Voice selection must appear alongside read-aloud")
    }
    func testScrollModeTracksReadingAndResumes() {
        let app = launchFresh(scrollMode: true)
        app.buttons["library-book-阅读测试"].tap()
        XCTAssertTrue(app.staticTexts["reading-position"].waitForExistence(timeout: 15))
        for _ in 0..<4 { app.swipeUp() }
        let position = app.staticTexts["reading-position"].firstMatch
        let saved = position.label
        XCTAssertFalse(saved.hasPrefix("1 /"))
        snapshot("05-scroll-before-close")
        closeReader(app)
        let shelfTab = app.buttons["tab-shelf"]
        shelfTab.tap()
        let resume = app.buttons["continue-reading"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "Continue-reading button should appear after returning to shelf")
        resume.tap()
        XCTAssertTrue(position.waitForExistence(timeout: 15))
        XCTAssertEqual(position.label, saved)
    }
}
