//
//  EmitterTests.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Testing
@testable import YamlKit

@Suite("Emitter")
struct EmitterTests {

  /// Parses `yaml` and emits the resulting events again.
  private func reemit(_ yaml: String, options: YAMLEmitter.Options = .init()) throws -> String {
    return try YAML.emit(try YAML.parseEvents(yaml), options: options)
  }

  private func serialize(_ node: YAMLNode, options: YAMLEmitter.Options = .init()) throws -> String {
    return try YAML.serialize(node, options: .init(formatting: options))
  }

  @Test("Block collections")
  func blockCollections() throws {
    let node: YAMLNode = ["name": "x", "list": [1, ["a": "b", "c": "d"], [2, 3]], "map": ["k": "v"]]
    #expect(try self.serialize(node) == """
      name: x
      list:
        - 1
        - a: b
          c: d
        - - 2
          - 3
      map:
        k: v

      """)
  }

  @Test("Indentless sequences")
  func indentlessSequences() throws {
    let node: YAMLNode = ["list": [1, 2]]
    #expect(try self.serialize(node, options: .init(indentsSequencesInMappings: false)) == "list:\n- 1\n- 2\n")
  }

  @Test("Indentation width")
  func indentationWidth() throws {
    let node: YAMLNode = ["a": ["b": [1]]]
    #expect(try self.serialize(node, options: .init(indentation: 4)) == "a:\n    b:\n        - 1\n")
  }

  @Test("Empty collections use flow style")
  func emptyCollections() throws {
    let node: YAMLNode = ["seq": [], "map": [:]]
    #expect(try self.serialize(node) == "seq: []\nmap: {}\n")
  }

  @Test("Flow collections")
  func flowCollections() throws {
    #expect(try self.reemit("{a: [1, 2], b: {c: d}}") == "{a: [1, 2], b: {c: d}}\n")
  }

  @Test("Strings are quoted where necessary", arguments: [
    ("plain", "plain"),
    ("true", "\"true\""),
    ("null", "\"null\""),
    ("", "\"\""),
    ("12", "\"12\""),
    ("1.5", "\"1.5\""),
    ("0x1F", "\"0x1F\""),
    ("a: b", "'a: b'"),
    ("a #b", "'a #b'"),
    ("- a", "'- a'"),
    ("#x", "'#x'"),
    (" leading", "' leading'"),
    ("trailing ", "'trailing '"),
    ("it's", "it's"),
    ("tab\there", "tab\there"),
    ("bell\u{07}", "\"bell\\a\""),
    ("---", "'---'"),
    ("a\u{2028}b", "\"a\\Lb\""),
    ("😀", "😀")
  ])
  func quoting(value: String, expected: String) throws {
    #expect(try self.serialize(["key": YAMLNode(value)]) == "key: \(expected)\n")
  }

  @Test("Multi-line strings use literal style")
  func literalStyle() throws {
    #expect(try self.serialize(["text": "line 1\nline 2\n"]) == "text: |\n  line 1\n  line 2\n")
    #expect(try self.serialize(["text": "line 1\nline 2"]) == "text: |-\n  line 1\n  line 2\n")
    #expect(try self.serialize(["text": "line\n\n"]) == "text: |+\n  line\n\n")
    #expect(try self.serialize(["text": "  indented\nline\n"]) == "text: |2\n    indented\n  line\n")
    // Trailing spaces cannot be represented in block scalars.
    #expect(try self.serialize(["text": "a\nb "]) == "text: \"a\\nb \"\n")
  }

  @Test("Folded style")
  func foldedStyle() throws {
    let node = YAMLNode.scalar(YAMLNode.Scalar("a b\nc\n", style: .folded))
    let yaml = try self.serialize(["text": node])
    #expect(yaml == "text: >\n  a b\n\n  c\n")
    #expect(try YAML.parse(yaml)?["text"]?.string == "a b\nc\n")
  }

  @Test("Long lines are folded")
  func lineFolding() throws {
    let words = Array(repeating: "word", count: 30).joined(separator: " ")
    let yaml = try self.serialize(["text": YAMLNode(words)], options: .init(lineWidth: 40))
    #expect(yaml.split(separator: "\n").count > 1)
    #expect(try YAML.parse(yaml)?["text"]?.string == words)
  }

  @Test("Tags are written when needed")
  func tags() throws {
    let node: YAMLNode = [
      .scalar(.init("12", tag: .int)),
      .scalar(.init("12", tag: .str)),
      .scalar(.init("abc", tag: .int)),
      .scalar(.init("x", tag: "!local")),
      .scalar(.init("x", tag: "tag:example.com,2000:t")),
      .mapping(.init([], tag: .set))
    ]
    #expect(try self.serialize(node) == """
      - 12
      - "12"
      - !!int abc
      - !local x
      - !<tag:example.com,2000:t> x
      - !!set {}

      """)
  }

  @Test("YAMLTag directives shorten tags")
  func tagDirectives() throws {
    let yaml = "%TAG !e! tag:example.com,2000:app/\n--- !e!foo x\n"
    #expect(try self.reemit(yaml) == yaml)
  }

  @Test("Anchors and aliases")
  func anchorsAndAliases() throws {
    let yaml = "a: &x [1, 2]\nb: *x\n*x : c\n"
    let node = try #require(try YAML.parse(yaml))
    let output = try self.serialize(node)
    #expect(output == "a: &x [1, 2]\nb: *x\n*x : c\n")
    #expect(try YAML.parse(output) == node)
  }

  @Test("Documents")
  func documents() throws {
    #expect(try YAML.serialize(documents: [1, 2]) == "1\n--- 2\n")
    #expect(try YAML.serialize(documents: [nil]) == "null\n")
    #expect(try self.reemit("---\n") == "---\n")
    #expect(try self.reemit("%YAML 1.2\n--- a\n...\n%YAML 1.2\n--- b\n") ==
            "%YAML 1.2\n--- a\n...\n%YAML 1.2\n--- b\n")
    #expect(try self.reemit("a\n--- b\n", options: .init(explicitDocumentStart: true)) == "--- a\n--- b\n")
  }

  @Test("Empty keys and values")
  func emptyNodes() throws {
    #expect(try self.reemit(": a\nb:\n") == ": a\nb:\n")
    #expect(try self.reemit("{: a, b: }") == "{: a, b:}\n")
    #expect(try self.reemit("- &a\n- !!str\n") == "- &a\n- !!str\n")
    #expect(try self.reemit("&a : x") == "&a : x\n")
  }

  @Test("Complex keys")
  func complexKeys() throws {
    #expect(try self.reemit("? [a, b]\n: c\n? |\n  multi\n  line\n: d\n") ==
            "? [a, b]\n: c\n? |\n  multi\n  line\n: d\n")
  }

  @Test("Unicode escaping")
  func unicodeEscaping() throws {
    let node: YAMLNode = ["k": "é😀"]
    #expect(try self.serialize(node) == "k: é😀\n")
    #expect(try self.serialize(node, options: .init(allowsUnicode: false)) == "k: \"\\xE9\\U0001F600\"\n")
  }

  @Test("Invalid event sequences are rejected")
  func invalidEvents() {
    var emitter = YAMLEmitter()
    #expect(throws: YAMLError.self) {
      try emitter.emit(.scalar("x"))
    }
    var anchors = YAMLEmitter()
    #expect(throws: YAMLError.self) {
      try anchors.emit(contentsOf: [
        YAMLEvent(.streamStart),
        YAMLEvent(.documentStart(version: nil, tagDirectives: [], isImplicit: true)),
        .scalar("x", anchor: "bad anchor")
      ])
    }
  }
}
