import XCTest
import MoonshineCore
@testable import MoonshinePlatform

final class ActivationCancellationTests: XCTestCase {
    func testCancelledNativeWindowOperationStopsBeforePermissionOrTargetLookup() async {
        let windows = WindowInventory()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await windows.activate(.unavailable)
        }
        do { try await operation.value; XCTFail("Cancelled operation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancelledChromeOperationStopsBeforeTargetLookupOrScriptDispatch() async {
        let chrome = ChromeAdapter()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await chrome.activate(.unavailable)
        }
        do { try await operation.value; XCTFail("Cancelled operation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
