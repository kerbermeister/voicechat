import Foundation

/// Flutter supplies a route from its verified catalog; Sparkle keeps its own
/// embedded signing key and verifies the unchanged feed and archive bytes.
struct MacUpdateRoute {
  private let canonical: URLComponents
  private let selected: URLComponents
  let feedURL: URL

  init?(feed: URL, canonicalOrigin: String, selectedOrigin: String) {
    guard let canonical = Self.origin(canonicalOrigin),
          let selected = Self.origin(selectedOrigin),
          let source = URLComponents(url: feed, resolvingAgainstBaseURL: false),
          Self.sameOrigin(source, canonical),
          source.percentEncodedPath == "/updates/macos/appcast.xml",
          source.query == nil, source.fragment == nil else { return nil }
    self.canonical = canonical
    self.selected = selected
    var routed = source
    routed.host = selected.host
    routed.port = selected.port
    guard let url = routed.url else { return nil }
    self.feedURL = url
  }

  func rewrite(_ url: URL) -> URL? {
    guard var source = URLComponents(url: url, resolvingAgainstBaseURL: false),
          Self.sameOrigin(source, canonical), source.query == nil, source.fragment == nil,
          source.percentEncodedPath.range(of: "^/updates/macos/[1-9][0-9]*/VoiceChat\\.zip$", options: .regularExpression) != nil
    else { return nil }
    source.host = selected.host
    source.port = selected.port
    return source.url
  }

  private static func origin(_ value: String) -> URLComponents? {
    guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
          let url = URLComponents(string: value), url.scheme == "https",
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil,
          ["", "/"].contains(url.percentEncodedPath),
          (1...65535).contains(url.port ?? 443) else { return nil }
    return url
  }

  private static func sameOrigin(_ value: URLComponents, _ expected: URLComponents) -> Bool {
    value.scheme == "https" && value.host?.lowercased() == expected.host?.lowercased() &&
      (value.port ?? 443) == (expected.port ?? 443) && value.user == nil && value.password == nil
  }
}
