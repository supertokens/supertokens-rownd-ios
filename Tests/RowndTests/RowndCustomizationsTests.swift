import Testing
import UIKit

@testable import Rownd

struct RowndCustomizationsTests {
    @Test func defaultFontSizeScalesTwelvePointsExactlyOnce() {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let expected = UIFontMetrics(forTextStyle: .body).scaledValue(for: 12, compatibleWith: traits)
        let actual = RowndCustomizations.scaledDefaultFontSize(compatibleWith: traits)

        #expect(actual == expected)
    }
}
