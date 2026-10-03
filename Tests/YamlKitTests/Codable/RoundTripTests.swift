//
//  RoundTripTests.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation
import Testing
import YamlKit

/// Property-based tests encoding randomly generated values and decoding them
/// again.
@Suite("Round trips")
struct RoundTripTests {

  /// A deterministic pseudo-random number generator (SplitMix64).
  struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
      self.state &+= 0x9E3779B97F4A7C15
      var z = self.state
      z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
      z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
      return z ^ (z >> 31)
    }
  }

  /// A recursive value covering all kinds of containers and scalars.
  indirect enum Value: Codable, Equatable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case null
    case list([Value])
    case object([String: Value])
  }

  struct Record: Codable, Equatable {
    var id: Int
    var name: String
    var score: Double
    var flags: [Bool]
    var tags: [String: String]
    var optional: String?
    var nested: [Record]
    var value: Value
  }

  private static let fragments = [
    "a", "Z", "0", "1", "x y", " ", "  ", "\t", "\n", "\r\n", ":", ": ", " #", "#", "-", "- ", "?", "? ",
    ",", "[", "]", "{", "}", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`", "\\", "---", "...",
    "true", "null", "~", "1.5", "0x1F", ".inf", "é", "ß", "😀", "\u{85}", "\u{2028}", "\u{FEFF}",
    "\u{0}", "\u{1B}", "\u{A0}", "<<", "=", "yes", "no"
  ]

  static func randomString(_ g: inout SeededGenerator) -> String {
    let count = Int.random(in: 0...6, using: &g)
    return (0..<count).map { _ in RoundTripTests.fragments.randomElement(using: &g)! }.joined()
  }

  static func randomValue(_ g: inout SeededGenerator, depth: Int) -> Value {
    switch Int.random(in: 0..<(depth > 2 ? 5 : 7), using: &g) {
      case 0: return .int(Int.random(in: Int.min...Int.max, using: &g))
      case 1: return .double([0.0, -0.0, 1e300, -1.5, .infinity, 0.1, Double.random(in: -1e6...1e6, using: &g)]
                              .randomElement(using: &g)!)
      case 2: return .bool(Bool.random(using: &g))
      case 3: return .string(RoundTripTests.randomString(&g))
      case 4: return .null
      case 5: return .list((0..<Int.random(in: 0...3, using: &g)).map { _ in
        RoundTripTests.randomValue(&g, depth: depth + 1)
      })
      default:
        var object: [String: Value] = [:]
        for _ in 0..<Int.random(in: 0...3, using: &g) {
          object[RoundTripTests.randomString(&g)] = RoundTripTests.randomValue(&g, depth: depth + 1)
        }
        return .object(object)
    }
  }

  static func randomRecord(_ g: inout SeededGenerator, depth: Int = 0) -> Record {
    var tags: [String: String] = [:]
    for _ in 0..<Int.random(in: 0...3, using: &g) {
      tags[RoundTripTests.randomString(&g)] = RoundTripTests.randomString(&g)
    }
    return Record(
      id: Int.random(in: -1000...1000, using: &g),
      name: RoundTripTests.randomString(&g),
      score: Double.random(in: -100...100, using: &g),
      flags: (0..<Int.random(in: 0...3, using: &g)).map { _ in Bool.random(using: &g) },
      tags: tags,
      optional: Bool.random(using: &g) ? RoundTripTests.randomString(&g) : nil,
      nested: depth < 2 ? (0..<Int.random(in: 0...2, using: &g)).map { _ in
        RoundTripTests.randomRecord(&g, depth: depth + 1)
      } : [],
      value: RoundTripTests.randomValue(&g, depth: 0))
  }

  @Test("Random records survive encoding and decoding", arguments: 0..<50)
  func randomRecords(seed: UInt64) throws {
    var generator = SeededGenerator(state: seed)
    let records = (0..<10).map { _ in RoundTripTests.randomRecord(&generator) }
    let decoder = YAMLDecoder()
    for formatting in [YAMLEncoder.OutputFormatting(), [.sortedKeys, .indentlessSequences], .flowStyle] {
      let encoder = YAMLEncoder()
      encoder.outputFormatting = formatting
      encoder.lineWidth = Int.random(in: 10...100, using: &generator)
      let yaml = try encoder.encodeToString(records)
      let decoded: [Record]
      do {
        decoded = try decoder.decode([Record].self, from: yaml)
      } catch {
        Issue.record("\(error)\n\(yaml)")
        continue
      }
      #expect(decoded == records)
      if decoded != records {
        for (a, b) in zip(decoded, records) where a != b {
          Issue.record("expected \(b)\nfound \(a)\n\(yaml)")
          break
        }
      }
    }
  }

  @Test("Random documents survive serialization and parsing", arguments: 0..<50)
  func randomNodes(seed: UInt64) throws {
    var generator = SeededGenerator(state: 1000 + seed)
    let value = RoundTripTests.randomValue(&generator, depth: 0)
    let node = try YAMLEncoder().encodeToNode(value)
    let yaml = try YAML.serialize(node)
    #expect(try YAML.parse(yaml) == node, "\(yaml)")
  }
}
