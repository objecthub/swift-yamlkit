//
//  JSONValue.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import YamlKit

/// A minimal JSON value model used to compare composed YAML nodes with the
/// `in.json` files of the YAML test suite.
enum JSONValue: Equatable, CustomStringConvertible {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  var description: String {
    switch self {
      case .null: return "null"
      case .bool(let b): return "\(b)"
      case .number(let n): return "\(n)"
      case .string(let s): return "\"\(s)\""
      case .array(let a): return "[" + a.map(\.description).joined(separator: ", ") + "]"
      case .object(let o):
        return "{" + o.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \($0.value)" }
          .joined(separator: ", ") + "}"
    }
  }

  /// Converts a node into the JSON data model using the core schema tags.
  init(_ node: YAMLNode) {
    switch node {
      case .scalar(let scalar):
        switch scalar.tag {
          case .null:
            self = .null
          case .bool:
            self = .bool(node.bool ?? false)
          case .int, .float:
            self = .number(node.double ?? .nan)
          default:
            self = .string(scalar.value)
        }
      case .sequence(let sequence):
        self = .array(sequence.elements.map(JSONValue.init))
      case .mapping(let mapping):
        var object: [String: JSONValue] = [:]
        for entry in mapping.entries {
          object[entry.key.string ?? entry.key.description] = JSONValue(entry.value)
        }
        self = .object(object)
    }
  }

  /// Parses a sequence of whitespace-separated JSON values.
  static func parseStream(_ text: String) throws -> [JSONValue] {
    var parser = JSONStreamParser(Array(text.unicodeScalars))
    var values: [JSONValue] = []
    parser.skipWhitespace()
    while !parser.isAtEnd {
      values.append(try parser.parseValue())
      parser.skipWhitespace()
    }
    return values
  }
}

struct JSONParseError: Error, CustomStringConvertible {
  let description: String
}

/// A small recursive descent JSON parser supporting streams of values.
private struct JSONStreamParser {
  let input: [Unicode.Scalar]
  var index = 0

  init(_ input: [Unicode.Scalar]) {
    self.input = input
  }

  var isAtEnd: Bool {
    return self.index >= self.input.count
  }

  var current: Unicode.Scalar {
    return self.index < self.input.count ? self.input[self.index] : "\0"
  }

  mutating func skipWhitespace() {
    while !self.isAtEnd && (self.current == " " || self.current == "\n"
                            || self.current == "\t" || self.current == "\r") {
      self.index += 1
    }
  }

  mutating func expect(_ text: String) throws {
    for c in text.unicodeScalars {
      guard self.current == c else {
        throw JSONParseError(description: "expected '\(text)' at \(self.index)")
      }
      self.index += 1
    }
  }

  mutating func parseValue() throws -> JSONValue {
    self.skipWhitespace()
    switch self.current {
      case "n":
        try self.expect("null")
        return .null
      case "t":
        try self.expect("true")
        return .bool(true)
      case "f":
        try self.expect("false")
        return .bool(false)
      case "\"":
        return .string(try self.parseString())
      case "[":
        self.index += 1
        var elements: [JSONValue] = []
        self.skipWhitespace()
        if self.current == "]" {
          self.index += 1
          return .array(elements)
        }
        while true {
          elements.append(try self.parseValue())
          self.skipWhitespace()
          if self.current == "," {
            self.index += 1
          } else {
            try self.expect("]")
            return .array(elements)
          }
        }
      case "{":
        self.index += 1
        var object: [String: JSONValue] = [:]
        self.skipWhitespace()
        if self.current == "}" {
          self.index += 1
          return .object(object)
        }
        while true {
          self.skipWhitespace()
          let key = try self.parseString()
          self.skipWhitespace()
          try self.expect(":")
          object[key] = try self.parseValue()
          self.skipWhitespace()
          if self.current == "," {
            self.index += 1
          } else {
            try self.expect("}")
            return .object(object)
          }
        }
      default:
        var text = ""
        while !self.isAtEnd && "+-0123456789.eE".unicodeScalars.contains(self.current) {
          text.unicodeScalars.append(self.current)
          self.index += 1
        }
        guard let number = Double(text) else {
          throw JSONParseError(description: "invalid number at \(self.index)")
        }
        return .number(number)
    }
  }

  mutating func parseString() throws -> String {
    try self.expect("\"")
    var result = String.UnicodeScalarView()
    var pendingHighSurrogate: UInt32? = nil
    while self.current != "\"" {
      guard !self.isAtEnd else {
        throw JSONParseError(description: "unterminated string")
      }
      var c = self.current
      self.index += 1
      if c == "\\" {
        let e = self.current
        self.index += 1
        switch e {
          case "n": c = "\n"
          case "t": c = "\t"
          case "r": c = "\r"
          case "b": c = "\u{08}"
          case "f": c = "\u{0C}"
          case "/": c = "/"
          case "\\": c = "\\"
          case "\"": c = "\""
          case "u":
            let hex = String(String.UnicodeScalarView(self.input[self.index..<self.index + 4]))
            self.index += 4
            let value = UInt32(hex, radix: 16) ?? 0
            if (0xD800...0xDBFF).contains(value) {
              pendingHighSurrogate = value
              continue
            } else if (0xDC00...0xDFFF).contains(value), let high = pendingHighSurrogate {
              c = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (value - 0xDC00)) ?? "?"
              pendingHighSurrogate = nil
            } else {
              c = Unicode.Scalar(value) ?? "?"
            }
          default:
            throw JSONParseError(description: "invalid escape")
        }
      }
      result.append(c)
    }
    self.index += 1
    return String(result)
  }
}
