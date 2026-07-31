import XCTest
@testable import LDTXAppCore

final class AppFeatureProviderTests: XCTestCase {
  @MainActor
  func testTinyConfigurationIsAIFree() {
    let configuration = TinyAppFeatureProvider().configuration
    XCTAssertTrue(configuration.uiFeatures.isEmpty)
    XCTAssertFalse(TinyAppFeatureProvider().workspaceFeatureAvailability.supportsVision)
    XCTAssertNil(TinyAppFeatureProvider().backgroundRemovalPreprocessorFactory)
  }
}
