import Testing

@testable import Domain

@Test
func domainPlaceholderReportsItsLayer() {
    #expect(DomainPlaceholder.layer == "Domain")
}
