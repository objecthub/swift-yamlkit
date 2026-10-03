//
//  ScannerTests.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Testing
@testable import YamlKit

@Suite("Scanner")
struct ScannerTests {

  /// Returns the kinds of all tokens of `yaml`.
  private func tokens(_ yaml: String) throws -> [Token.Kind] {
    var scanner = Scanner(try Reader.normalize(yaml))
    var kinds: [Token.Kind] = []
    while true {
      let token = try scanner.nextToken()
      kinds.append(token.kind)
      if case .streamEnd = token.kind {
        return kinds
      }
    }
  }

  @Test("Block mapping with implicit keys")
  func blockMapping() throws {
    #expect(try self.tokens("a: 1\nb: 2\n") == [
      .streamStart, .blockMappingStart,
      .key, .scalar("a", .plain), .value, .scalar("1", .plain),
      .key, .scalar("b", .plain), .value, .scalar("2", .plain),
      .blockEnd, .streamEnd
    ])
  }

  @Test("Indentless sequence in a mapping")
  func indentlessSequence() throws {
    #expect(try self.tokens("a:\n- x\n- y\n") == [
      .streamStart, .blockMappingStart,
      .key, .scalar("a", .plain), .value,
      .blockEntry, .scalar("x", .plain), .blockEntry, .scalar("y", .plain),
      .blockEnd, .streamEnd
    ])
  }

  @Test("Flow collections")
  func flowCollections() throws {
    #expect(try self.tokens("[a, {b: c}]") == [
      .streamStart, .flowSequenceStart,
      .scalar("a", .plain), .flowEntry,
      .flowMappingStart, .key, .scalar("b", .plain), .value, .scalar("c", .plain), .flowMappingEnd,
      .flowSequenceEnd, .streamEnd
    ])
  }

  @Test("JSON-like keys allow adjacent values")
  func adjacentValues() throws {
    #expect(try self.tokens("{\"a\":b}") == [
      .streamStart, .flowMappingStart,
      .key, .scalar("a", .doubleQuoted), .value, .scalar("b", .plain),
      .flowMappingEnd, .streamEnd
    ])
  }

  @Test("Plain scalars in flow context may contain colons")
  func plainScalarsWithColons() throws {
    #expect(try self.tokens("[http://example.com, a:b]") == [
      .streamStart, .flowSequenceStart,
      .scalar("http://example.com", .plain), .flowEntry, .scalar("a:b", .plain),
      .flowSequenceEnd, .streamEnd
    ])
  }

  @Test("Properties and aliases")
  func properties() throws {
    #expect(try self.tokens("- &a !!str x\n- *a\n- !<tag:x> y\n- !e!foo z\n- ! w") == [
      .streamStart, .blockSequenceStart,
      .blockEntry, .anchor("a"), .tag(handle: "!!", suffix: "str"), .scalar("x", .plain),
      .blockEntry, .alias("a"),
      .blockEntry, .tag(handle: nil, suffix: "tag:x"), .scalar("y", .plain),
      .blockEntry, .tag(handle: "!e!", suffix: "foo"), .scalar("z", .plain),
      .blockEntry, .tag(handle: "!", suffix: ""), .scalar("w", .plain),
      .blockEnd, .streamEnd
    ])
  }

  @Test("Directives and document markers")
  func directives() throws {
    #expect(try self.tokens("%YAML 1.2\n%TAG !e! tag:example.com,2000:\n---\nx\n...\n") == [
      .streamStart,
      .versionDirective(.v1_2),
      .tagDirective(TagDirective(handle: "!e!", prefix: "tag:example.com,2000:")),
      .documentStart, .scalar("x", .plain), .documentEnd,
      .streamEnd
    ])
  }

  @Test("Scalar folding", arguments: [
    ("a\n  b\n\n  c", "a b\nc"),
    ("'a ''b''\n  c'", "a 'b' c"),
    ("\"a\\tb\\\n  c \\x41\\u00e9\\U0001F600\"", "a\tbc A\u{e9}\u{1F600}"),
    ("|\n  a\n   b\n\n", "a\n b\n"),
    ("|-\n  a\n", "a"),
    ("|+\n  a\n\n", "a\n\n"),
    (">\n  a\n  b\n\n  c\n", "a b\nc\n"),
    (">\n  a\n    b\n  c\n", "a\n  b\nc\n"),
    ("k: |2\n   a\n", " a\n"),
    ("--- |1\n  a\n", "  a\n")
  ])
  func scalarFolding(yaml: String, value: String) throws {
    let scalars = try self.tokens(yaml).compactMap { kind -> String? in
      if case .scalar(let value, _) = kind {
        return value
      }
      return nil
    }
    #expect(scalars.last == value)
  }

  @Test("Lexical errors", arguments: [
    "key: \"unterminated",
    "a: b: c",
    "--- a: b",
    "key: - a",
    "- \t- a",
    "a:\n\tb: c",
    "\"a\"b",
    "[a]#comment",
    "key: |0\n  x",
    "key: > text",
    "&anchor - entry",
    "\"\\q\"",
    "{a: [b\nc]}x: y"
  ])
  func lexicalErrors(yaml: String) {
    #expect(throws: YAMLError.self) {
      _ = try self.tokens(yaml)
    }
  }

  @Test("Error locations")
  func errorLocations() {
    #expect {
      _ = try self.tokens("key:\n  value: 1\n  other: \"x")
    } throws: { error in
      let error = error as? YAMLError
      return error?.kind == .scanner && error?.mark?.line == 3 && error?.mark?.column == 10
    }
  }
}
