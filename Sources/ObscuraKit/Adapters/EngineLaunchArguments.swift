import Foundation

internal enum EngineLaunchArguments {
  static func obscura(
    port: UInt16,
    configuration: LaunchConfiguration
  ) -> [String] {
    var arguments = [
      "serve", "--host", "127.0.0.1", "--port", String(port), "--workers", "1",
      "--max-connections", "1", "--quiet",
    ]
    if configuration.stealth { arguments.insert("--stealth", at: 0) }
    if configuration.allowPrivateNetwork { arguments.insert("--allow-private-network", at: 0) }
    if let userAgent = configuration.userAgent { arguments += ["--user-agent", userAgent] }
    return arguments
  }

  static func chrome(
    port: UInt16,
    profileDirectory: URL,
    configuration: LaunchConfiguration
  ) -> [String] {
    var arguments = [
      "--headless=new",
      "--remote-debugging-address=127.0.0.1",
      "--remote-debugging-port=\(port)",
      "--user-data-dir=\(profileDirectory.path)",
      "--no-first-run",
      "--no-default-browser-check",
      "about:blank",
    ]
    if let proxy = configuration.proxy { arguments.append("--proxy-server=\(proxy)") }
    if let userAgent = configuration.userAgent { arguments.append("--user-agent=\(userAgent)") }
    return arguments
  }
}
