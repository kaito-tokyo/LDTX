import XCTest
@testable import LDTXFullAppFeatures

@MainActor
final class FeatureProviderTests: XCTestCase {
    func testFullProviderEnablesVision() {
        XCTAssertTrue(FullAppFeatureProvider().configuration.uiFeatures.contains(.vision))
    }
}
