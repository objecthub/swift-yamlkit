//
//  YAMLTestSuiteTests.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation
import Testing
@testable import YamlKit

/// Conformance tests based on the YAML test suite.
@Suite("YAML test suite")
struct YAMLTestSuiteTests {

  @Test("Suite is available")
  func suiteIsAvailable() {
    #expect(TestSuiteCase.all.count > 300)
  }

  /// Parses every input and compares the resulting events with
  /// `test.event`, or expects a failure for invalid inputs.
  @Test("Parsing events", arguments: TestSuiteCase.all)
  func parseEvents(_ testCase: TestSuiteCase) throws {
    if testCase.isError {
      #expect(throws: YAMLError.self, "\(testCase.id) must not be accepted") {
        var parser = try YAMLParser(data: testCase.yaml)
        _ = try parser.parseAll()
      }
    } else {
      var parser = try YAMLParser(data: testCase.yaml)
      let events = try parser.parseAll()
      #expect(EventFormatter.format(events) == testCase.events)
    }
  }

  /// Composes every valid input with a JSON representation and compares the
  /// resulting nodes with `in.json`.
  @Test("Composing nodes", arguments: TestSuiteCase.withJSON)
  func composeNodes(_ testCase: TestSuiteCase) throws {
    let nodes = try YAML.parseAll(testCase.yaml)
    let expected = try JSONValue.parseStream(testCase.json ?? "")
    #expect(nodes.map(JSONValue.init) == expected)
  }

  /// Emits the events of every valid input, parses the output again, and
  /// compares the events. Presentation details that an emitter may change
  /// (collection styles, quoting styles, document markers) are ignored, but
  /// the distinction between plain and non-plain scalars is retained since
  /// it affects tag resolution.
  @Test("Emitting events", arguments: TestSuiteCase.valid)
  func emitEvents(_ testCase: TestSuiteCase) throws {
    let events = try YAML.parseEvents(testCase.yaml)
    let yaml = try YAML.emit(events)
    let reparsed: [YAMLEvent]
    do {
      reparsed = try YAML.parseEvents(yaml)
    } catch {
      Issue.record("emitted YAML cannot be parsed: \(error)\n\(yaml)")
      return
    }
    #expect(YAMLTestSuiteTests.normalize(reparsed) == YAMLTestSuiteTests.normalize(events),
            "emitted:\n\(yaml)")
  }

  /// Serializes the composed nodes of every valid input, parses the output
  /// again, and compares the nodes.
  @Test("Serializing nodes", arguments: TestSuiteCase.valid)
  func serializeNodes(_ testCase: TestSuiteCase) throws {
    let options = YAML.ParseOptions(allowsDuplicateKeys: true)
    let nodes = try YAML.parseAll(testCase.yaml, options: options)
    let yaml = try YAML.serialize(documents: nodes)
    let reparsed: [YAMLNode]
    do {
      reparsed = try YAML.parseAll(yaml, options: options)
    } catch {
      Issue.record("serialized YAML cannot be parsed: \(error)\n\(yaml)")
      return
    }
    #expect(reparsed == nodes, "serialized:\n\(yaml)")
  }

  /// Removes presentation details from events.
  static func normalize(_ events: [YAMLEvent]) -> [String] {
    return events.map { event in
      switch event.kind {
        case .documentStart:
          return "+DOC"
        case .documentEnd:
          return "-DOC"
        case .scalar(let value, let style, let tag, let anchor):
          // The style of a scalar only matters for untagged plain scalars
          // that are not resolved as strings.
          let isPlain = style == .plain && tag == nil
            && CoreSchema().tag(forPlainScalar: value) != .str
          return EventFormatter.format(.scalar(value, style: isPlain ? .plain : .doubleQuoted,
                                               tag: tag, anchor: anchor))
        case .sequenceStart(_, let tag, let anchor):
          return EventFormatter.format(YAMLEvent(.sequenceStart(style: .block, tag: tag, anchor: anchor)))
        case .mappingStart(_, let tag, let anchor):
          return EventFormatter.format(YAMLEvent(.mappingStart(style: .block, tag: tag, anchor: anchor)))
        default:
          return EventFormatter.format(event)
      }
    }
  }
}
