//
//  YAMLSchema.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// A schema determines how untagged plain scalars are resolved to tags
/// (YAML 1.2.2, chapter 10).
///
/// YamlKit provides the three schemas defined by the specification:
/// ``FailsafeSchema``, ``JSONSchema``, and ``CoreSchema`` (the default).
/// Custom schemas can be implemented by conforming to this protocol, e.g. to
/// support YAML 1.1 booleans such as `yes` and `no`.
///
/// YAMLTag resolution for all other nodes is fixed by the specification:
/// non-plain untagged scalars and scalars with the non-specific tag `!` are
/// strings, untagged sequences are `!!seq`, and untagged mappings are
/// `!!map`.
public protocol YAMLSchema: Sendable {

  /// Returns the tag of an untagged plain scalar with the given value.
  func tag(forPlainScalar value: String) -> YAMLTag
}

extension YAMLSchema where Self == CoreSchema {

  /// The core schema (YAML 1.2.2, section 10.3), which is the default.
  public static var core: CoreSchema {
    return CoreSchema()
  }
}

extension YAMLSchema where Self == JSONSchema {

  /// The JSON schema (YAML 1.2.2, section 10.2).
  public static var json: JSONSchema {
    return JSONSchema()
  }
}

extension YAMLSchema where Self == FailsafeSchema {

  /// The failsafe schema (YAML 1.2.2, section 10.1).
  public static var failsafe: FailsafeSchema {
    return FailsafeSchema()
  }
}

/// The failsafe schema (YAML 1.2.2, section 10.1): all scalars are strings.
public struct FailsafeSchema: YAMLSchema {

  /// Creates the failsafe schema.
  public init() {}

  public func tag(forPlainScalar value: String) -> YAMLTag {
    return .str
  }
}

/// The JSON schema (YAML 1.2.2, section 10.2): plain scalars are resolved
/// using the strict JSON syntax for `null`, booleans, and numbers. Other
/// plain scalars, which are invalid according to the specification, are
/// resolved as strings.
public struct JSONSchema: YAMLSchema {

  /// Creates the JSON schema.
  public init() {}

  public func tag(forPlainScalar value: String) -> YAMLTag {
    switch value {
      case "null":
        return .null
      case "true", "false":
        return .bool
      default:
        break
      }
    var s = Substring(value)[...]
    if s.first == "-" {
      s = s.dropFirst()
    }
    // -? ( 0 | [1-9] [0-9]* )
    guard let first = s.first, first.isASCIIDigit else {
      return .str
    }
    if first == "0" {
      s = s.dropFirst()
    } else {
      s = s.drop(while: \.isASCIIDigit)
    }
    if s.isEmpty {
      return .int
    }
    // ( \. [0-9]* )? ( [eE] [-+]? [0-9]+ )?
    if s.first == "." {
      s = s.dropFirst().drop(while: \.isASCIIDigit)
    }
    if s.first == "e" || s.first == "E" {
      s = s.dropFirst()
      if s.first == "-" || s.first == "+" {
        s = s.dropFirst()
      }
      guard s.first?.isASCIIDigit ?? false else {
        return .str
      }
      s = s.drop(while: \.isASCIIDigit)
    }
    return s.isEmpty ? .float : .str
  }
}

/// The core schema (YAML 1.2.2, section 10.3), which extends the JSON schema
/// with more human-readable notations:
///
/// | YAMLTag      | Plain scalars                                               |
/// |----------|-------------------------------------------------------------|
/// | `!!null` | `null`, `Null`, `NULL`, `~`, and the empty scalar           |
/// | `!!bool` | `true`, `True`, `TRUE`, `false`, `False`, `FALSE`           |
/// | `!!int`  | `[-+]?[0-9]+`, `0o[0-7]+`, `0x[0-9a-fA-F]+`                  |
/// | `!!float`| `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`, `[-+]?\.inf`, `.nan` (in three capitalizations each) |
/// | `!!str`  | everything else                                             |
public struct CoreSchema: YAMLSchema {

  /// Creates the core schema.
  public init() {}

  public func tag(forPlainScalar value: String) -> YAMLTag {
    if CoreSchema.isNull(value) {
      return .null
    } else if CoreSchema.parseBool(value) != nil {
      return .bool
    } else if CoreSchema.isInteger(value) {
      return .int
    } else if CoreSchema.isFloat(value) {
      return .float
    }
    return .str
  }

