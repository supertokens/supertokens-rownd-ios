import Testing

@testable import Rownd

struct HubWebsiteDataCleanerTests {
    @Test func matchesHubHostAndManagedParentDomainRecords() {
        #expect(HubWebsiteDataCleaner.recordDisplayName(
            "rownd-hub.supertokens.com",
            matchesHost: "rownd-hub.supertokens.com"
        ))
        #expect(HubWebsiteDataCleaner.recordDisplayName(
            "supertokens.com",
            matchesHost: "rownd-hub.supertokens.com"
        ))
        #expect(HubWebsiteDataCleaner.recordDisplayName(
            "rownd-hub.supertokens.com",
            matchesHost: "tenant.rownd-hub.supertokens.com"
        ))
        #expect(HubWebsiteDataCleaner.recordDisplayName(
            ".ROWND-HUB.SUPERTOKENS.COM.",
            matchesHost: "rownd-hub.supertokens.com"
        ))
    }

    @Test func matchesIOHubHostAndManagedParentDomainRecords() {
        #expect(HubWebsiteDataCleaner.recordDisplayName(
            "rownd-hub.supertokens.io",
            matchesHost: "rownd-hub.supertokens.io"
        ))
        #expect(HubWebsiteDataCleaner.recordDisplayName(
            "supertokens.io",
            matchesHost: "rownd-hub.supertokens.io"
        ))
        #expect(HubWebsiteDataCleaner.recordDisplayName(
            "rownd-hub.supertokens.io",
            matchesHost: "tenant.rownd-hub.supertokens.io"
        ))
        #expect(HubWebsiteDataCleaner.recordDisplayName(
            "supertokens.io",
            matchesHost: "tenant.rownd-hub.supertokens.io"
        ))
    }

    @Test func rejectsUnrelatedAndLookalikeIODomains() {
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "example.io",
            matchesHost: "rownd-hub.supertokens.io"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "supertokens.com",
            matchesHost: "rownd-hub.supertokens.io"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "supertokens.io",
            matchesHost: "notsupertokens.io"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "rownd-hub.supertokens.io",
            matchesHost: "notrownd-hub.supertokens.io"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "supertokens.io",
            matchesHost: "rownd-hub.supertokens.io.example.com"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "example.io",
            matchesHost: "hub.example.io"
        ))
    }

    @Test func rejectsUnrelatedAndLookalikeDomains() {
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "example.com",
            matchesHost: "rownd-hub.supertokens.com"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "notsupertokens.com",
            matchesHost: "rownd-hub.supertokens.com"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "login.rownd-hub.supertokens.com",
            matchesHost: "rownd-hub.supertokens.com"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "com",
            matchesHost: "rownd-hub.supertokens.com"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "co.uk",
            matchesHost: "hub.example.co.uk"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "github.io",
            matchesHost: "tenant.github.io"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "pages.dev",
            matchesHost: "tenant.pages.dev"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "example.com",
            matchesHost: "hub.example.com"
        ))
        #expect(!HubWebsiteDataCleaner.recordDisplayName(
            "",
            matchesHost: "rownd-hub.supertokens.com"
        ))
    }
}
