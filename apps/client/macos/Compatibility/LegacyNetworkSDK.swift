import Network

// shortcut: Xcode 16 cannot name NWPath.isUltraConstrained (SDK 26).
// Remove when the minimum build toolchain becomes Xcode 26. This file is added
// only with SDK <26; ordinary Wi-Fi/Ethernet/offline reporting stays unchanged.
// Builds made with the older SDK cannot distinguish satellite connectivity.
extension NWPath {
  var isUltraConstrained: Bool { false }
}
