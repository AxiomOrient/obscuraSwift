import Foundation

package enum CLIEngineSelection: Sendable, Equatable {
  case repositoryRoot(String?)
  case explicitExecutable(String)
  case chromeExecutable(String)
}

package enum CLICommand: Sendable, Equatable {
  case help
  case doctor(engine: CLIEngineSelection)
  case run(url: URL, engine: CLIEngineSelection)
}

package struct CLIArgumentError: Error, Sendable, Equatable, CustomStringConvertible {
  package let description: String

  package init(_ description: String) {
    self.description = description
  }
}

package enum CLIArgumentParser {
  package static func parse(_ arguments: [String]) throws -> CLICommand {
    guard let command = arguments.first else { return .help }
    let tail = Array(arguments.dropFirst())

    switch command {
    case "help", "--help", "-h":
      guard tail.isEmpty else {
        throw CLIArgumentError("help does not accept arguments")
      }
      return .help

    case "doctor":
      let parsed = try parseTail(tail, positionalCount: 0)
      return .doctor(engine: parsed.engine)

    case "run":
      let parsed = try parseTail(tail, positionalCount: 1)
      let rawURL = parsed.positionals[0]
      guard let url = URL(string: rawURL), let scheme = url.scheme, !scheme.isEmpty else {
        throw CLIArgumentError("run requires one absolute URL")
      }
      return .run(url: url, engine: parsed.engine)

    default:
      throw CLIArgumentError("unknown command: \(command)")
    }
  }

  private static func parseTail(
    _ arguments: [String],
    positionalCount: Int
  ) throws -> (positionals: [String], engine: CLIEngineSelection) {
    var positionals: [String] = []
    var engine: CLIEngineSelection = .repositoryRoot(nil)
    var hasEngineOption = false
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--engine", "--repository-root", "--chrome":
        guard !hasEngineOption else {
          throw CLIArgumentError("choose exactly one engine source option")
        }
        guard index + 1 < arguments.count else {
          throw CLIArgumentError("\(argument) requires a path")
        }
        let path = arguments[index + 1]
        guard !path.isEmpty, !path.hasPrefix("--") else {
          throw CLIArgumentError("\(argument) requires a path")
        }
        switch argument {
        case "--engine":
          engine = .explicitExecutable(path)
        case "--repository-root":
          engine = .repositoryRoot(path)
        case "--chrome":
          engine = .chromeExecutable(path)
        default:
          fatalError("handled engine option is missing a selection")
        }
        hasEngineOption = true
        index += 2

      default:
        if argument.hasPrefix("-") {
          throw CLIArgumentError("unknown option: \(argument)")
        }
        positionals.append(argument)
        index += 1
      }
    }

    guard positionals.count == positionalCount else {
      if positionalCount == 0 {
        throw CLIArgumentError("command does not accept positional arguments")
      }
      throw CLIArgumentError("run requires exactly one absolute URL")
    }
    return (positionals, engine)
  }
}
