//
//  ParserTests.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Testing
@testable import YamlKit

@Suite("Parser")
struct ParserTests {

  private func events(_ yaml: String) throws -> String {
    return EventFormatter.format(try YAML.parseEvents(yaml))
  }

  @Test("Empty stream")
  func emptyStream() throws {
    #expect(try self.events("") == "+STR\n-STR\n")
    #expect(try self.events("# only a comment\n") == "+STR\n-STR\n")
  }

  @Test("Implicit and explicit documents")
  func documents() throws {
    #expect(try self.events("a\n---\nb\n...\n") == """
      +STR
      +DOC
      =VAL :a
      -DOC
      +DOC ---
      =VAL :b
      -DOC ...
      -STR

      """)
  }

  @Test("Bare documents may follow a document end marker")
  func bareDocumentAfterEndMarker() throws {
    #expect(try self.events("a\n...\nb\n") == """
      +STR
      +DOC
      =VAL :a
      -DOC ...
      +DOC
      =VAL :b
      -DOC
      -STR

      """)
  }

  @Test("Directives")
  func directives() throws {
    let events = try YAML.parseEvents("%YAML 1.2\n%TAG !e! tag:example.com,2000:app/\n--- !e!foo x\n")
    guard case .documentStart(let version, let directives, let isImplicit) = events[1].kind else {
      Issue.record("expected document start")
      return
    }
    #expect(version == .v1_2)
    #expect(directives == [TagDirective(handle: "!e!", prefix: "tag:example.com,2000:app/")])
    #expect(!isImplicit)
    #expect(EventFormatter.format(events[2]) == "=VAL <tag:example.com,2000:app/foo> :x")
  }

  @Test("YAMLTag resolution", arguments: [
    ("!!str a", "=VAL <tag:yaml.org,2002:str> :a"),
    ("!local a", "=VAL <!local> :a"),
    ("! a", "=VAL <!> :a"),
    ("!<tag:x,2000:y> a", "=VAL <tag:x,2000:y> :a"),
    ("%TAG ! tag:x,2000:\n---\n!y%21 a", "=VAL <tag:x,2000:y!> :a")
  ])
  func tagResolution(yaml: String, event: String) throws {
    #expect(try self.events(yaml).contains(event + "\n"))
  }

  @Test("Complex keys and empty nodes")
  func complexKeys() throws {
    #expect(try self.events("? [a, b]\n: c\n? d\n: \n") == """
      +STR
      +DOC
      +MAP
      +SEQ []
      =VAL :a
      =VAL :b
      -SEQ
      =VAL :c
      =VAL :d
      =VAL :
      -MAP
      -DOC
      -STR

      """)
  }

  @Test("Single pair mappings in flow sequences")
  func singlePairMappings() throws {
    #expect(try self.events("[a: b, : c, ? d]") == """
      +STR
      +DOC
      +SEQ []
      +MAP {}
      =VAL :a
      =VAL :b
      -MAP
      +MAP {}
      =VAL :
      =VAL :c
      -MAP
      +MAP {}
      =VAL :d
      =VAL :
      -MAP
      -SEQ
      -DOC
      -STR

      """)
  }

  @Test("Syntax errors", arguments: [
    "%YAML 1.2\nfoo",
    "%YAML 1.2\n%YAML 1.2\n---",
    "%YAML 2.0\n---",
    "%TAG !a! x\n%TAG !a! y\n---",
    "a: b\n%YAML 1.2\n---",
    "!undefined!tag x",
    "[a, b",
    "{a: b",
    "[a,, b]",
    "&a &b c",
    "- a\nb: c",
    "a: 1\n- b",
    "key: value\n  other: x"
  ])
  func syntaxErrors(yaml: String) {
    #expect(throws: YAMLError.self) {
      _ = try YAML.parseEvents(yaml)
    }
  }

  @Test("Maximum depth")
  func maximumDepth() throws {
    let yaml = String(repeating: "[", count: 20) + String(repeating: "]", count: 20)
    var parser = try YAMLParser(string: yaml, maximumDepth: 10)
    #expect {
      _ = try parser.parseAll()
    } throws: { error in
      (error as? YAMLError)?.kind == .limitExceeded
    }
    var unlimited = try YAMLParser(string: yaml, maximumDepth: 20)
    #expect(try unlimited.parseAll().count == 44)
  }

  @Test("Event locations")
  func eventLocations() throws {
    let events = try YAML.parseEvents("a:\n  - b\n")
    let scalar = try #require(events.first { EventFormatter.format($0) == "=VAL :b" })
    #expect(scalar.start == Mark(offset: 7, line: 2, column: 5))
  }
}
