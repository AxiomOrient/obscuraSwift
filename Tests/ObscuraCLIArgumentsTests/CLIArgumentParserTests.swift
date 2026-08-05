import Foundation
import XCTest

@testable import ObscuraCLIArguments

final class CLIArgumentParserTests: XCTestCase {
  func testDefaultsToHelp() throws {
    XCTAssertEqual(try CLIArgumentParser.parse([]), .help)
    XCTAssertEqual(try CLIArgumentParser.parse(["help"]), .help)
  }

  func testDoctorParsesExactlyOneEngineSource() throws {
    XCTAssertEqual(
      try CLIArgumentParser.parse(["doctor"]),
      .doctor(engine: .repositoryRoot(nil)))
    XCTAssertEqual(
      try CLIArgumentParser.parse(["doctor", "--engine", "/tmp/obscura"]),
      .doctor(engine: .explicitExecutable("/tmp/obscura")))
    XCTAssertEqual(
      try CLIArgumentParser.parse(["doctor", "--repository-root", "/repo"]),
      .doctor(engine: .repositoryRoot("/repo")))
    XCTAssertEqual(
      try CLIArgumentParser.parse(["doctor", "--chrome", "/Applications/Google Chrome"]),
      .doctor(engine: .chromeExecutable("/Applications/Google Chrome")))
  }

  func testRunAcceptsOptionsBeforeOrAfterOneAbsoluteURL() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/path"))
    XCTAssertEqual(
      try CLIArgumentParser.parse(["run", "https://example.com/path", "--engine", "/engine"]),
      .run(url: url, engine: .explicitExecutable("/engine")))
    XCTAssertEqual(
      try CLIArgumentParser.parse(["run", "--repository-root", "/repo", "https://example.com/path"]
      ),
      .run(url: url, engine: .repositoryRoot("/repo")))
    XCTAssertEqual(
      try CLIArgumentParser.parse(["run", "https://example.com/path", "--chrome", "/chrome"]),
      .run(url: url, engine: .chromeExecutable("/chrome")))
  }

  func testRejectsAmbiguousUnknownAndIncompleteArguments() throws {
    let invalid: [[String]] = [
      ["help", "extra"],
      ["doctor", "extra"],
      ["doctor", "--unknown"],
      ["doctor", "--engine"],
      ["doctor", "--engine", "--repository-root"],
      ["doctor", "--engine", "/one", "--repository-root", "/two"],
      ["doctor", "--chrome", "/chrome", "--engine", "/engine"],
      ["run"],
      ["run", "relative/path"],
      ["run", "https://one.example", "https://two.example"],
    ]

    for arguments in invalid {
      XCTAssertThrowsError(try CLIArgumentParser.parse(arguments), "accepted \(arguments)")
    }
  }
}
