import XCTest
@testable import ECAI

final class ECAITests: XCTestCase {
    func testECAIStartsInExplicitStubModeUntilConfigured() {
        XCTAssertNil(AppConfig.ecaiBaseURL)
    }

    func testStubAuthRejectsEmptyCredentials() async {
        do {
            _ = try await StubECAIAuthService().login(identifier: "", password: "")
            XCTFail("Expected invalid credentials")
        } catch {
            XCTAssertNotNil(error as? APIError)
        }
    }
}
