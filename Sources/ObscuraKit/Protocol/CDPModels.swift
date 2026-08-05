import Foundation

internal struct CDPRequest: Encodable, Sendable {
  let id: Int
  let method: String
  let params: JSONValue
  let sessionID: String?

  enum CodingKeys: String, CodingKey {
    case id, method, params
    case sessionID = "sessionId"
  }

  init(id: Int, method: String, params: JSONValue, sessionID: String? = nil) {
    self.id = id
    self.method = method
    self.params = params
    self.sessionID = sessionID
  }
}

internal struct CDPErrorBody: Decodable, Sendable, Equatable {
  let code: Int
  let message: String
}

internal struct CDPInbound: Decodable, Sendable {
  let id: Int?
  let method: String?
  let params: JSONValue?
  let result: JSONValue?
  let error: CDPErrorBody?
  let sessionId: String?
}
