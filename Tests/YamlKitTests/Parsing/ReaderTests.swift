//
//  ReaderTests.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation
import Testing
@testable import YamlKit

@Suite("Reader")
struct ReaderTests {

  private static let text = "key: välue 😀\n"

  @Test("Detects encodings", arguments: [
    (String.Encoding.utf8, false),
    (.utf8, true),
    (.utf16BigEndian, false),
    (.utf16BigEndian, true),
    (.utf16LittleEndian, false),
    (.utf16LittleEndian, true),
    (.utf32BigEndian, false),
    (.utf32BigEndian, true),
    (.utf32LittleEndian, false),
    (.utf32LittleEndian, true)
  ])
  func detectsEncodings(encoding: String.Encoding, withBOM: Bool) throws {
    let data = try #require((withBOM ? "\u{FEFF}" + ReaderTests.text : ReaderTests.text)
      .data(using: encoding))
    let scalars = try Reader.decode(data)
    #expect(String(String.UnicodeScalarView(scalars)) == ReaderTests.text)
  }

  @Test("Normalizes line breaks")
  func normalizesLineBreaks() throws {
    let scalars = try Reader.normalize("a\r\nb\rc\nd")
    #expect(String(String.UnicodeScalarView(scalars)) == "a\nb\nc\nd")
  }

  @Test("Rejects non-printable characters with a location")
  func rejectsNonPrintableCharacters() {
    #expect {
      _ = try Reader.normalize("a: b\nc: \u{07}")
    } throws: { error in
      guard let error = error as? YAMLError else {
        return false
      }
      return error.kind == .reader && error.mark?.line == 2 && error.mark?.column == 4
    }
  }

  @Test("Rejects invalid UTF-8")
  func rejectsInvalidUTF8() {
    #expect(throws: YAMLError.self) {
      _ = try Reader.decode(Data([0x61, 0x3A, 0x20, 0xFF, 0xFE, 0x0A, 0x41]))
    }
  }
}
