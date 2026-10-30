import Foundation
import PrismCore
import Testing

@Suite struct WebIntentTests {
    @Test func acceptsOnlyHTTPAddressesWithAHostAndNoCredentials() {
        #expect(WebIntent("https://example.com/docs?q=prism#readme") == .url(URL(string: "https://example.com/docs?q=prism#readme")!))
        #expect(WebIntent("http://localhost:3000") != nil)
        #expect(WebIntent("file:///tmp/prism") == nil)
        #expect(WebIntent("https:///missing-host") == nil)
        #expect(WebIntent("https:\\example.com") == nil)
        #expect(WebIntent("https://user:pass@example.com") == nil)
        #expect(WebIntent("https://example.com/a b") == nil)
        #expect(WebIntent("https://example.com/@me") != nil)
        #expect(WebIntent("example.com") == nil)
    }

    @Test func searchesNeedTheWebPrefix() {
        #expect(WebIntent("web 서울 날씨") == .search("서울 날씨"))
        #expect(WebIntent("WEB swift") == .search("swift"))
        #expect(WebIntent("web ") == nil)
        #expect(WebIntent("weather") == nil)
    }

    @Test func searchAddressEncodesTheQuery() {
        #expect(WebIntent.searchURL("c++ & swift")?.absoluteString == "https://www.google.com/search?q=c%2B%2B%20%26%20swift")
        #expect(WebIntent.searchURL(String(repeating: "a", count: 1_025)) == nil)
    }
}
