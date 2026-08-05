import Foundation
import ObscuraCLIArguments
import ObscuraKit

@main
struct ObscuraSwiftCLI {
  static func main() async {
    do {
      switch try CLIArgumentParser.parse(Array(CommandLine.arguments.dropFirst())) {
      case .help:
        printHelp()
      case .doctor(let engine):
        try await doctor(engine: engine)
      case .run(let url, let engine):
        try await run(url: url, engine: engine)
      }
    } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      Foundation.exit(1)
    }
  }

  private static func doctor(engine: CLIEngineSelection) async throws {
    let configuration = try LaunchConfiguration(
      executable: executable(from: engine),
      startupTimeout: .seconds(15),
      operationTimeout: .seconds(15)
    )
    let session = try await BrowserSession.launch(configuration)
    do {
      let html = "<title>ObscuraKit Doctor</title><div id='probe'>ready</div>"
      let payload = Data(html.utf8).base64EncodedString()
      guard let url = URL(string: "data:text/html;base64,\(payload)") else {
        throw CLIError("failed to construct doctor data URL")
      }
      _ = try await session.navigate(to: url, waitUntil: .load)
      let title = try await session.title()
      let selector = try CSSSelector("#probe")
      let text = try await session.locator(selector).textContent()
      guard title == "ObscuraKit Doctor", text == "ready" else {
        throw CLIError("runtime semantic check failed")
      }
      await session.close()
      try printJSON(DoctorOutput(status: "ok", title: title, text: text))
    } catch {
      await session.close()
      throw error
    }
  }

  private static func run(url: URL, engine: CLIEngineSelection) async throws {
    let configuration = try LaunchConfiguration(executable: executable(from: engine))
    let session = try await BrowserSession.launch(configuration)
    do {
      let result = try await session.navigate(to: url)
      let title = try await session.title()
      await session.close()
      try printJSON(
        RunOutput(url: result.url.absoluteString, title: title, generation: result.generation))
    } catch {
      await session.close()
      throw error
    }
  }

  private static func executable(from selection: CLIEngineSelection) -> EngineExecutable {
    switch selection {
    case .explicitExecutable(let path):
      .explicit(URL(fileURLWithPath: path))
    case .chromeExecutable(let path):
      .chrome(executable: URL(fileURLWithPath: path))
    case .repositoryRoot(let path):
      .vendored(
        repositoryRoot: URL(
          fileURLWithPath: path ?? FileManager.default.currentDirectoryPath,
          isDirectory: true))
    }
  }

  private static func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
  }

  private static func printHelp() {
    print(
      """
      usage:
        obscura-swift doctor [--engine PATH | --repository-root PATH | --chrome PATH]
        obscura-swift run URL [--engine PATH | --repository-root PATH | --chrome PATH]
      """)
  }
}

private struct DoctorOutput: Encodable {
  let status: String
  let title: String
  let text: String?
}

private struct RunOutput: Encodable {
  let url: String
  let title: String
  let generation: UInt64
}

private struct CLIError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
