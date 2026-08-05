import CObscuraProcess
import Foundation

internal enum PortAllocator {
  static func allocateLoopbackPort() throws -> UInt16 {
    var port: UInt16 = 0
    let error = obscura_allocate_loopback_port(&port)
    guard error == 0, port != 0 else {
      throw ObscuraError.controlPlane("failed to allocate loopback port (errno \(error))")
    }
    return port
  }
}
