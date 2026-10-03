//
//  NodeTests.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Testing
@testable import YamlKit

@Suite("Nodes")
struct NodeTests {

  @Test("Literals")
  func literals() {
    let node: YAMLNode = ["name": "YamlKit", "version": 1, "ratio": 0.5, "enabled": true, "none": nil,
                          "tags": ["a", "b"]]
    #expect(node["name"]?.string == "YamlKit")
    #expect(node["name"]?.tag == .str)
    #expect(node["version"]?.int == 1)
    #expect(node["ratio"]?.double == 0.5)
    #expect(node["enabled"]?.bool == true)
    #expect(node["none"]?.isNull == true)
    #expect(node["tags"]?[1]?.string == "b")
    #expect(node["tags"]?[2] == nil)
    #expect(node["missing"] == nil)
  }

  @Test("Canonical floats")
  func canonicalFloats() {
    #expect(YAMLNode(1.0).string == "1.0")
    #expect(YAMLNode(Double.infinity).string == ".inf")
    #expect(YAMLNode(-Double.infinity).string == "-.inf")
    #expect(YAMLNode(Double.nan).string == ".nan")
    #expect(YAMLNode(1e100).string == "1e+100")
  }

  @Test("Equality ignores presentation and mapping order")
  func equality() throws {
    let a = try #require(try YAML.parse("{b: 2, a: [1, 'x']}"))
    let b = try #require(try YAML.parse("a:\n  - 0x1\n  - x\nb: 2\n"))
    let c = try #require(try YAML.parse("a: [1, x]\nb: 2\n"))
    #expect(a == b) // 1 and 0x1 are different notations of the same integer
    #expect(a == c)
    #expect(a.hashValue == b.hashValue)
    #expect(YAMLNode("1") != YAMLNode(1))
    #expect(try YAML.parse("[~, null, '', 1.0, 1e0]") == [nil, nil, "", 1.0, 1.0])
  }

  @Test("Mapping mutation")
  func mappingMutation() {
    var mapping: YAMLNode.Mapping = ["a": 1, "b": 2]
    mapping["a"] = 10
    mapping["c"] = 3
    mapping["b"] = nil
    #expect(mapping.keys == ["a", "c"])
    #expect(mapping.values == [10, 3])
  }

  @Test("YAMLTag resolution during composition")
  func composition() throws {
    let node = try #require(try YAML.parse("""
      - 12
      - "12"
      - !!str 12
      - ! 12
      - !custom 12
      - ~
      -
      - [a]
      - !!set {a}
      """))
    let tags = node.array?.map(\.tag)
    #expect(tags == [.int, .str, .str, .str, YAMLTag("!custom"), .null, .null, .seq, .set])
  }

  @Test("Schemas affect composition")
  func schemas() throws {
    let yaml = "[null, true, 1, 1.5, ~]"
    let core = try #require(try YAML.parse(yaml))
    let json = try #require(try YAML.parse(yaml, options: .init(schema: .json)))
    let failsafe = try #require(try YAML.parse(yaml, options: .init(schema: .failsafe)))
    #expect(core.array?.map(\.tag) == [.null, .bool, .int, .float, .null])
    #expect(json.array?.map(\.tag) == [.null, .bool, .int, .float, .str])
    #expect(failsafe.array?.map(\.tag) == [.str, .str, .str, .str, .str])
  }

  @Test("Aliases are resolved")
  func aliases() throws {
    let node = try #require(try YAML.parse("base: &b {x: 1}\ncopy: *b\n"))
    #expect(node["copy"] == node["base"])
    #expect(node["copy"]?.anchor == "b")
  }

  @Test("Undefined and recursive aliases are rejected")
  func undefinedAliases() {
    #expect(throws: YAMLError.self) { _ = try YAML.parse("a: *missing") }
    #expect(throws: YAMLError.self) { _ = try YAML.parse("&a [*a]") }
  }

  @Test("Duplicate keys")
  func duplicateKeys() throws {
    #expect {
      _ = try YAML.parse("a: 1\nb: 2\na: 3\n")
    } throws: { error in
      let error = error as? YAMLError
      return error?.kind == .composer && error?.mark?.line == 3
    }
    let node = try YAML.parse("a: 1\na: 2\n", options: .init(allowsDuplicateKeys: true))
    #expect(node?.mapping?.count == 2)
  }

  @Test("Merge keys")
  func mergeKeys() throws {
    let yaml = """
      base: &base {a: 1, b: 2}
      extra: &extra {c: 3}
      derived:
        <<: [*base, *extra]
        b: 20
      """
    let options = YAML.ParseOptions(resolvesMergeKeys: true)
    let node = try #require(try YAML.parse(yaml, options: options))
    #expect(node["derived"] == ["b": 20, "a": 1, "c": 3])
    let unmerged = try #require(try YAML.parse(yaml))
    #expect(unmerged["derived"]?["<<"] != nil)
  }

  @Test("Billion laughs are rejected")
  func billionLaughs() {
    var yaml = "a0: &a0 [x, x, x, x, x, x, x, x, x, x]\n"
    for i in 1...9 {
      yaml += "a\(i): &a\(i) [" + Array(repeating: "*a\(i - 1)", count: 10).joined(separator: ", ") + "]\n"
    }
    #expect {
      _ = try YAML.parse(yaml)
    } throws: { error in
      (error as? YAMLError)?.kind == .limitExceeded
    }
  }

  @Test("Multiple documents")
  func multipleDocuments() throws {
    let documents = try YAML.parseAll("--- 1\n--- 2\n---\n")
    #expect(documents == [1, 2, nil])
    #expect(throws: YAMLError.self) { _ = try YAML.parse("--- 1\n--- 2\n") }
    #expect(try YAML.parse("") == nil)
  }
}
