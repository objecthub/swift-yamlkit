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
    let (encoding, bomLength) = Reader.detectEncoding([UInt8](data.prefix(4)))
    if encoding == .utf8 {
      return try Reader.decodeUTF8(data.dropFirst(bomLength))
    }
    let payload = Data(data.dropFirst(bomLength))
    guard let string = String(data: payload, encoding: encoding) else {
      throw YAMLError(.reader, "input is not valid \(Reader.name(of: encoding))")
    }
    return try Reader.normalize(string)
  }

  /// Decodes and normalizes UTF-8 in one pass; the same as
  /// `normalize(String(data: payload, encoding: .utf8))`: invalid UTF-8 is
  /// reported in preference to a non-printable character, and a byte order
  /// mark at the start of `payload` is skipped as Foundation does.
  private static func decodeUTF8(_ payload: Data) throws -> [Unicode.Scalar] {
    return try payload.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      // The first non-printable character; after it, the input is only
      // validated.
      var nonPrintable: Unicode.Scalar? = nil
      let result = try [Unicode.Scalar](unsafeUninitializedCapacity: bytes.count) { buffer, count in
        var i = 0
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
          i = 3
        }
        var previousWasCR = false
        while i < bytes.count {
          let scalar: Unicode.Scalar
          if bytes[i] < 0x80 {
            scalar = Unicode.Scalar(bytes[i])
            i += 1
          } else if let (value, length) = Reader.decodeMultiByte(bytes, at: i),
                    let multiByteScalar = Unicode.Scalar(value) {
            scalar = multiByteScalar
            i += length
          } else {
            throw YAMLError(.reader, "input is not valid UTF-8")
          }
          if nonPrintable != nil {
            continue
          }
          if scalar == "\r" {
            buffer[count] = "\n"
            count += 1
            previousWasCR = true
            continue
          } else if scalar == "\n" && previousWasCR {
            previousWasCR = false
            continue
          }
          previousWasCR = false
          guard Reader.isPrintable(scalar) else {
            nonPrintable = scalar
            continue
          }
          buffer[count] = scalar
          count += 1
        }
      }
      if let nonPrintable {
        // `result` ends before the character; derive its line and column.
        let lineStart = (result.lastIndex(of: "\n") ?? -1) + 1
        let line = 1 + result.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        throw YAMLError(.reader,
                        "invalid character U+\(String(nonPrintable.value, radix: 16, uppercase: true))",
                        at: Mark(offset: result.count, line: line, column: result.count - lineStart + 1))
      }
      return result
    }
  }

  /// Decodes the multi-byte sequence starting at `i`; returns `nil` if it is
  /// not well-formed (The Unicode Standard, table 3-7).
  @inline(__always)
  private static func decodeMultiByte(_ bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> (UInt32, Int)? {
    let first = bytes[i]
    func continuation(_ k: Int, _ low: UInt8 = 0x80, _ high: UInt8 = 0xBF) -> UInt32? {
      guard i + k < bytes.count, bytes[i + k] >= low, bytes[i + k] <= high else {
        return nil
      }
      return UInt32(bytes[i + k] & 0x3F)
    }
    switch first {
      case 0xC2...0xDF:
        guard let c1 = continuation(1) else {
          return nil
        }
        return ((UInt32(first & 0x1F) << 6) | c1, 2)
      case 0xE0...0xEF:
        let low: UInt8 = first == 0xE0 ? 0xA0 : 0x80
        let high: UInt8 = first == 0xED ? 0x9F : 0xBF
        guard let c1 = continuation(1, low, high), let c2 = continuation(2) else {
          return nil
        }
        return ((UInt32(first & 0x0F) << 12) | (c1 << 6) | c2, 3)
      case 0xF0...0xF4:
        let low: UInt8 = first == 0xF0 ? 0x90 : 0x80
        let high: UInt8 = first == 0xF4 ? 0x8F : 0xBF
        guard let c1 = continuation(1, low, high), let c2 = continuation(2), let c3 = continuation(3) else {
          return nil
        }
        return ((UInt32(first & 0x07) << 18) | (c1 << 12) | (c2 << 6) | c3, 4)
      default:
        return nil
    }
  }

  /// Converts `string` into a normalized array of Unicode scalars.
  static func normalize(_ string: String) throws -> [Unicode.Scalar] {
    var normalizer = Normalizer()
    normalizer.result.reserveCapacity(string.utf8.count)
    for scalar in string.unicodeScalars {
      try normalizer.add(scalar)
    }
    return normalizer.result
  }

  /// Normalizes line breaks and checks that all characters are printable.
  private struct Normalizer {
    var result: [Unicode.Scalar] = []
    var line = 1
    var column = 1
    var previousWasCR = false

    @inline(__always)
    mutating func add(_ scalar: Unicode.Scalar) throws {
      if scalar == "\r" {
        self.result.append("\n")
        self.previousWasCR = true
        self.line += 1
        self.column = 1
        return
      } else if scalar == "\n" && self.previousWasCR {
        self.previousWasCR = false
        return
      }
      self.previousWasCR = false
      guard Reader.isPrintable(scalar) else {
        throw YAMLError(.reader,
                        "invalid character U+\(String(scalar.value, radix: 16, uppercase: true))",
                        at: Mark(offset: self.result.count, line: self.line, column: self.column))
      }
      self.result.append(scalar)
      if scalar == "\n" {
        self.line += 1
        self.column = 1
      } else {
        self.column += 1
      }
    }
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
