//
//  Reader.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation

/// Converts raw input into the normalized sequence of Unicode scalars that is
/// consumed by the ``Scanner``.
///
/// The reader implements the character-level requirements of YAML 1.2.2,
/// chapter 5:
///
/// - Encoding detection based on the byte order mark or the pattern of null
///   bytes at the beginning of the stream (section 5.2). UTF-8, UTF-16 and
///   UTF-32 in both byte orders are supported.
/// - Verification that all characters are printable (section 5.1).
/// - Normalization of line breaks: `CR LF` and `CR` are converted to `LF`
///   (section 5.4).
enum Reader {

  /// Decodes `data` into a normalized array of Unicode scalars.
  static func decode(_ data: Data) throws -> [Unicode.Scalar] {
    let bytes = [UInt8](data)
    let (encoding, bomLength) = Reader.detectEncoding(bytes)
    let payload = Data(bytes[bomLength...])
    guard let string = String(data: payload, encoding: encoding) else {
      throw YAMLError(.reader, "input is not valid \(Reader.name(of: encoding))")
    }
    return try Reader.normalize(string)
  }

  /// Converts `string` into a normalized array of Unicode scalars.
  static func normalize(_ string: String) throws -> [Unicode.Scalar] {
    var result: [Unicode.Scalar] = []
    result.reserveCapacity(string.unicodeScalars.count)
    var line = 1
    var column = 1
    var previousWasCR = false
    for scalar in string.unicodeScalars {
      if scalar == "\r" {
        result.append("\n")
        previousWasCR = true
        line += 1
        column = 1
        continue
      } else if scalar == "\n" && previousWasCR {
        previousWasCR = false
        continue
      }
      previousWasCR = false
      guard Reader.isPrintable(scalar) else {
        throw YAMLError(.reader,
                        "invalid character U+\(String(scalar.value, radix: 16, uppercase: true))",
                        at: Mark(offset: result.count, line: line, column: column))
      }
      result.append(scalar)
      if scalar == "\n" {
        line += 1
        column = 1
      } else {
        column += 1
      }
    }
    return result
  }

  /// Returns `true` if `scalar` matches production [1] `c-printable`.
  @inline(__always)
  static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
      case 0x09, 0x0A, 0x0D, 0x20...0x7E, 0x85, 0xA0...0xD7FF, 0xE000...0xFFFD,
           0x10000...0x10FFFF:
        return true
      default:
        return false
    }
  }

  /// Detects the character encoding of `bytes` following the rules of
  /// section 5.2. Returns the encoding and the length of the byte order mark.
  static func detectEncoding(_ bytes: [UInt8]) -> (String.Encoding, Int) {
    func byte(_ i: Int) -> UInt8? {
      return i < bytes.count ? bytes[i] : nil
    }
    switch (byte(0), byte(1), byte(2), byte(3)) {
      case (0x00, 0x00, 0xFE, 0xFF):
        return (.utf32BigEndian, 4)
      case (0x00, 0x00, 0x00, .some):
        return (.utf32BigEndian, 0)
      case (0xFF, 0xFE, 0x00, 0x00):
        return (.utf32LittleEndian, 4)
      case (.some, 0x00, 0x00, 0x00):
        return (.utf32LittleEndian, 0)
      case (0xFE, 0xFF, _, _):
        return (.utf16BigEndian, 2)
      case (0x00, .some, _, _):
        return (.utf16BigEndian, 0)
      case (0xFF, 0xFE, _, _):
        return (.utf16LittleEndian, 2)
      case (.some, 0x00, _, _):
        return (.utf16LittleEndian, 0)
      case (0xEF, 0xBB, 0xBF, _):
        return (.utf8, 3)
      default:
        return (.utf8, 0)
    }
  }

  private static func name(of encoding: String.Encoding) -> String {
    switch encoding {
      case .utf16BigEndian:
        return "UTF-16BE"
      case .utf16LittleEndian:
        return "UTF-16LE"
      case .utf32BigEndian:
        return "UTF-32BE"
      case .utf32LittleEndian:
        return "UTF-32LE"
      default:
        return "UTF-8"
    }
  }
}
