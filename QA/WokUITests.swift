import UIKit
import XCTest

final class WokUITests: XCTestCase {
    func shot(_ name: String) {
        let photo = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        photo.name = name
        photo.lifetime = .keepAlways
        add(photo)
    }

    func hasValue(_ item: XCUIElement, _ part: String, timeout: Double = 8, file: StaticString = #filePath, line: UInt = #line) {
        let check = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", part), object: item)
        let result = XCTWaiter.wait(for: [check], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(item.identifier) expected \(part), saw \(item.value ?? "?")", file: file, line: line)
    }

    func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func swipe(_ from: XCUIElement, to: XCUIElement, hover: TimeInterval = 0) {
        from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.07,
            thenDragTo: to.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .fast, thenHoldForDuration: hover)
    }

    func flip(_ wok: XCUIElement) {
        let origin = wok.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.08, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -41)),
                     withVelocity: .fast, thenHoldForDuration: 0)
    }

    func launch(_ app: XCUIApplication, locale: String = "en-GB", shift: String? = nil) {
        app.launchArguments = ["-AppleLanguages", "(\(locale))", "-AppleLocale", locale.replacingOccurrences(of: "-", with: "_")]
        if let shift {
            app.launchEnvironment = [
                "WOK_QA_PROFILE": shift, "WOK_QA_SHIFT": shift,
                "WOK_QA_SLOW": shift == "lights1" ? "2" : "1", "WOK_QA_TELEMETRY": "1"
            ]
        }
        app.launch()
    }

    func stock(_ food: String, in pan: Int, _ app: XCUIApplication) {
        app.buttons["pan-\(pan)"].tap()
        app.buttons["stock-\(food)"].tap()
    }

    func cook(_ food: String, in pan: Int, twoSides: Bool = false, _ app: XCUIApplication) {
        let wok = app.buttons["pan-\(pan)"]
        stock(food, in: pan, app)
        if twoSides {
            hasValue(wok, "Seared")
            flip(wok)
        }
        hasValue(wok, "Ready", timeout: 13)
    }

    func motionWait(_ label: String, seconds: Double = 9, file: StaticString = #filePath, line: UInt = #line,
                    condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.075))
        }
        XCTFail("Motion check timed out: \(label)", file: file, line: line)
    }

    func motionContains(_ view: XCUIElement, _ part: String) -> Bool {
        (view.value as? String)?.contains(part) == true
    }

    func motionDrag(_ from: XCUIElement, toPoint target: XCUICoordinate, hold: Double = 0, speed: Double = 1900) {
        from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.065, thenDragTo: target, withVelocity: XCUIGestureVelocity(rawValue: speed), thenHoldForDuration: hold)
    }

    func motionDrag(_ from: XCUIElement, to target: XCUIElement, hold: Double = 0, speed: Double = 1900) {
        motionDrag(from, toPoint: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), hold: hold, speed: speed)
    }

    func motionThrow(_ pan: XCUIElement, to plate: XCUIElement) {
        let start = pan.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = plate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let offset = CGVector(dx: (end.screenPoint.x - start.screenPoint.x) * 0.48,
                              dy: (end.screenPoint.y - start.screenPoint.y) * 0.48)
        motionDrag(pan, toPoint: start.withOffset(offset), speed: 2100)
    }

    func motionFlip(_ pan: XCUIElement) {
        let start = pan.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        motionDrag(pan, toPoint: start.withOffset(CGVector(dx: 3, dy: -46)), hold: 0.04)
    }

    func testMotionSession() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["WOK_MOTION_AUDIO_TRACE": "1"]
        launch(app)
        let open = app.buttons["start-shift"]
        XCTAssertTrue(open.waitForExistence(timeout: 6))
        shot("Market Stall")
        open.tap()
        let hot = app.buttons["pan-1"]
        let low = app.buttons["pan-0"]
        let plate = app.buttons["plate"]
        let dumplings = app.buttons["stock-dumpling"]
        XCTAssertTrue(hot.exists)
        print("MOTION Demo begins \(Date().timeIntervalSince1970)")
        let tiles = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.51))
        motionDrag(dumplings, toPoint: tiles, hold: 0.14, speed: 1220)
        XCTAssertTrue(motionContains(hot, "Empty"))
        XCTAssertTrue(motionContains(low, "Empty"))
        print("MOTION cancelled basket grab returned \(Date().timeIntervalSince1970)")

        motionDrag(dumplings, to: hot, hold: 0.08, speed: 1280)
        shot("Loading the Wok")
        motionWait("first side changes surface") { self.motionContains(hot, "Seared") }
        motionFlip(hot)
        shot("Wok Flip")
        motionWait("second side lands and warms") { self.motionContains(hot, "Ready") && self.motionContains(hot, "Side 2") }
        motionDrag(hot, to: plate, hold: 0.12, speed: 1400)
        motionWait("first plate counted on contact") { app.staticTexts["score"].label.contains("1 /") }
        shot("Ceramic Catch")
        print("MOTION first dish contact \(Date().timeIntervalSince1970)")

        motionDrag(app.buttons["stock-noodles"], to: hot, speed: 1500)
        motionWait("noodles land in hot wok") { self.motionContains(hot, "Noodles") }
        motionDrag(hot, to: low, speed: 1850)
        motionDrag(app.buttons["stock-greens"], to: hot, speed: 1500)
        motionWait("both ingredients ready", seconds: 14) { self.motionContains(hot, "Ready") && self.motionContains(low, "Ready") }
        motionThrow(low, to: plate)
        motionThrow(hot, to: plate)
        shot("Parallel Service")
        XCTAssertTrue(motionContains(element(app, "kitchen-scene"), "air 2"), "Both objects should share the air at 1×")
        motionWait("shared dish completes once") { app.staticTexts["score"].label.contains("2 /") }
        print("MOTION second dish contact \(Date().timeIntervalSince1970)")
        XCTAssertTrue(app.staticTexts["waste"].label.contains("0"))

        // Finish with two taps for selection and release, using the same flights.
        for (food, sides) in [("dumpling", true), ("noodles", false), ("greens", false), ("dumpling", true)] {
            stock(food, in: 1, app)
            if sides {
                motionWait("sear before tap flip") { self.motionContains(hot, "Seared") }
                hot.tap()
                hot.tap()
            }
            motionWait("ready before tap serve") { self.motionContains(hot, "Ready") }
            hot.tap()
            plate.tap()
            motionWait("tap toss leaves the wok") { !self.motionContains(hot, "Ready") }
        }
        XCTAssertTrue(app.buttons["next-shift"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["receipt-served"].label.contains("5"))
        XCTAssertEqual(app.staticTexts["receipt-badge"].label, "Patch earned")
        shot("First Dinner Receipt")
    }

    func testOpeningAndResume() {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app)
        XCTAssertTrue(app.buttons["start-shift"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["start-shift"].label.contains("Open the kitchen"))
        shot("01-clean-stall")
        app.buttons["start-shift"].tap()
        XCTAssertTrue(app.buttons["ticket-0"].exists)
        XCTAssertFalse(app.buttons["pan-2"].exists)
        let fast = app.buttons["pan-1"]
        let slow = app.buttons["pan-0"]
        let plate = app.buttons["plate"]
        app.buttons["stock-dumpling"].tap()
        hasValue(fast, "Side 1")
        hasValue(fast, "Seared")
        flip(fast)
        hasValue(fast, "Side 2")
        hasValue(fast, "Ready")
        measureLayout(app, name: "iPhone portrait")
        shot("02-dumpling-turned-ready")
        swipe(fast, to: plate, hover: 0.29)
        shot("03-dumpling-in-flight")
        plate.tap()
        XCTAssertTrue(app.buttons["ticket-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["score"].label.contains("1 /"))
        plate.tap()
        plate.tap()
        XCTAssertTrue(app.staticTexts["score"].label.contains("1 /"))
        app.buttons["stock-noodles"].tap()
        hasValue(fast, "Noodles")
        swipe(fast, to: slow)
        hasValue(slow, "Noodles")
        app.buttons["stock-greens"].tap()
        hasValue(fast, "Ready")
        shot("04-noodles-low-greens-high")
        swipe(fast, to: plate)
        hasValue(slow, "Ready", timeout: 14)
        swipe(slow, to: plate)
        XCTAssertTrue(app.buttons["ticket-2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["score"].label.contains("2 /"))
        shot("05-timed-service-begins")

        cook("dumpling", in: 1, twoSides: true, app)
        swipe(fast, to: plate)
        XCTAssertTrue(app.buttons["ticket-3"].waitForExistence(timeout: 5))
        cook("noodles", in: 1, app)
        swipe(fast, to: plate)
        cook("greens", in: 1, app)
        swipe(fast, to: plate)
        XCTAssertTrue(app.buttons["ticket-4"].waitForExistence(timeout: 5))
        cook("dumpling", in: 1, twoSides: true, app)
        swipe(fast, to: plate)
        XCTAssertTrue(app.buttons["next-shift"].waitForExistence(timeout: 7))
        XCTAssertEqual(app.staticTexts["receipt-badge"].label, "Patch earned")
        XCTAssertTrue(app.staticTexts["receipt-served"].label.contains("5"))
        shot("06-earned-first-patch")

        app.terminate()
        launch(app)
        XCTAssertTrue(app.buttons["start-shift"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["start-shift"].label.contains("Take the next shift"))
        app.buttons["open-recipes"].tap()
        app.buttons["recipe-pocket"].tap()
        let practice = app.buttons["practice-pocket"]
        XCTAssertTrue(practice.waitForExistence(timeout: 4))
        shot("08-learned-recipe")
        practice.tap()
        XCTAssertTrue(app.staticTexts["Practice kitchen"].exists)
        XCTAssertTrue(element(app, "timer").label.contains("∞"))
        let practicePan = app.buttons["pan-1"]
        stock("dumpling", in: 1, app)
        hasValue(practicePan, "Seared")
        practicePan.tap()
        practicePan.tap()
        hasValue(practicePan, "Ready")
        practicePan.tap()
        app.buttons["plate"].tap()
        XCTAssertTrue(app.buttons["replay-shift"].waitForExistence(timeout: 5))
        app.buttons["back-home"].tap()
        app.buttons["open-markets"].tap()
        let earned = app.buttons["shift-tent1"]
        let next = app.buttons["shift-tent2"]
        hasValue(earned, "Patch earned")
        XCTAssertTrue(next.isEnabled)
        XCTAssertFalse(app.buttons["shift-tent3"].isEnabled)
        shot("07-patch-and-unlock-after-relaunch")
        next.tap()
        XCTAssertEqual(app.buttons["ticket-0"].label, "Market Noodles")
        XCTAssertFalse(app.buttons["pan-2"].exists)
    }

    func testBurnDiscardAndRecover() {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, shift: "tent2")
        let fast = app.buttons["pan-1"]
        let slow = app.buttons["pan-0"]
        XCTAssertTrue(fast.waitForExistence(timeout: 5))
        stock("greens", in: 0, app)
        hasValue(slow, "Greens")
        swipe(slow, to: fast)
        hasValue(fast, "Burnt")
        shot("11-burnt-greens-smoke")
        swipe(fast, to: app.buttons["bin"])
        XCTAssertTrue(app.staticTexts["waste"].waitForExistence(timeout: 4))
        let wasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "1"),
                                                object: app.staticTexts["waste"])
        XCTAssertEqual(XCTWaiter.wait(for: [wasted], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["score"].label.contains("0 /"))
        cook("noodles", in: 1, app)
        swipe(fast, to: app.buttons["plate"])
        cook("greens", in: 1, app)
        swipe(fast, to: app.buttons["plate"])
        XCTAssertTrue(app.buttons["ticket-1"].waitForExistence(timeout: 5))
        cook("greens", in: 1, app)
        swipe(fast, to: app.buttons["plate"])
        XCTAssertTrue(app.buttons["ticket-2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["score"].label.contains("2 /"))
        XCTAssertTrue(app.staticTexts["waste"].label.contains("1"))
        shot("12-service-recovered")
    }

    func testLateOrderAndBackground() {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, shift: "lights1")
        let timer = element(app, "timer")
        let slow = app.buttons["pan-0"]
        let medium = app.buttons["pan-2"]
        let plate = app.buttons["plate"]
        XCTAssertTrue(medium.waitForExistence(timeout: 5))
        hasValue(app.buttons["ticket-0"], "Rice → Tofu")
        hasValue(app.buttons["ticket-1"], "Tofu → Rice")
        XCTAssertTrue(element(app, "queue-next").exists)
        shot("21-lantern-opposite-orders")

        cook("tofu", in: 2, twoSides: true, app)
        swipe(medium, to: plate)
        let outOfOrder = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Wrong landing order"),
                                                   object: app.staticTexts["hint"])
        XCTAssertEqual(XCTWaiter.wait(for: [outOfOrder], timeout: 4), .completed)
        XCTAssertTrue(app.staticTexts["waste"].label.contains("1"))
        shot("22-wrong-landing-order")

        stock("rice", in: 0, app)
        cook("tofu", in: 2, twoSides: true, app)
        hasValue(slow, "Ready", timeout: 13)
        motionThrow(slow, to: plate)
        motionThrow(medium, to: plate)
        shot("23-parallel-plating-flights")
        hasValue(timer, "peak-2")
        XCTAssertTrue(app.buttons["ticket-2"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["score"].label.contains("1 /"))
        XCTAssertTrue(app.buttons["ticket-1"].exists)

        app.buttons["ticket-1"].tap()
        cook("tofu", in: 2, twoSides: true, app)
        app.buttons["stock-rice"].tap()
        hasValue(slow, "Rice")
        medium.tap()
        plate.tap()
        XCTAssertTrue((timer.value as? String)?.contains("air-1") == true, "\(timer.value ?? "?")")
        shot("25-tofu-in-air-before-home")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        hasValue(timer, "resume-frozen-1")
        hasValue(app.buttons["ticket-1"], "1 of 2")
        hasValue(slow, "Ready", timeout: 14)
        swipe(slow, to: plate)
        XCTAssertTrue(app.buttons["ticket-3"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["score"].label.contains("2 /"))
        XCTAssertTrue(app.staticTexts["waste"].label.contains("1"))
        shot("24-flight-resumed-second-order-served")
    }

    func testFullCampaignToFreeShift() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["WOK_QA_PROFILE": "campaign-" + UUID().uuidString, "WOK_QA_CAMPAIGN": "1"]
        launch(app)
        let shifts: [(String, Int)] = [
            ("First Dinner", 5), ("Two Fires, One Bowl", 4), ("Steam at the Awning", 5), ("The Awning Queue", 6),
            ("Mushrooms at the Pier", 5), ("Tofu at High Tide", 6), ("Crackle on the Quay", 6), ("Last Ferry Queue", 6),
            ("Ginger in the Rain", 6), ("Rice Under Cover", 6), ("Make It a Double", 6), ("The Late Crossing", 7),
            ("Two Ways to Plate", 6), ("Three on the Rail", 6), ("The Long Streak", 7), ("Lantern Finale", 8)
        ]
        let open = app.buttons["start-shift"]
        XCTAssertTrue(open.waitForExistence(timeout: 6))
        XCTAssertTrue(open.label.contains("Open the kitchen"))
        open.tap()
        var journal: [String] = []
        for (index, shift) in shifts.enumerated() {
            let next = app.buttons["next-shift"]
            XCTAssertTrue(next.waitForExistence(timeout: 38), "Did not clear \(shift.0)")
            XCTAssertTrue(app.staticTexts[shift.0].exists)
            XCTAssertTrue(app.staticTexts["receipt-served"].label.hasSuffix(String(shift.1)))
            XCTAssertEqual(app.staticTexts["receipt-badge"].label, "Patch earned")
            let note = "CAMPAIGN \(index + 1)/16 | \(shift.0) | \(shift.1) served | patch earned"
            print(note)
            journal.append(note)
            if index == 3 { shot("41-red-awning-campaign-receipt") }
            if index == 7 { shot("42-ferry-campaign-receipt") }
            if index == 11 { shot("43-rain-campaign-receipt") }
            if index == 15 {
                XCTAssertTrue(next.label.contains("Free shift"))
                shot("44-finale-campaign-receipt")
            }
            next.tap()
        }
        XCTAssertTrue(app.staticTexts["Free shift"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["pan-2"].exists)
        shot("45-free-shift-unlocked")
        app.terminate()
        launch(app)
        XCTAssertTrue(app.buttons["start-shift"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["start-shift"].label.contains("Free shift"))
        shot("46-campaign-resumed-complete")
        journal.append("CAMPAIGN free shift opened and retained after relaunch.")
        print(journal.last!)
        let attachment = XCTAttachment(string: journal.joined(separator: "\n"))
        attachment.name = "campaign-through-simulator"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func measureLayout(_ app: XCUIApplication, name: String, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        let board = element(app, "kitchen-scene")
        let pan = app.buttons["pan-1"].frame
        let pass = app.buttons["plate"].frame
        let stock = app.buttons["stock-rice"].exists ? app.buttons["stock-rice"].frame : app.buttons["stock-dumpling"].frame
        XCTAssertTrue(board.exists, file: file, line: line)
        let value = (board.value as? String) ?? ""
        if let first = value.components(separatedBy: ";").first,
           let sceneWidth = Double(first.replacingOccurrences(of: "scene ", with: "").components(separatedBy: "×").first ?? "") {
            XCTAssertGreaterThan(sceneWidth, window.width * 0.96, file: file, line: line)
        } else {
            XCTFail("Missing scene geometry: \(value)", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(pan.height, 54, file: file, line: line)
        XCTAssertGreaterThanOrEqual(pan.width, 104, file: file, line: line)
        XCTAssertGreaterThanOrEqual(pass.height, 54, file: file, line: line)
        XCTAssertGreaterThanOrEqual(stock.height, 44, file: file, line: line)
        XCTAssertTrue(window.contains(pan) && window.contains(pass) && window.contains(stock), file: file, line: line)
        XCTAssertFalse(pass.intersects(pan), file: file, line: line)
        print("LAYOUT \(name) | window \(Int(window.width))×\(Int(window.height)) | \(value) | target \(Int(pan.width))×\(Int(pan.height)) | stock \(Int(stock.width))×\(Int(stock.height))")
    }

    func testPadOrientations() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        launch(app, shift: "lights1")
        defer { XCUIDevice.shared.orientation = .portrait }
        let hot = app.buttons["pan-1"]
        let medium = app.buttons["pan-2"]
        let plate = app.buttons["plate"]
        XCTAssertTrue(medium.waitForExistence(timeout: 6))
        measureLayout(app, name: "iPad portrait")
        shot("61-ipad-fullscreen-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 6), .completed)
        measureLayout(app, name: "iPad landscape left")
        stock("rice", in: 1, app)
        swipe(hot, to: medium)
        hasValue(medium, "Ready", timeout: 13)
        shot("62-ipad-fullscreen-landscape-rice")
        swipe(medium, to: plate)
        hasValue(app.buttons["ticket-0"], "1 of 2")

        XCUIDevice.shared.orientation = .landscapeRight
        cook("tofu", in: 1, twoSides: true, app)
        measureLayout(app, name: "iPad landscape right")
        shot("63-ipad-fullscreen-landscape-tofu")
        hot.tap()
        plate.tap()
        XCTAssertTrue(app.buttons["ticket-2"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["score"].label.contains("1 /"))

        XCUIDevice.shared.orientation = .portraitUpsideDown
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.height > frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 6), .completed)
        measureLayout(app, name: "iPad portrait upside down")
        shot("64-ipad-fullscreen-upside-down")
    }

    func testWokSwapSignature() {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, shift: "tent3")
        let hot = app.buttons["pan-1"]
        let low = app.buttons["pan-0"]
        let plate = app.buttons["plate"]
        XCTAssertTrue(hot.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["ticket-0"].label, "Dumpling & Noodles")
        stock("dumpling", in: 1, app)
        hasValue(hot, "Seared")
        flip(hot)
        stock("noodles", in: 0, app)
        hasValue(hot, "Ready")
        swipe(hot, to: plate)
        swipe(low, to: hot)
        hasValue(element(app, "timer"), "peak-2")
        hasValue(hot, "Ready")
        swipe(hot, to: plate)
        XCTAssertTrue(app.buttons["ticket-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["score"].label.contains("1 /"))
        XCTAssertTrue(app.staticTexts["waste"].label.contains("0"))
        shot("51-dumpling-and-noodles-same-ticket")
    }

    func testLocalesAndRecipeOrMarkets() {
        continueAfterFailure = false
        let app = XCUIApplication()
        var index = 1
        for (locale, start, kitchen) in [("zh-Hant", "開張", "第一頓晚餐"),
                                         ("ar", "افتح المطبخ", "العشاء الأول"),
                                         ("en-US", "Open the kitchen", "First Dinner")] {
            launch(app, locale: locale)
            if app.buttons["start-shift"].waitForExistence(timeout: 6) {
                // A prior test may have cleared First Dinner in the standard profile.
                if app.buttons["start-shift"].label.contains(start) {
                    app.buttons["start-shift"].tap()
                } else {
                    app.buttons["open-markets"].tap()
                    app.buttons["market-0"].tap()
                    app.buttons["shift-tent1"].tap()
                }
            }
            XCTAssertTrue(app.staticTexts[kitchen].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["pan-1"].exists)
            shot("3\(index)-locale-\(locale)")
            index += 1
            app.terminate()
        }
    }
}
