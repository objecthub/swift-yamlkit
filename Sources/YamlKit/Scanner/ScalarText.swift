//
//  ScalarText.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// The text of a scalar while it is scanned, collected as UTF-8.
///
/// Appending to a byte array and creating the string once is considerably
/// faster than appending to a `String.UnicodeScalarView` character by
/// character.
struct ScalarText {

  /// The UTF-8 encoding of the text.
  private(set) var bytes: [UInt8] = []

  var isEmpty: Bool {
    return self.bytes.isEmpty
  }

  @inline(__always)
  mutating func append(_ c: Unicode.Scalar) {
    let value = c.value
    if value < 0x80 {
      self.bytes.append(UInt8(truncatingIfNeeded: value))
    } else if value < 0x800 {
      self.bytes.append(UInt8(truncatingIfNeeded: 0xC0 | (value >> 6)))
      self.bytes.append(UInt8(truncatingIfNeeded: 0x80 | (value & 0x3F)))
    } else if value < 0x10000 {
      self.bytes.append(UInt8(truncatingIfNeeded: 0xE0 | (value >> 12)))
      self.bytes.append(UInt8(truncatingIfNeeded: 0x80 | ((value >> 6) & 0x3F)))
      self.bytes.append(UInt8(truncatingIfNeeded: 0x80 | (value & 0x3F)))
    } else {
      self.bytes.append(UInt8(truncatingIfNeeded: 0xF0 | (value >> 18)))
      self.bytes.append(UInt8(truncatingIfNeeded: 0x80 | ((value >> 12) & 0x3F)))
      self.bytes.append(UInt8(truncatingIfNeeded: 0x80 | ((value >> 6) & 0x3F)))
      self.bytes.append(UInt8(truncatingIfNeeded: 0x80 | (value & 0x3F)))
    }
  }

  mutating func append(contentsOf text: ScalarText) {
    self.bytes.append(contentsOf: text.bytes)
  }

  mutating func removeAll() {
    self.bytes.removeAll(keepingCapacity: true)
  }
}

extension String {

  /// Creates the string of a scanned scalar.
  init(_ text: ScalarText) {
    self = String(decoding: text.bytes, as: UTF8.self)
  }
}
