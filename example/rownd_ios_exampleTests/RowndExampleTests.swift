import XCTest
import Rownd

final class RowndExampleTests: XCTestCase {
    func testSuperTokensConfigDefaultsToAuthBasePath() {
        let config = RowndSuperTokensConfig(
            appName: "Example App",
            apiDomain: "https://api.example.com"
        )

        XCTAssertEqual(config.appName, "Example App")
        XCTAssertEqual(config.apiDomain, "https://api.example.com")
        XCTAssertEqual(config.apiBasePath, "/auth")
    }
}
