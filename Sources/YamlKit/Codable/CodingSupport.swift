//
//  CodingSupport.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation

/// A coding key used for sequence indices and `super` keys.
struct YAMLCodingKey: CodingKey, Sendable {

  let stringValue: String
  let intValue: Int?

  init(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init(intValue: Int) {
    self.stringValue = "Index \(intValue)"
    self.intValue = intValue
  }

  init(index: Int) {
    self.init(intValue: index)
  }

  static let `super` = YAMLCodingKey(stringValue: "super")
}

// MARK: - Key conversion

/// Conversions between Swift-style camel case keys and the snake case and
/// kebab case keys commonly found in YAML files.
enum KeyConversion {

  /// Converts `camelCaseKey` into lower case words separated by `separator`,
  /// e.g. `myURLProperty` becomes `my_url_property`.
  static func convertFromCamelCase(_ key: String, separator: String) -> String {
    guard !key.isEmpty else {
      return key
    }
    var words: [Range<String.Index>] = []
    var wordStart = key.startIndex
    var searchRange = key.index(after: wordStart)..<key.endIndex
    while let upperCaseRange = key.rangeOfCharacter(from: .uppercaseLetters, options: [], range: searchRange) {
      words.append(wordStart..<upperCaseRange.lowerBound)
      searchRange = upperCaseRange.lowerBound..<searchRange.upperBound
      guard let lowerCaseRange = key.rangeOfCharacter(from: .lowercaseLetters,
                                                      options: [],
                                                      range: searchRange) else {
        wordStart = searchRange.lowerBound
        break
      }
      let nextCharacterAfterCapital = key.index(after: upperCaseRange.lowerBound)
      if lowerCaseRange.lowerBound == nextCharacterAfterCapital {
        // A single capital letter starts a new word.
        wordStart = upperCaseRange.lowerBound
      } else {
        // An acronym: the last capital letter starts the next word.
        let beforeLowerIndex = key.index(before: lowerCaseRange.lowerBound)
        words.append(upperCaseRange.lowerBound..<beforeLowerIndex)
        wordStart = beforeLowerIndex
      }
      searchRange = lowerCaseRange.upperBound..<searchRange.upperBound
    }
    words.append(wordStart..<searchRange.upperBound)
    return words.map { key[$0].lowercased() }.joined(separator: separator)
  }

  /// Converts a key consisting of words separated by `separator` into camel
  /// case, e.g. `my_property` becomes `myProperty`. Leading and trailing
  /// separators are preserved.
  static func convertToCamelCase(_ key: String, separator: Character) -> String {
    guard let first = key.firstIndex(where: { $0 != separator }) else {
      return key
    }
    var last = key.index(before: key.endIndex)
    while last > first && key[last] == separator {
      key.formIndex(before: &last)
    }
    let keyRange = first...last
    let components = key[keyRange].split(separator: separator)
    let joined: String
    if components.count == 1 {
      joined = String(key[keyRange])
    } else {
      joined = ([components[0].lowercased()] + components[1...].map(\.capitalized)).joined()
    }
    return String(key[..<first]) + joined + String(key[key.index(after: last)...])
  }
}

// MARK: - Timestamps

/// Parsing and formatting of YAML timestamps
/// (https://yaml.org/type/timestamp.html), which extend ISO 8601.
enum Timestamp {

  /// Parses a timestamp such as `2001-12-14`, `2001-12-14t21:59:43.10-05:00`,
  /// or `2001-12-14 21:59:43.10 -5`. Times without a time zone are
  /// interpreted as UTC.
  static func parse(_ string: String) -> Date? {
    var s = Substring(string)
    func number(minDigits: Int, maxDigits: Int) -> Int? {
      let digits = s.prefix(while: \.isASCIIDigit).prefix(maxDigits)
      guard digits.count >= minDigits else {
        return nil
      }
      s = s.dropFirst(digits.count)
      return Int(digits)
    }
    func consume(_ c: Character) -> Bool {
      guard s.first == c else {
        return false
      }
      s = s.dropFirst()
      return true
    }
    guard let year = number(minDigits: 4, maxDigits: 4), consume("-"),
          let month = number(minDigits: 1, maxDigits: 2), consume("-"),
          let day = number(minDigits: 1, maxDigits: 2) else {
      return nil
    }
    var components = DateComponents(calendar: Calendar(identifier: .gregorian),
                                    timeZone: TimeZone(secondsFromGMT: 0),
                                    year: year, month: month, day: day,
                                    hour: 0, minute: 0, second: 0)
    var fraction = 0.0
    var offset = 0
    if !s.isEmpty {
      // Time part.
      if s.first == "T" || s.first == "t" {
        s = s.dropFirst()
      } else {
        let blanks = s.prefix(while: { $0 == " " || $0 == "\t" })
        guard !blanks.isEmpty else {
          return nil
        }
        s = s.dropFirst(blanks.count)
      }
      guard let hour = number(minDigits: 1, maxDigits: 2), consume(":"),
            let minute = number(minDigits: 2, maxDigits: 2), consume(":"),
            let second = number(minDigits: 2, maxDigits: 2) else {
        return nil
      }
      components.hour = hour
      components.minute = minute
      components.second = second
      if consume(".") {
        let digits = s.prefix(while: \.isASCIIDigit)
        s = s.dropFirst(digits.count)
        fraction = Double("0." + digits) ?? 0
      }
      s = s.drop(while: { $0 == " " || $0 == "\t" })
      if consume("Z") || consume("z") {
        offset = 0
      } else if let sign = s.first, sign == "+" || sign == "-" {
        s = s.dropFirst()
        guard let hours = number(minDigits: 1, maxDigits: 2) else {
          return nil
        }
        var minutes = 0
        if consume(":") {
          guard let m = number(minDigits: 2, maxDigits: 2) else {
            return nil
          }
          minutes = m
        }
        offset = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
      }
    }
    guard s.isEmpty, components.isValidDate, let date = components.date else {
      return nil
    }
    return date.addingTimeInterval(fraction - Double(offset))
  }

  /// Formats `date` as an ISO 8601 timestamp in UTC. Fractional seconds are
  /// only included if they are non-zero.
  static func format(_ date: Date) -> String {
    let seconds = date.timeIntervalSince1970
    if seconds == seconds.rounded(.down) {
      return date.formatted(Date.ISO8601FormatStyle())
    }
    return date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
  }
}
