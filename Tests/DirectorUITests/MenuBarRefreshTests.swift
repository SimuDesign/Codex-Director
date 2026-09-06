import Foundation
import XCTest
import SwiftUI
import DirectorCore
@testable import DirectorUI

@MainActor
final class MenuBarRefreshTests: XCTestCase {
    func testFailedAccountReadWithoutSnapshotRemainsUnavailable() async {
        let stores = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            menuBarPreferences: MenuBarPreferences(memoryEnabled: true)
        )

        let outcome = await model.refreshMenuBarIfNeeded()

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(model.menuBarPresentation.state, .failed)
        XCTAssertEqual(model.menuBarPresentation.primaryValue, "—")
        XCTAssertFalse(model.menuBarPresentation.usesCachedValue)
    }

    func testDefaultEnabledConstructionDoesNotStartAccountRead() async throws {
        let stores = TestMemoryPreferences.makeStores()
        let calls = CallCounter()
        let response = try JSONSerialization.data(withJSONObject: ["result": [:]])
        let reading = CodexAccountUsageReading(
            transport: { _, _, _, _ in
                await calls.increment()
                return response
            },
            executableURL: URL(fileURLWithPath: "/synthetic/codex")
        )

        let model = DirectorAppModel(
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            menuBarPreferences: MenuBarPreferences(memoryEnabled: true),
            accountUsageReading: reading
        )

        XCTAssertTrue(model.menuBarEnabled)
        _ = model.menuBarPresentation
        let readCount = await calls.value()
        XCTAssertEqual(readCount, 0)
    }

    func testSnapshotWithoutWeeklyAllowanceRetriesOnNextPopoverRefresh() async throws {
        let stores = TestMemoryPreferences.makeStores()
        let calls = CallCounter()
        let response = try JSONSerialization.data(withJSONObject: [
            "id": 2,
            "result": [
                "rateLimits": ["primary": ["usedPercent": 12, "windowDurationMins": 60]]
            ]
        ])
        let reading = CodexAccountUsageReading(
            transport: { _, _, _, _ in
                await calls.increment()
                return response
            },
            executableURL: URL(fileURLWithPath: "/synthetic/codex"),
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )
        let model = DirectorAppModel(
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            menuBarPreferences: MenuBarPreferences(memoryEnabled: true),
            accountUsageReading: reading
        )

        let firstOutcome = await model.refreshMenuBarIfNeeded()
        XCTAssertEqual(firstOutcome, .completed)
        XCTAssertNil(model.accountUsageSnapshot?.weeklyRemainingPercent)
        XCTAssertEqual(model.menuBarPresentation.primaryValue, "—")
        XCTAssertEqual(model.accountUsageError, "account_usage_incomplete")
        XCTAssertEqual(model.menuBarPresentation.state, .failed)
        XCTAssertFalse(model.menuBarPresentation.usesCachedValue)

        let secondOutcome = await model.refreshMenuBarIfNeeded()
        let readCount = await calls.value()
        XCTAssertEqual(secondOutcome, .completed)
        XCTAssertEqual(readCount, 2)
    }

    /// Runtime seam for the app's Scene binding: both Settings and
    /// MenuBarExtra must read the same observable store without rebuilding the
    /// model. This is the failure mode of the shipped 0.6.0 wiring, where a
    /// nested model change did not invalidate the App scene.
    func testSettingsToggleUpdatesLiveMenuBarInsertionBinding() {
        let preferences = MenuBarPreferences(memoryEnabled: true)
        let model = DirectorAppModel(menuBarPreferences: preferences)
        let insertionBinding = MenuBarInsertionBinding.make(preferences: preferences, model: model)

        XCTAssertTrue(insertionBinding.wrappedValue)
        model.setMenuBarEnabled(false)
        XCTAssertFalse(insertionBinding.wrappedValue)
        XCTAssertFalse(model.menuBarEnabled)

        insertionBinding.wrappedValue = true
        XCTAssertTrue(preferences.isEnabled)
        XCTAssertTrue(model.menuBarEnabled)
    }

    func testSharedAppPreferenceSynchronizesBindingsAcrossWindows() {
        let preferences = MenuBarPreferences(memoryEnabled: true)
        let firstWindowModel = DirectorAppModel(menuBarPreferences: preferences)
        let secondWindowModel = DirectorAppModel(menuBarPreferences: preferences)
        let firstInsertion = MenuBarInsertionBinding.make(preferences: preferences, model: firstWindowModel)
        let secondInsertion = MenuBarInsertionBinding.make(preferences: preferences, model: secondWindowModel)

        firstInsertion.wrappedValue = false
        XCTAssertFalse(secondInsertion.wrappedValue)
        XCTAssertFalse(secondWindowModel.menuBarEnabled)
        secondInsertion.wrappedValue = true
        XCTAssertTrue(firstInsertion.wrappedValue)
        XCTAssertTrue(firstWindowModel.menuBarEnabled)
    }
}

private actor CallCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}
