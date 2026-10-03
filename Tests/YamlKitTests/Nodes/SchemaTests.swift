//
//  SchemaTests.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Testing
@testable import YamlKit

@Suite("Schemas")
struct SchemaTests {

  @Test("Core schema resolution", arguments: [
    ("", YAMLTag.null), ("~", .null), ("null", .null), ("Null", .null), ("NULL", .null),
    ("nULL", .str),
    ("true", .bool), ("True", .bool), ("TRUE", .bool), ("false", .bool), ("FALSE", .bool),
    ("yes", .str), ("on", .str), ("tRUE", .str),
    ("0", .int), ("-19", .int), ("+12", .int), ("007", .int), ("0o14", .int), ("0x1F", .int),
    ("0o8", .str), ("0xG", .str), ("1_000", .str), ("0b101", .str),
    ("1.0", .float), ("-1.5e3", .float), (".5", .float), ("1.", .float), ("1e10", .float),
    (".inf", .float), ("-.Inf", .float), ("+.INF", .float), (".nan", .float), (".NaN", .float),
    ("-.nan", .str), (".", .str), ("1e", .str), ("e1", .str), ("1.2.3", .str),
    ("hello", .str), ("12:30", .str)
  ])
  func coreSchema(value: String, tag: YAMLTag) {
    #expect(CoreSchema().tag(forPlainScalar: value) == tag)
  }

  @Test("JSON schema resolution", arguments: [
    ("null", YAMLTag.null), ("Null", .str), ("~", .str), ("", .str),
    ("true", .bool), ("True", .str),
    ("0", .int), ("-1", .int), ("01", .str), ("+1", .str), ("0x1", .str),
    ("1.5", .float), ("-0.5e-3", .float), ("1e3", .float), (".5", .str), (".inf", .str)
  ])
  func jsonSchema(value: String, tag: YAMLTag) {
    #expect(JSONSchema().tag(forPlainScalar: value) == tag)
  }

  @Test("Failsafe schema resolution")
  func failsafeSchema() {
    for value in ["", "null", "true", "1", "1.0"] {
      #expect(FailsafeSchema().tag(forPlainScalar: value) == .str)
    }
  }

  @Test("Integer parsing")
  func integerParsing() {
    #expect(CoreSchema.parseInteger("0x1F", as: Int.self) == 31)
    #expect(CoreSchema.parseInteger("0o17", as: Int.self) == 15)
    #expect(CoreSchema.parseInteger("-128", as: Int8.self) == -128)
    #expect(CoreSchema.parseInteger("128", as: Int8.self) == nil)
    #expect(CoreSchema.parseInteger("+42", as: UInt.self) == 42)
    #expect(CoreSchema.parseInteger("-1", as: UInt.self) == nil)
    #expect(CoreSchema.parseInteger("1.0", as: Int.self) == nil)
  }

  @Test("Float parsing")
  func floatParsing() {
    #expect(CoreSchema.parseFloat("1.5") == 1.5)
    #expect(CoreSchema.parseFloat("+1.5") == 1.5)
    #expect(CoreSchema.parseFloat(".5") == 0.5)
    #expect(CoreSchema.parseFloat("-.inf") == -.infinity)
    #expect(CoreSchema.parseFloat(".nan")?.isNaN == true)
    #expect(CoreSchema.parseFloat("0x10") == 16)
    #expect(CoreSchema.parseFloat("abc") == nil)
  }
}