  /// Does `value` represent `null`?
  public static func isNull(_ value: String) -> Bool {
    switch value {
      case "", "~", "null", "Null", "NULL":
        return true
      default:
        return false
    }
  }

  /// Returns the boolean represented by `value`, if any.
  public static func parseBool(_ value: String) -> Bool? {
    switch value {
      case "true", "True", "TRUE":
        return true
      case "false", "False", "FALSE":
        return false
      default:
        return nil
    }
  }

  /// Does `value` match one of the core schema integer notations?
  public static func isInteger(_ value: String) -> Bool {
    return CoreSchema.integerComponents(value) != nil
  }

  /// Splits an integer literal into sign, digits, and radix.
  static func integerComponents(_ value: String) -> (isNegative: Bool, digits: Substring, radix: Int)? {
    var s = Substring(value)
    if s.hasPrefix("0o") {
      s = s.dropFirst(2)
      guard !s.isEmpty, s.allSatisfy({ ("0"..."7").contains($0) }) else {
        return nil
      }
      return (false, s, 8)
    } else if s.hasPrefix("0x") {
      s = s.dropFirst(2)
      guard !s.isEmpty, s.allSatisfy(\.isHexDigit) else {
        return nil
      }
      return (false, s, 16)
    }
    var isNegative = false
    if s.first == "-" || s.first == "+" {
      isNegative = s.first == "-"
      s = s.dropFirst()
    }
    guard !s.isEmpty, s.allSatisfy(\.isASCIIDigit) else {
      return nil
    }
    return (isNegative, s, 10)
  }

  /// Parses an integer in one of the core schema notations, returning `nil`
  /// if `value` is not an integer or does not fit into `T`.
  public static func parseInteger<T: FixedWidthInteger>(_ value: String, as type: T.Type) -> T? {
    guard let (isNegative, digits, radix) = CoreSchema.integerComponents(value) else {
      return nil
    }
    if isNegative {
      return T("-" + digits, radix: radix)
    }
    return T(digits, radix: radix)
  }

  /// Does `value` match one of the core schema float notations?
  public static func isFloat(_ value: String) -> Bool {
    var s = Substring(value)
    if s.first == "-" || s.first == "+" {
      s = s.dropFirst()
    }
    switch s {
      case ".inf", ".Inf", ".INF":
        return true
      case ".nan", ".NaN", ".NAN":
        return s.count == value.count
      default:
        break
    }
    // ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?
    var hasDigits = false
    let integerPart = s.prefix(while: \.isASCIIDigit)
    hasDigits = !integerPart.isEmpty
    s = s.dropFirst(integerPart.count)
    if s.first == "." {
      s = s.dropFirst()
      let fraction = s.prefix(while: \.isASCIIDigit)
      if !hasDigits && fraction.isEmpty {
        return false
      }
      hasDigits = true
      s = s.dropFirst(fraction.count)
    }
    guard hasDigits else {
      return false
    }
    if s.first == "e" || s.first == "E" {
      s = s.dropFirst()
      if s.first == "-" || s.first == "+" {
        s = s.dropFirst()
      }
      let exponent = s.prefix(while: \.isASCIIDigit)
      guard !exponent.isEmpty else {
        return false
      }
      s = s.dropFirst(exponent.count)
    }
    return s.isEmpty
  }

  /// Parses a number in one of the core schema float or integer notations.
  public static func parseFloat(_ value: String) -> Double? {
    var s = Substring(value)
    var sign = 1.0
    if s.first == "-" || s.first == "+" {
      sign = s.first == "-" ? -1.0 : 1.0
      s = s.dropFirst()
    }
    switch s {
      case ".inf", ".Inf", ".INF":
        return sign * Double.infinity
      case ".nan", ".NaN", ".NAN":
        return Double.nan
      default:
        break
    }
    if CoreSchema.isFloat(value) {
      return Double(value.hasPrefix("+") ? String(value.dropFirst()) : value)
        ?? Double("0" + value)
    }
    if let (isNegative, digits, radix) = CoreSchema.integerComponents(value) {
      if radix == 10 {
        return Double(String(digits)).map { isNegative ? -$0 : $0 }
      }
      var result = 0.0
      for digit in digits {
        result = result * Double(radix) + Double(digit.hexDigitValue ?? 0)
      }
      return isNegative ? -result : result
    }
    return nil
  }
}

extension Character {

  /// Is the character an ASCII decimal digit?
  var isASCIIDigit: Bool {
    return self >= "0" && self <= "9"
  }
}
