//
//  TestSuiteCase.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation
import Testing

/// A test case of the YAML test suite (https://github.com/yaml/yaml-test-suite).
///
/// Each case is a directory containing:
///
/// - `===`: the name of the test,
/// - `in.yaml`: the YAML input,
/// - `test.event`: the expected parsing events,
/// - `in.json`: the expected data as JSON (optional),
/// - `out.yaml` / `emit.yaml`: canonical emitter output (optional),
/// - `error`: present if the input is invalid.
struct TestSuiteCase: Sendable, CustomTestStringConvertible, CustomStringConvertible {

  /// The identifier of the test, e.g. `2G84/02`.
  let id: String

  /// The descriptive name of the test.
  let name: String

  /// The raw YAML input.
  let yaml: Data

  /// The expected events in the test suite's event notation.
  let events: String?

  /// The expected data as a stream of JSON values.
  let json: String?

  /// The expected output of an emitter, if provided.
  let outYAML: String?

  /// Does the input contain an error?
  let isError: Bool

  var testDescription: String {
    return "\(self.id): \(self.name)"
  }

  var description: String {
    return self.testDescription
  }

  /// The directory containing the vendored test suite.
  static var suiteDirectory: URL? {
    return Bundle.module.resourceURL?.appendingPathComponent("yaml-test-suite")
  }

  /// All test cases of the vendored suite, sorted by identifier.
  static let all: [TestSuiteCase] = {
    guard let root = TestSuiteCase.suiteDirectory,
          let enumerator = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: nil) else {
      return []
    }
    var cases: [TestSuiteCase] = []
    for case let url as URL in enumerator where url.lastPathComponent == "in.yaml" {
      let directory = url.deletingLastPathComponent()
      let id = directory.path.dropFirst(root.path.count + 1)
      func read(_ name: String) -> String? {
        let file = directory.appendingPathComponent(name)
        return (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) }
      }
      guard let yaml = try? Data(contentsOf: url) else {
        continue
      }
      cases.append(TestSuiteCase(
        id: String(id),
        name: (read("===") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
        yaml: yaml,
        events: read("test.event"),
        json: read("in.json"),
        outYAML: read("out.yaml"),
        isError: FileManager.default.fileExists(atPath: directory.appendingPathComponent("error").path)))
    }
    return cases.sorted { $0.id < $1.id }
  }()

  /// All valid test cases.
  static var valid: [TestSuiteCase] {
    return TestSuiteCase.all.filter { !$0.isError }
  }

  /// All test cases with expected JSON output.
  static var withJSON: [TestSuiteCase] {
    return TestSuiteCase.all.filter { !$0.isError && $0.json != nil }
  }
}
