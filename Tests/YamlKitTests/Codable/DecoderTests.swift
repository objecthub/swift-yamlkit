//
//  DecoderTests.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation
import Testing
@testable import YamlKit

@Suite("YAMLDecoder")
struct DecoderTests {

  struct Server: Codable, Equatable {
    var host: String
    var port: Int
    var secure: Bool
    var timeout: Double?
    var tags: [String]
  }

  struct Config: Codable, Equatable {
    var name: String
    var servers: [Server]
    var limits: [String: Int]
    var version: String
  }

  @Test("Decodes nested structures")
  func nestedStructures() throws {
    let yaml = """
      # Service configuration
      name: example
      version: 1.10
      servers:
        - host: alpha.example.com
          port: 8080
          secure: true
          timeout: 2.5
          tags: [primary, eu]
        - host: beta.example.com
          port: 0x1F90
          secure: False
          tags: []
      limits:
        cpu: 4
        memory: 1024
      """
    let config = try YAMLDecoder().decode(Config.self, from: yaml)
    #expect(config == Config(
      name: "example",
      servers: [
        Server(host: "alpha.example.com", port: 8080, secure: true, timeout: 2.5, tags: ["primary", "eu"]),
        Server(host: "beta.example.com", port: 8080, secure: false, timeout: nil, tags: [])
      ],
      limits: ["cpu": 4, "memory": 1024],
      version: "1.10"))
  }

  @Test("Decodes from data in different encodings")
  func encodings() throws {
    let yaml = "- 1\n- 2\n"
    for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian] {
      let data = try #require(yaml.data(using: encoding))
      #expect(try YAMLDecoder().decode([Int].self, from: data) == [1, 2])
    }
  }

  @Test("Decodes top-level scalars")
  func topLevelScalars() throws {
    let decoder = YAMLDecoder()
    #expect(try decoder.decode(Int.self, from: "42") == 42)
    #expect(try decoder.decode(String.self, from: "hello world") == "hello world")
    #expect(try decoder.decode(Bool.self, from: "TRUE") == true)
    #expect(try decoder.decode(Double.self, from: "-.inf") == -.infinity)
    #expect(try decoder.decode(Double.self, from: ".nan").isNaN)
    #expect(try decoder.decode(Int?.self, from: "~") == nil)
    #expect(try decoder.decode(Int?.self, from: "") == nil)
    #expect(try decoder.decode(UInt8.self, from: "0o377") == 255)
    #expect(try decoder.decode(Float.self, from: "1e3") == 1000)
    #expect(try decoder.decode(Int.self, from: "3.0") == 3)
  }

  @Test("Decodes optionals")
  func optionals() throws {
    struct Options: Decodable, Equatable {
      var a: Int?
      var b: String?
      var c: [Int]?
    }
    let options = try YAMLDecoder().decode(Options.self, from: "a: null\nb:\n")
    #expect(options == Options(a: nil, b: nil, c: nil))
  }

  @Test("Decodes enumerations")
  func enumerations() throws {
    enum Level: String, Codable {
      case low, high
    }
    enum Priority: Int, Codable {
      case minor = 1, major = 2
    }
    enum Shape: Codable, Equatable {
      case circle(radius: Double)
      case rectangle(width: Double, height: Double)
      case empty
    }
    struct Item: Codable {
      var level: Level
      var priority: Priority
      var shapes: [Shape]
    }
    let item = try YAMLDecoder().decode(Item.self, from: """
      level: high
      priority: 2
      shapes:
        - circle: {radius: 1}
        - rectangle:
            width: 2
            height: 3
        - empty: {}
      """)
    #expect(item.level == .high)
    #expect(item.priority == .major)
    #expect(item.shapes == [.circle(radius: 1), .rectangle(width: 2, height: 3), .empty])
  }

  @Test("Decodes dictionaries with non-string keys")
  func dictionaries() throws {
    let dictionary = try YAMLDecoder().decode([Int: String].self, from: "1: one\n2: two\n")
    #expect(dictionary == [1: "one", 2: "two"])
  }

  @Test("Decodes dates")
  func dates() throws {
    struct Event: Decodable {
      var date: Date
    }
    let decoder = YAMLDecoder()
    let expectations: [(String, TimeInterval)] = [
      ("2001-12-14", 1008288000),
      ("2001-12-14t21:59:43.10-05:00", 1008385183.1),
      ("2001-12-14 21:59:43.10 -5", 1008385183.1),
      ("2001-12-15T02:59:43.1Z", 1008385183.1),
      ("2002-12-14 2:59:43", 1039834783)
    ]
    for (text, interval) in expectations {
      let event = try decoder.decode(Event.self, from: "date: \(text)")
      #expect(abs(event.date.timeIntervalSince1970 - interval) < 0.001, "\(text)")
    }
    #expect(throws: DecodingError.self) {
      _ = try decoder.decode(Event.self, from: "date: 2001-13-45")
    }
    decoder.dateDecodingStrategy = .secondsSince1970
    #expect(try decoder.decode(Event.self, from: "date: 86400").date == Date(timeIntervalSince1970: 86400))
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(Event.self, from: "date: 1970-01-02T00:00:00Z").date
            == Date(timeIntervalSince1970: 86400))
    decoder.dateDecodingStrategy = .custom { decoder in
      let days = try decoder.singleValueContainer().decode(Double.self)
      return Date(timeIntervalSince1970: days * 86400)
    }
    #expect(try decoder.decode(Event.self, from: "date: 2").date == Date(timeIntervalSince1970: 172800))
  }

  @Test("Decodes binary data")
  func binaryData() throws {
    let yaml = """
      data: !!binary |
        SGVsbG8s
        IFdvcmxk
      """
    let decoded = try YAMLDecoder().decode([String: Data].self, from: yaml)
    #expect(decoded["data"] == Data("Hello, World".utf8))
  }

  @Test("Decodes Foundation types")
  func foundationTypes() throws {
    struct Values: Decodable {
      var url: URL
      var decimal: Decimal
    }
    let values = try YAMLDecoder().decode(Values.self, from: "url: https://example.com/a?b=c\ndecimal: 12.345")
    #expect(values.url == URL(string: "https://example.com/a?b=c"))
    #expect(values.decimal == Decimal(string: "12.345"))
  }

  @Test("Key decoding strategies")
  func keyStrategies() throws {
    struct Settings: Decodable, Equatable {
      var maxRetryCount: Int
      var baseUrl: String
    }
    let decoder = YAMLDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    #expect(try decoder.decode(Settings.self, from: "max_retry_count: 3\nbase_url: x")
            == Settings(maxRetryCount: 3, baseUrl: "x"))
    decoder.keyDecodingStrategy = .convertFromKebabCase
    #expect(try decoder.decode(Settings.self, from: "max-retry-count: 3\nbaseUrl: x")
            == Settings(maxRetryCount: 3, baseUrl: "x"))
    decoder.keyDecodingStrategy = .custom { path in
      YAMLCodingKey(stringValue: String(path.last!.stringValue.dropFirst(2)))
    }
    #expect(try decoder.decode(Settings.self, from: "x-maxRetryCount: 3\nx-baseUrl: x")
            == Settings(maxRetryCount: 3, baseUrl: "x"))
  }

  @Test("Merge keys")
  func mergeKeys() throws {
    struct Service: Decodable, Equatable {
      var image: String
      var replicas: Int
    }
    let yaml = """
      defaults: &defaults
        image: nginx
        replicas: 1
      web:
        <<: *defaults
        replicas: 3
      """
    let decoder = YAMLDecoder()
    decoder.parseOptions.resolvesMergeKeys = true
    let services = try decoder.decode([String: Service].self, from: yaml)
    #expect(services["web"] == Service(image: "nginx", replicas: 3))
  }

  @Test("Multiple documents")
  func multipleDocuments() throws {
    let values = try YAMLDecoder().decodeAll([String: Int].self, from: "a: 1\n---\nb: 2\n")
    #expect(values == [["a": 1], ["b": 2]])
    #expect(throws: DecodingError.self) {
      _ = try YAMLDecoder().decode([String: Int].self, from: "a: 1\n---\nb: 2\n")
    }
  }

  @Test("Class inheritance with super decoders")
  func superDecoder() throws {
    class Animal: Decodable {
      var name: String
    }
    final class Dog: Animal {
      var breed: String
      enum CodingKeys: String, CodingKey {
        case breed
      }
      required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.breed = try container.decode(String.self, forKey: .breed)
        try super.init(from: container.superDecoder())
      }
    }
    let dog = try YAMLDecoder().decode(Dog.self, from: "breed: beagle\nsuper:\n  name: Snoopy\n")
    #expect(dog.name == "Snoopy")
    #expect(dog.breed == "beagle")
  }

  @Test("User info is available to decoded types")
  func userInfo() throws {
    struct Scaled: Decodable {
      var value: Int
      init(from decoder: any Decoder) throws {
        let factor = decoder.userInfo[CodingUserInfoKey(rawValue: "factor")!] as? Int ?? 1
        self.value = try decoder.singleValueContainer().decode(Int.self) * factor
      }
    }
    let decoder = YAMLDecoder()
    decoder.userInfo[CodingUserInfoKey(rawValue: "factor")!] = 10
    #expect(try decoder.decode([Scaled].self, from: "[1, 2]").map(\.value) == [10, 20])
  }

  // MARK: - Errors

  @Test("Type mismatches report the coding path")
  func typeMismatch() {
    #expect {
      _ = try YAMLDecoder().decode(Config.self, from: """
        name: x
        version: "1"
        limits: {}
        servers:
          - host: a
            port: eighty
            secure: true
            tags: []
        """)
    } throws: { error in
      guard case DecodingError.typeMismatch(let type, let context) = error else {
        return false
      }
      return type == Int.self && context.codingPath.map(\.stringValue) == ["servers", "Index 0", "port"]
        && context.debugDescription.contains("line 6")
    }
  }

  @Test("Quoted numbers are strings")
  func quotedNumbers() {
    #expect(throws: DecodingError.self) {
      _ = try YAMLDecoder().decode(Int.self, from: "'12'")
    }
  }

  @Test("Missing keys")
  func missingKeys() {
    #expect {
      _ = try YAMLDecoder().decode(Server.self, from: "host: a\nsecure: true\ntags: []")
    } throws: { error in
      guard case DecodingError.keyNotFound(let key, _) = error else {
        return false
      }
      return key.stringValue == "port"
    }
  }

  @Test("Null values for non-optional properties")
  func nullValues() {
    #expect {
      _ = try YAMLDecoder().decode(Server.self, from: "host: ~\nport: 1\nsecure: true\ntags: []")
    } throws: { error in
      guard case DecodingError.valueNotFound(let type, let context) = error else {
        return false
      }
      return type == String.self && context.codingPath.map(\.stringValue) == ["host"]
    }
  }

  @Test("Numbers that do not fit")
  func overflow() {
    #expect {
      _ = try YAMLDecoder().decode(Int8.self, from: "300")
    } throws: { error in
      if case DecodingError.dataCorrupted = error {
        return true
      }
      return false
    }
  }

  @Test("Invalid YAML is reported as corrupted data")
  func invalidYAML() {
    #expect {
      _ = try YAMLDecoder().decode([String: Int].self, from: "a: [1, 2")
    } throws: { error in
      guard case DecodingError.dataCorrupted(let context) = error else {
        return false
      }
      return context.underlyingError is YAMLError
    }
  }

  @Test("Unkeyed containers report their end")
  func unkeyedEnd() {
    struct Pair: Decodable {
      var first: Int
      var second: Int
      init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.first = try container.decode(Int.self)
        self.second = try container.decode(Int.self)
      }
    }
    #expect(throws: DecodingError.self) {
      _ = try YAMLDecoder().decode(Pair.self, from: "[1]")
    }
  }
}
