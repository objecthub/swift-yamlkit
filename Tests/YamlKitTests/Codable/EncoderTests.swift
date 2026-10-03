//
//  EncoderTests.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation
import Testing
@testable import YamlKit

@Suite("YAMLEncoder")
struct EncoderTests {

  struct Person: Codable, Equatable {
    var name: String
    var age: Int
    var email: String?
    var nicknames: [String]
    var address: Address
  }

  struct Address: Codable, Equatable {
    var street: String
    var zipCode: String
  }

  private let person = Person(name: "Jane Doe", age: 42, email: nil, nicknames: ["JD", "Janie"],
                              address: Address(street: "1 Infinite Loop", zipCode: "95014"))

  @Test("Encodes nested structures in block style")
  func nestedStructures() throws {
    #expect(try YAMLEncoder().encodeToString(self.person) == """
      name: Jane Doe
      age: 42
      nicknames:
        - JD
        - Janie
      address:
        street: 1 Infinite Loop
        zipCode: "95014"

      """)
  }

  @Test("Encodes data as UTF-8")
  func data() throws {
    let data = try YAMLEncoder().encode(["a": 1])
    #expect(String(decoding: data, as: UTF8.self) == "a: 1\n")
  }

  @Test("Output formatting")
  func outputFormatting() throws {
    let encoder = YAMLEncoder()
    encoder.outputFormatting = [.sortedKeys, .explicitDocumentStart, .indentlessSequences]
    #expect(try encoder.encodeToString(self.person) == """
      ---
      address:
        street: 1 Infinite Loop
        zipCode: "95014"
      age: 42
      name: Jane Doe
      nicknames:
      - JD
      - Janie

      """)
    encoder.outputFormatting = [.flowStyle, .sortedKeys]
    encoder.lineWidth = 200
    #expect(try encoder.encodeToString(self.person) ==
      "{address: {street: 1 Infinite Loop, zipCode: \"95014\"}, age: 42, name: Jane Doe, nicknames: [JD, Janie]}\n")
    encoder.outputFormatting = []
    encoder.lineWidth = 80
    encoder.indentation = 4
    #expect(try encoder.encodeToString(["a": ["b": 1]]) == "a:\n    b: 1\n")
  }

  @Test("Encodes top-level values")
  func topLevelValues() throws {
    let encoder = YAMLEncoder()
    #expect(try encoder.encodeToString(42) == "42\n")
    #expect(try encoder.encodeToString("text") == "text\n")
    #expect(try encoder.encodeToString("true") == "\"true\"\n")
    #expect(try encoder.encodeToString([Int]()) == "[]\n")
    #expect(try encoder.encodeToString(Int?.none) == "null\n")
    #expect(try encoder.encodeToString(Double.infinity) == ".inf\n")
    #expect(try encoder.encodeToString(1.0) == "1.0\n")
    #expect(try encoder.encodeToString([1.5, -0.25]) == "- 1.5\n- -0.25\n")
  }

  @Test("Encodes multiple documents")
  func multipleDocuments() throws {
    #expect(try YAMLEncoder().encodeAllToString([["a": 1], ["b": 2]]) == "a: 1\n---\nb: 2\n")
  }

  @Test("Encodes nil values explicitly when requested")
  func explicitNil() throws {
    struct Value: Encodable {
      var a: Int?
      func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.a, forKey: .a)
      }
      enum CodingKeys: CodingKey {
        case a
      }
    }
    #expect(try YAMLEncoder().encodeToString(Value(a: nil)) == "a: null\n")
  }

  @Test("Encodes multi-line strings as literal block scalars")
  func multiLineStrings() throws {
    #expect(try YAMLEncoder().encodeToString(["script": "echo hello\necho world\n"]) == """
      script: |
        echo hello
        echo world

      """)
  }

  @Test("Encodes dictionaries with integer keys")
  func integerKeys() throws {
    let yaml = try YAMLEncoder().encodeToString([1: "one"])
    #expect(yaml == "1: one\n")
    #expect(try YAMLDecoder().decode([Int: String].self, from: yaml) == [1: "one"])
  }

  @Test("Key encoding strategies")
  func keyStrategies() throws {
    struct Settings: Encodable {
      var maxRetryCount = 3
      var baseURL = "x"
    }
    let encoder = YAMLEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    #expect(try encoder.encodeToString(Settings()) == "max_retry_count: 3\nbase_url: x\n")
    encoder.keyEncodingStrategy = .convertToKebabCase
    #expect(try encoder.encodeToString(Settings()) == "max-retry-count: 3\nbase-url: x\n")
  }

  @Test("Date encoding strategies")
  func dates() throws {
    let encoder = YAMLEncoder()
    let date = Date(timeIntervalSince1970: 1008385183.25)
    #expect(try encoder.encodeToString(["d": date]) == "d: 2001-12-15T02:59:43.250Z\n")
    #expect(try encoder.encodeToString(["d": Date(timeIntervalSince1970: 0)]) == "d: 1970-01-01T00:00:00Z\n")
    encoder.dateEncodingStrategy = .secondsSince1970
    #expect(try encoder.encodeToString(["d": date]) == "d: 1008385183.25\n")
    encoder.dateEncodingStrategy = .millisecondsSince1970
    #expect(try encoder.encodeToString(["d": Date(timeIntervalSince1970: 1)]) == "d: 1000.0\n")
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(Int(date.timeIntervalSince1970 / 86400))
    }
    #expect(try encoder.encodeToString(["d": Date(timeIntervalSince1970: 172800)]) == "d: 2\n")
  }

  @Test("Data is encoded as binary")
  func binaryData() throws {
    let yaml = try YAMLEncoder().encodeToString(["data": Data("Hello".utf8)])
    #expect(yaml == "data: !!binary SGVsbG8=\n")
    #expect(try YAMLDecoder().decode([String: Data].self, from: yaml)["data"] == Data("Hello".utf8))
  }

  @Test("Foundation types")
  func foundationTypes() throws {
    struct Values: Codable, Equatable {
      var url: URL
      var decimal: Decimal
    }
    let values = Values(url: URL(string: "https://example.com")!, decimal: Decimal(string: "3.25")!)
    let yaml = try YAMLEncoder().encodeToString(values)
    #expect(yaml == "url: https://example.com\ndecimal: 3.25\n")
    #expect(try YAMLDecoder().decode(Values.self, from: yaml) == values)
  }

  @Test("Class inheritance with super encoders")
  func superEncoder() throws {
    class Animal: Encodable {
      var name = "Snoopy"
    }
    final class Dog: Animal {
      var breed = "beagle"
      enum CodingKeys: CodingKey {
        case breed
      }
      override func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.breed, forKey: .breed)
        try super.encode(to: container.superEncoder())
      }
    }
    #expect(try YAMLEncoder().encodeToString(Dog()) == "breed: beagle\nsuper:\n  name: Snoopy\n")
  }

  @Test("Encodes to nodes")
  func nodes() throws {
    let node = try YAMLEncoder().encodeToNode(["a": [1, 2]])
    #expect(node == ["a": [1, 2]])
  }

  @Test("Round trips", arguments: [
    "plain", "", " ", "true", "False", "null", "~", "-", "--- x", "...", "- x", "? x", ": x",
    "a: b", "a #b", "#", "@x", "`x", "%x", "!x", "&x", "*x", "|", ">", "'", "\"", "\\", "[", "]", "{}",
    "1", "-1", "0x1F", "0o7", "1.5", "1e5", ".inf", ".nan", "1_000", "2001-12-14",
    "line\nbreak", "trailing\n", "\n", "\n\n", "  leading", "trailing  ", "a\n b", "a \nb",
    "tab\t", "\ttab", "a\tb", "\u{0}", "\u{7F}", "\u{85}", "\u{A0}", "\u{2028}", "\u{FEFF}x", "é", "😀",
    "\r\n", "\r", "a\r\nb", String(repeating: "long words ", count: 20),
    String(repeating: "x", count: 200) + " y", "  \n  ", "a\n\n\nb\n\n"
  ])
  func roundTrips(value: String) throws {
    let encoder = YAMLEncoder()
    let decoder = YAMLDecoder()
    for wrapped in [["key": value], ["key": "x", value: "y"]] {
      let yaml = try encoder.encodeToString(wrapped)
      #expect(try decoder.decode([String: String].self, from: yaml) == wrapped, "\(yaml)")
    }
    let sequence = try encoder.encodeToString([value, value])
    #expect(try decoder.decode([String].self, from: sequence) == [value, value], "\(sequence)")
    let top = try encoder.encodeToString(value)
    #expect(try decoder.decode(String.self, from: top) == value, "\(top)")
    encoder.outputFormatting = .flowStyle
    let flow = try encoder.encodeToString([[value: [value]]])
    #expect(try decoder.decode([[String: [String]]].self, from: flow) == [[value: [value]]], "\(flow)")
  }
}
