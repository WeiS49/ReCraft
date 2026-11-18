import AppKit
import XCTest
@testable import ReCraft

@MainActor
final class TaskOnlyHostIsolationTests: XCTestCase {
    func testNormalAppAndBenchmarkOptInsDoNotSelectHostIsolation() {
        XCTAssertFalse(AppDelegate.isUnitTestHost(environment: [:]))
        XCTAssertFalse(AppDelegate.isUnitTestHost(environment: [
            "RECRAFT_PROMPT_GATE_MODE": "preflight",
            "RECRAFT_PROMPT_V2_MODE": "live-once",
            "XCODE_SCHEME_NAME": "ReCraft",
        ]))

        let xctestEnvironment = [
            "XCTestConfigurationFilePath": "/private/tmp/synthetic.xctestconfiguration",
        ]
        #if DEBUG
        XCTAssertTrue(AppDelegate.isUnitTestHost(environment: xctestEnvironment))
        #else
        XCTAssertFalse(AppDelegate.isUnitTestHost(environment: xctestEnvironment))
        #endif
    }

    func testDebugHostedLifecycleLeavesConfigurationAndRuntimeUnstarted() async throws {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            XCTFail("debug-test-host-missing-xctest-configuration-marker")
            return
        }

        // Construction must not load the production catalog or read Keychain.
        // Exercise only the suppressed lifecycle, never a normal App launch.
        let delegate = AppDelegate()
        XCTAssertTrue(delegate.isRunningUnitTests)
        XCTAssertNil(delegate.taskSettings.persistedCatalog)
        XCTAssertNil(delegate.taskSettings.draftCatalog)
        XCTAssertNil(delegate.taskSettings.onRuntimeStateChange)
        XCTAssertTrue(delegate.taskSettings.activeDisplayTasks.isEmpty)

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        await Task.yield()
        XCTAssertEqual(delegate.coordinator.statusMessage, "Starting…")
        XCTAssertEqual(delegate.coordinator.phase, .idle)
        XCTAssertFalse(delegate.coordinator.accessibilityGranted)
        XCTAssertNil(delegate.coordinator.hotKeyRegistrationError)
        XCTAssertNil(delegate.apiKeySettings.statusMessage)
        XCTAssertFalse(delegate.apiKeySettings.isConfigured)
        XCTAssertNil(delegate.taskSettings.persistedCatalog)
        XCTAssertNil(delegate.taskSettings.onRuntimeStateChange)

        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        XCTAssertEqual(delegate.coordinator.statusMessage, "Starting…")
        #else
        throw XCTSkip("debug-host-isolation-check-only")
        #endif
    }
}
