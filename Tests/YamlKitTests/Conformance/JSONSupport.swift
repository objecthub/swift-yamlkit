//
//  JSONSupport.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import DynamicJSON
import YamlKit

extension JSON {

  /// Converts a node into the JSON data model based on its core schema tag.
  init(_ node: YAMLNode) {
    switch node {
      case .scalar(let scalar):
        switch scalar.tag {
          case .null:
            self = .null
          case .bool:
            self = .boolean(node.bool ?? false)
          case .int:
            if let int = CoreSchema.parseInteger(scalar.value, as: Int64.self) {
              self = .integer(int)
            } else {
              self = .float(node.double ?? .nan)
            }
          case .float:
            self = .float(node.double ?? .nan)
          default:
            self = .string(scalar.value)
        }
      case .sequence(let sequence):
        self = .array(sequence.elements.map(JSON.init))
      case .mapping(let mapping):
        var object: [String: JSON] = [:]
        for entry in mapping.entries {
          object[entry.key.string ?? entry.key.description] = JSON(entry.value)
        }
        self = .object(object)
    }
  }

  /// Parses a stream of whitespace-separated JSON values, as found in the
  /// `in.json` files of multi-document test cases.
  static func parseStream(_ text: String) throws -> [JSON] {
    return try JSON.split(text).map { try JSON(string: $0) }
  }

  /// Returns the value with all integers converted to floating-point
  /// numbers, so that numerically equal values compare equal (e.g. the YAML
  /// float `12.0` and the JSON number `12`).
  var withNormalizedNumbers: JSON {
    switch self {
      case .integer(let int):
        return .float(Double(int))
      case .array(let elements):
        return .array(elements.map(\.withNormalizedNumbers))
      case .object(let members):
        return .object(members.mapValues(\.withNormalizedNumbers))
      default:
        return self
    }
  }

  /// Splits a stream of JSON texts into the texts of the individual values by
  /// tracking strings and the nesting of arrays and objects. Top-level scalars
  /// are delimited by white space.
  private static func split(_ text: String) -> [String] {
    var values: [String] = []
    var current = String.UnicodeScalarView()
    var depth = 0
    var inString = false
    var isEscaped = false
    func finish() {
      if !current.isEmpty {
        values.append(String(current))
        current.removeAll()
      }
    }
    for c in text.unicodeScalars {
      if inString {
        current.append(c)
        if isEscaped {
          isEscaped = false
        } else if c == "\\" {
          isEscaped = true
        } else if c == "\"" {
          inString = false
          if depth == 0 {
            finish()
          }
        }
        continue
      }
      switch c {
        case " ", "\t", "\n", "\r":
          if depth == 0 {
            finish()
          } else {
            current.append(c)
          }
        case "\"":
          inString = true
          current.append(c)
        case "[", "{":
          depth += 1
          current.append(c)
        case "]", "}":
          depth -= 1
          current.append(c)
          if depth == 0 {
            finish()
          }
        default:
          current.append(c)
      }
    }
    finish()
    return values
  }
}
