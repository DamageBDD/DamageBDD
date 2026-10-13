import XCTest
@testable import DamageBDD

final class DamageBDDTests: XCTestCase {
    func testDamageBaseURLUsesHTTPS() {
        XCTAssertEqual(AppConfig.damageBaseURL.scheme, "https")
    }

    func testDamageAndECAIUseDifferentDefaultBundleIdentifiers() {
        XCTAssertNotEqual("com.damagebdd.mobile", "com.ecai.mobile")
    }
}
