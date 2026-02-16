import XCTest
@testable import SpeechDock

@MainActor
final class PermissionServiceTests: XCTestCase {

    // MARK: - Computed Properties

    func testAllRequiredGrantedDependsOnMicrophone() {
        let service = PermissionService.shared
        // allRequiredGranted should equal microphoneGranted
        XCTAssertEqual(service.allRequiredGranted, service.microphoneGranted,
            "allRequiredGranted should match microphoneGranted")
    }

    func testAllGrantedRequiresAllThree() {
        let service = PermissionService.shared
        if service.microphoneGranted && service.accessibilityGranted && service.screenRecordingGranted {
            XCTAssertTrue(service.allGranted)
        } else {
            XCTAssertFalse(service.allGranted)
        }
    }

    func testHasAnyMissingIsInverseOfAllGranted() {
        let service = PermissionService.shared
        XCTAssertEqual(service.hasAnyMissing, !service.allGranted,
            "hasAnyMissing should be the inverse of allGranted")
    }

    // MARK: - Refresh

    func testRefreshAllPermissionsDoesNotCrash() {
        let service = PermissionService.shared
        // Simply verify that refreshAllPermissions can be called without crashing
        service.refreshAllPermissions()
        // Verify properties are accessible after refresh
        _ = service.microphoneGranted
        _ = service.accessibilityGranted
        _ = service.screenRecordingGranted
    }

    // MARK: - Monitoring Lifecycle

    func testStartMonitoringSetsFlag() {
        let service = PermissionService.shared
        let wasMonitoring = service.isMonitoring

        service.startMonitoring()
        XCTAssertTrue(service.isMonitoring, "isMonitoring should be true after startMonitoring")

        service.stopMonitoring()
        XCTAssertFalse(service.isMonitoring, "isMonitoring should be false after stopMonitoring")

        // Restore original state
        if wasMonitoring {
            service.startMonitoring()
        }
    }

    func testStartMonitoringIsIdempotent() {
        let service = PermissionService.shared

        service.startMonitoring()
        service.startMonitoring() // calling again should not crash or create duplicate tasks

        XCTAssertTrue(service.isMonitoring)

        service.stopMonitoring()
    }

    func testStopMonitoringIsIdempotent() {
        let service = PermissionService.shared

        service.stopMonitoring()
        service.stopMonitoring() // calling again should not crash

        XCTAssertFalse(service.isMonitoring)
    }

    // MARK: - Permission State Consistency

    func testPermissionStatesAreConsistent() {
        let service = PermissionService.shared
        service.refreshAllPermissions()

        // If all granted, none should be missing
        if service.allGranted {
            XCTAssertTrue(service.microphoneGranted)
            XCTAssertTrue(service.accessibilityGranted)
            XCTAssertTrue(service.screenRecordingGranted)
            XCTAssertFalse(service.hasAnyMissing)
        }

        // If microphone is granted, allRequiredGranted should be true
        if service.microphoneGranted {
            XCTAssertTrue(service.allRequiredGranted)
        }
    }
}
