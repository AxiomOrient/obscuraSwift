import Foundation

internal protocol WebSocketTransport: Sendable {
  func connect() async throws
  func send(text: String) async throws
  func receive() async throws -> String
  func close() async
}
