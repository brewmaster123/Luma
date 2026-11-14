import Foundation
import XCTest

/// Exercises the real SwiftUI controls on a fresh iOS simulator.
/// No screenshot model is injected, and no AlarmKit consent or scheduling is performed.
final class ReferenceNightUITests: XCTestCase {
  private let helpPreference = "com.sevchlenko.luma.indirectMethod.skipStartHelp.v1"
  private let signalConsentPreference = "luma.alarmkit.night-audio-stop.v3"

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(resetHelpForThisLaunch: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    // This flag stops only decorative animation, allowing XCTest quiescence.
    // The app's ordinary model, archive, navigation and interaction paths are used.
    app.launchArguments = ["-reference-ui-test", "-" + signalConsentPreference, "NO"]
    if resetHelpForThisLaunch {
      // Argument-domain override: do not erase the archive or other preferences.
      // A later launch without it exposes the persisted opt-out written by Continue.
      app.launchArguments += ["-" + helpPreference, "NO"]
    }
    app.launch()
    XCTAssertTrue(app.buttons["indirect.start"].waitForExistence(timeout: 15))
    return app
  }

  @MainActor
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    XCTAssertTrue(element.waitForExistence(timeout: 10))
    for _ in 0..<10 {
      if element.isHittable { return }
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable, "Element exists but could not be reached: \(element)")
  }

  @MainActor
  private func tap(_ element: XCUIElement, in app: XCUIApplication) {
    reveal(element, in: app)
    element.tap()
  }

  @MainActor
  private func expectInterval(_ minutes: Int, in app: XCUIApplication) {
    let element = app.buttons["indirect.interval"]
    let predicate = NSPredicate(format: "label == %@", "Интервал \(minutes) минут")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
  }

  @MainActor
  private func selectInterval(_ minutes: Int, in app: XCUIApplication) {
    tap(app.buttons["indirect.interval"], in: app)
    let wheel = app.pickerWheels.firstMatch
    XCTAssertTrue(wheel.waitForExistence(timeout: 8))
    wheel.adjust(toPickerWheelValue: "\(minutes) мин")
    tap(app.buttons["indirect.save"], in: app)
    expectInterval(minutes, in: app)
  }

  @MainActor
  private func helpChoice(in app: XCUIApplication) -> XCUIElement {
    // A custom checkbox can be represented as a Toggle or a Button by SwiftUI.
    app.descendants(matching: .any).matching(identifier: "indirect.help.skip").firstMatch
  }

  @MainActor
  private func expectNotRunning(_ app: XCUIApplication) {
    let start = app.buttons["indirect.start"]
    XCTAssertTrue(start.waitForExistence(timeout: 8))
    XCTAssertTrue(start.label.contains("Начать сеанс"))
    XCTAssertFalse(start.label.contains("Завершить сеанс"))
    XCTAssertFalse(app.staticTexts["Следующий сигнал через"].exists)
  }

  @MainActor
  private func cancelReadiness(in app: XCUIApplication) {
    // Do not press signal.continue: it is the actual system-permission/start path.
    XCTAssertTrue(app.staticTexts["AlarmKit · короткий сигнал"].waitForExistence(timeout: 10))
    tap(app.buttons["Закрыть"].firstMatch, in: app)
    expectNotRunning(app)
  }

  @MainActor
  func testColdLaunchOpensNightWithoutWelcome() throws {
    let app = launch()
    defer { app.terminate() }
    XCTAssertFalse(app.buttons["Начать знакомство"].exists)
    XCTAssertFalse(app.staticTexts["Доброй ночи.\nЭто Luma."].exists)
    XCTAssertTrue(app.buttons["indirect.start"].isHittable)
    XCTAssertTrue(app.buttons["reference.tab.Ночь"].exists)
    XCTAssertTrue(app.buttons["reference.tab.Дневник"].exists)
    XCTAssertTrue(app.buttons["reference.tab.Настройки"].exists)
    XCTAssertFalse(app.buttons["indirect.help.continue"].exists)
    expectNotRunning(app)
  }

  @MainActor
  func testIconNavigationUsesExistingJournalAndSettings() throws {
    let app = launch()
    defer { app.terminate() }
    tap(app.buttons["reference.tab.Дневник"], in: app)
    XCTAssertTrue(app.staticTexts["Сохраните то, что хочется запомнить."].waitForExistence(timeout: 8))
    tap(app.buttons["reference.tab.Настройки"], in: app)
    XCTAssertTrue(app.staticTexts["Ваша ночь, ваш ритм."].waitForExistence(timeout: 8))
    tap(app.buttons["reference.tab.Ночь"], in: app)
    XCTAssertTrue(app.buttons["indirect.start"].waitForExistence(timeout: 8))
    expectNotRunning(app)
  }

  @MainActor
  func testIntervalControlsPersistSelectionAndRespectBounds() throws {
    let app = launch()
    defer { app.terminate() }
    selectInterval(30, in: app)
    tap(app.buttons["indirect.increase"], in: app)
    expectInterval(31, in: app)
    tap(app.buttons["indirect.decrease"], in: app)
    expectInterval(30, in: app)

    selectInterval(10, in: app)
    XCTAssertFalse(app.buttons["indirect.decrease"].isEnabled)
    XCTAssertTrue(app.buttons["indirect.increase"].isEnabled)
    selectInterval(60, in: app)
    XCTAssertFalse(app.buttons["indirect.increase"].isEnabled)
    XCTAssertTrue(app.buttons["indirect.decrease"].isEnabled)

    app.terminate()
    app.launch()
    expectInterval(60, in: app)
  }

  @MainActor
  func testAlarmHeadingHelpAndAddAreIndependent() throws {
    let app = launch()
    defer { app.terminate() }
    tap(app.buttons["alarm.help"], in: app)
    let explanation = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Будильник через AlarmKit.")
    ).firstMatch
    XCTAssertTrue(explanation.waitForExistence(timeout: 8))
    XCTAssertFalse(app.navigationBars["Будильник"].exists)
    tap(app.buttons["Закрыть справку"], in: app)

    tap(app.buttons["alarm.add"], in: app)
    XCTAssertTrue(app.navigationBars["Будильник"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.textFields.firstMatch.exists)
    // The editor also contains this same reused explanation; distinguish the actual surfaces.
    XCTAssertFalse(app.buttons["Закрыть справку"].exists)
    tap(app.navigationBars["Будильник"].buttons["Отмена"], in: app)
    expectNotRunning(app)
  }

  @MainActor
  func testCancelHelpDoesNotStartAndHelpIsShownAgain() throws {
    let app = launch()
    defer { app.terminate() }
    tap(app.buttons["indirect.start"], in: app)
    XCTAssertTrue(helpChoice(in: app).waitForExistence(timeout: 8))
    tap(app.buttons["indirect.help.cancel"], in: app)
    expectNotRunning(app)
    XCTAssertFalse(app.staticTexts["AlarmKit · короткий сигнал"].exists)

    tap(app.buttons["indirect.start"], in: app)
    XCTAssertTrue(helpChoice(in: app).waitForExistence(timeout: 8))
    tap(app.buttons["indirect.help.cancel"], in: app)
    expectNotRunning(app)
  }

  @MainActor
  func testContinueWithoutOptOutShowsHelpOnNextAttempt() throws {
    let app = launch()
    defer { app.terminate() }
    tap(app.buttons["indirect.start"], in: app)
    XCTAssertTrue(helpChoice(in: app).waitForExistence(timeout: 8))
    tap(app.buttons["indirect.help.continue"], in: app)
    cancelReadiness(in: app)
    tap(app.buttons["indirect.start"], in: app)
    XCTAssertTrue(helpChoice(in: app).waitForExistence(timeout: 8))
    tap(app.buttons["indirect.help.cancel"], in: app)
    expectNotRunning(app)
  }

  @MainActor
  func testOptOutPersistsButDoesNotBypassSignalReadiness() throws {
    var app = launch()
    defer { app.terminate() }
    tap(app.buttons["indirect.start"], in: app)
    let choice = helpChoice(in: app)
    tap(choice, in: app)
    tap(app.buttons["indirect.help.continue"], in: app)
    cancelReadiness(in: app)

    app.terminate()
    // Remove the test's help override, but keep real signal consent explicitly false.
    app = launch(resetHelpForThisLaunch: false)
    tap(app.buttons["indirect.start"], in: app)
    XCTAssertTrue(app.staticTexts["AlarmKit · короткий сигнал"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["indirect.help.continue"].exists)
    XCTAssertFalse(helpChoice(in: app).exists)
    cancelReadiness(in: app)
  }
}
