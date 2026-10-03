//
//  YAMLDecoderImpl.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation

/// The `Decoder` implementation used by ``YAMLDecoder``. Each instance
/// decodes a single node at a given coding path.
final class YAMLDecoderImpl: Decoder {

  /// The node being decoded.
  let node: YAMLNode

  /// The decoder configuration.
  let options: YAMLDecoder.Options

  let codingPath: [any CodingKey]

  var userInfo: [CodingUserInfoKey: Any] {
    return self.options.userInfo
  }

  init(node: YAMLNode, options: YAMLDecoder.Options, codingPath: [any CodingKey]) {
    self.node = node
    self.options = options
    self.codingPath = codingPath
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    guard case .mapping(let mapping) = self.node else {
      throw self.mismatch([String: Any].self, self.node, at: self.codingPath)
    }
    return KeyedDecodingContainer(YAMLKeyedDecodingContainer<Key>(decoder: self, mapping: mapping))
  }

  func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
    guard case .sequence(let sequence) = self.node else {
      throw self.mismatch([Any].self, self.node, at: self.codingPath)
    }
    return YAMLUnkeyedDecodingContainer(decoder: self, elements: sequence.elements)
  }

  func singleValueContainer() throws -> any SingleValueDecodingContainer {
    return self
  }

  // MARK: - Errors

  /// Returns a type mismatch error, or a `valueNotFound` error if the node
  /// is null.
  func mismatch(_ type: Any.Type, _ node: YAMLNode, at path: [any CodingKey]) -> DecodingError {
    if self.isNull(node) {
      return DecodingError.valueNotFound(
        type,
        DecodingError.Context(codingPath: path,
                              debugDescription: "Expected \(type) value but found null instead."))
    }
    let found: String
    switch node {
      case .scalar(let scalar):
        found = "a scalar of type \(scalar.tag)"
      case .sequence:
        found = "a sequence"
      case .mapping:
        found = "a mapping"
    }
    return DecodingError.typeMismatch(
      type,
      DecodingError.Context(codingPath: path,
                            debugDescription: "Expected to decode \(type) but found \(found) instead\(YAMLDecoderImpl.location(of: node))."))
  }

  func corrupted(_ message: String, _ node: YAMLNode, at path: [any CodingKey]) -> DecodingError {
    return DecodingError.dataCorrupted(
      DecodingError.Context(codingPath: path,
                            debugDescription: message + YAMLDecoderImpl.location(of: node)))
  }

  private static func location(of node: YAMLNode) -> String {
    guard let mark = node.mark else {
      return ""
    }
    return " (\(mark))"
  }

  // MARK: - Scalar interpretation

  /// Returns the tag used to interpret a scalar. Scalars with tags outside of
  /// the core schema (e.g. local tags) are interpreted like untagged plain
  /// scalars.
  func effectiveTag(of scalar: YAMLNode.Scalar) -> YAMLTag {
    switch scalar.tag {
      case .str, .null, .bool, .int, .float:
        return scalar.tag
      default:
        return self.options.parseOptions.schema.tag(forPlainScalar: scalar.value)
    }
  }

  func isNull(_ node: YAMLNode) -> Bool {
    guard case .scalar(let scalar) = node else {
      return false
    }
    return self.effectiveTag(of: scalar) == .null
  }

  func unboxString(_ node: YAMLNode, at path: [any CodingKey]) throws -> String {
    guard case .scalar(let scalar) = node, self.effectiveTag(of: scalar) != .null else {
      throw self.mismatch(String.self, node, at: path)
    }
    return scalar.value
  }

  func unboxBool(_ node: YAMLNode, at path: [any CodingKey]) throws -> Bool {
    guard case .scalar(let scalar) = node, self.effectiveTag(of: scalar) == .bool else {
      throw self.mismatch(Bool.self, node, at: path)
    }
    // The schema determined that the scalar is a boolean; accept the core
    // schema notations as well as the YAML 1.1 notations used by custom
    // schemas.
    switch scalar.value.lowercased() {
      case "true", "yes", "y", "on":
        return true
      case "false", "no", "n", "off":
        return false
      default:
        throw self.corrupted("Invalid boolean '\(scalar.value)'.", node, at: path)
    }
  }

  func unboxInteger<T: FixedWidthInteger>(_ node: YAMLNode, as type: T.Type, at path: [any CodingKey]) throws -> T {
    guard case .scalar(let scalar) = node else {
      throw self.mismatch(type, node, at: path)
    }
    switch self.effectiveTag(of: scalar) {
      case .int:
        if let value = CoreSchema.parseInteger(scalar.value, as: type) {
          return value
        }
        throw self.corrupted("Parsed YAML number <\(scalar.value)> does not fit in \(type).", node, at: path)
      case .float:
        if let double = CoreSchema.parseFloat(scalar.value), let value = T(exactly: double) {
          return value
        }
        throw self.corrupted("Parsed YAML number <\(scalar.value)> does not fit in \(type).", node, at: path)
      default:
        throw self.mismatch(type, node, at: path)
    }
  }

  func unboxFloat<T: BinaryFloatingPoint>(_ node: YAMLNode, as type: T.Type, at path: [any CodingKey]) throws -> T {
    guard case .scalar(let scalar) = node else {
      throw self.mismatch(type, node, at: path)
    }
    switch self.effectiveTag(of: scalar) {
      case .int, .float:
        guard let double = CoreSchema.parseFloat(scalar.value) else {
          throw self.corrupted("Invalid number <\(scalar.value)>.", node, at: path)
        }
        let value = T(double)
        if double.isFinite && !value.isFinite {
          throw self.corrupted("Parsed YAML number <\(scalar.value)> does not fit in \(type).", node, at: path)
        }
        return value
      default:
        throw self.mismatch(type, node, at: path)
    }
  }

  // MARK: - Unboxing values

  /// Decodes a value of type `T` from `node`, special-casing the Foundation
  /// types that have a natural YAML representation.
  ///
  /// If `path` is `nil`, `node` must be the node of this decoder.
  func unbox<T: Decodable>(_ node: YAMLNode, as type: T.Type, at codingPath: [any CodingKey]? = nil) throws -> T {
    let path = codingPath ?? self.codingPath
    switch type {
      case is Date.Type:
        return try self.unboxDate(node, at: path) as! T
      case is Data.Type:
        return try self.unboxData(node, at: path) as! T
      case is URL.Type:
        let string = try self.unboxString(node, at: path)
        guard let url = URL(string: string) else {
          throw self.corrupted("Invalid URL string.", node, at: path)
        }
        return url as! T
      case is Decimal.Type:
        guard case .scalar(let scalar) = node,
              [.int, .float].contains(self.effectiveTag(of: scalar)) else {
          throw self.mismatch(type, node, at: path)
        }
        guard let decimal = Decimal(string: scalar.value, locale: Locale(identifier: "en_US_POSIX")) else {
          throw self.corrupted("Invalid decimal number <\(scalar.value)>.", node, at: path)
        }
        return decimal as! T
      default:
        let decoder = codingPath == nil ? self : self.decoder(for: node, at: path)
        return try T(from: decoder)
    }
  }

  private func unboxDate(_ node: YAMLNode, at path: [any CodingKey]) throws -> Date {
    switch self.options.dateDecodingStrategy {
      case .timestamp:
        let string = try self.unboxString(node, at: path)
        guard let date = Timestamp.parse(string) else {
          throw self.corrupted("Expected date string to be a YAML timestamp.", node, at: path)
        }
        return date
      case .deferredToDate:
        return try Date(from: self.decoder(for: node, at: path))
      case .secondsSince1970:
        return Date(timeIntervalSince1970: try self.unboxFloat(node, as: Double.self, at: path))
      case .millisecondsSince1970:
        return Date(timeIntervalSince1970: try self.unboxFloat(node, as: Double.self, at: path) / 1000)
      case .iso8601:
        let string = try self.unboxString(node, at: path)
        guard let date = try? Date.ISO8601FormatStyle().parse(string) else {
          throw self.corrupted("Expected date string to be ISO8601-formatted.", node, at: path)
        }
        return date
      case .formatted(let formatter):
        let string = try self.unboxString(node, at: path)
        guard let date = formatter.date(from: string) else {
          throw self.corrupted("Date string does not match format expected by formatter.", node, at: path)
        }
        return date
      case .custom(let closure):
        return try closure(self.decoder(for: node, at: path))
    }
  }

  private func unboxData(_ node: YAMLNode, at path: [any CodingKey]) throws -> Data {
    switch self.options.dataDecodingStrategy {
      case .base64:
        let string = try self.unboxString(node, at: path)
        let stripped = string.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: stripped) else {
          throw self.corrupted("Encountered Data is not valid Base64.", node, at: path)
        }
        return data
      case .deferredToData:
        return try Data(from: self.decoder(for: node, at: path))
      case .custom(let closure):
        return try closure(self.decoder(for: node, at: path))
    }
  }

  private func decoder(for node: YAMLNode, at path: [any CodingKey]) -> YAMLDecoderImpl {
    return YAMLDecoderImpl(node: node, options: self.options, codingPath: path)
  }
}

// MARK: - Single value container

extension YAMLDecoderImpl: SingleValueDecodingContainer {

  func decodeNil() -> Bool {
    return self.isNull(self.node)
  }

  func decode(_ type: Bool.Type) throws -> Bool {
    return try self.unboxBool(self.node, at: self.codingPath)
  }

  func decode(_ type: String.Type) throws -> String {
    return try self.unboxString(self.node, at: self.codingPath)
  }

  func decode(_ type: Double.Type) throws -> Double {
    return try self.unboxFloat(self.node, as: type, at: self.codingPath)
  }

  func decode(_ type: Float.Type) throws -> Float {
    return try self.unboxFloat(self.node, as: type, at: self.codingPath)
  }

  func decode(_ type: Int.Type) throws -> Int {
    return try self.unboxInteger(self.node, as: type, at: self.codingPath)
  }

  func decode(_ type: Int8.Type) throws -> Int8 {
    return try self.unboxInteger(self.node, as: type, at: self.codingPath)
  }

  func decode(_ type: Int16.Type) throws -> Int16 {
    return try self.unboxInteger(self.node, as: type, at: self.codingPath)
  }

  func decode(_ type: Int32.Type) throws -> Int32 {
    return try self.unboxInteger(self.node, as: type, at: self.codingPath)
  }

  func decode(_ type: Int64.Type) throws -> Int64 {
    return try self.unboxInteger(self.node, as: type, at: self.codingPath)
  }

  func decode(_ type: UInt.Type) throws -> UInt {
    return try self.unboxInteger(self.node, as: type, at: self.codingPath)
  }

  func decode(_ type: UInt8.Type) throws -> UInt8 {
    return try self.unboxInteger(self.node, as: type, at: self.codingPath)
  }

  func decode(_ type: UInt16.Type) throws -> UInt16 {
    return try self.unboxInteger(self.node, as: type, at: self.codingPath)
  }

  func decode(_ type: UInt32.Type) throws -> UInt32 {
    return try self.unboxInteger(self.node, as: type, at: self.codingPath)
  }

  func decode(_ type: UInt64.Type) throws -> UInt64 {
    return try self.unboxInteger(self.node, as: type, at: self.codingPath)
  }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    return try self.unbox(self.node, as: type)
  }
}

// MARK: - Keyed container

/// Decodes the entries of a mapping. Only entries with scalar keys can be
/// accessed; the key's textual value is used as the coding key.
struct YAMLKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {

  let decoder: YAMLDecoderImpl
  let codingPath: [any CodingKey]
  private let keys: [String]
  private let entries: [String: YAMLNode]

  init(decoder: YAMLDecoderImpl, mapping: YAMLNode.Mapping) {
    self.decoder = decoder
    self.codingPath = decoder.codingPath
    var keys: [String] = []
    var entries: [String: YAMLNode] = [:]
    for entry in mapping.entries {
      guard case .scalar(let scalar) = entry.key else {
        continue
      }
      let key: String
      switch decoder.options.keyDecodingStrategy {
        case .useDefaultKeys:
          key = scalar.value
        case .convertFromSnakeCase:
          key = KeyConversion.convertToCamelCase(scalar.value, separator: "_")
        case .convertFromKebabCase:
          key = KeyConversion.convertToCamelCase(scalar.value, separator: "-")
        case .custom(let convert):
          key = convert(decoder.codingPath + [YAMLCodingKey(stringValue: scalar.value)]).stringValue
      }
      if entries.updateValue(entry.value, forKey: key) == nil {
        keys.append(key)
      }
    }
    self.keys = keys
    self.entries = entries
  }

  var allKeys: [Key] {
    return self.keys.compactMap { Key(stringValue: $0) }
  }

  func contains(_ key: Key) -> Bool {
    return self.entries[key.stringValue] != nil
  }

  private func node(for key: Key) throws -> YAMLNode {
    guard let node = self.entries[key.stringValue] else {
      throw DecodingError.keyNotFound(
        key,
        DecodingError.Context(codingPath: self.codingPath,
                              debugDescription: "No value associated with key \(key) (\"\(key.stringValue)\")."))
    }
    return node
  }

  func decodeNil(forKey key: Key) throws -> Bool {
    return self.decoder.isNull(try self.node(for: key))
  }

  func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
    return try self.decoder.unboxBool(try self.node(for: key), at: self.codingPath + [key])
  }

  func decode(_ type: String.Type, forKey key: Key) throws -> String {
    return try self.decoder.unboxString(try self.node(for: key), at: self.codingPath + [key])
  }

  func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
    return try self.decoder.unboxFloat(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
    return try self.decoder.unboxFloat(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
    return try self.decoder.unboxInteger(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
    return try self.decoder.unboxInteger(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
    return try self.decoder.unboxInteger(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
    return try self.decoder.unboxInteger(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
    return try self.decoder.unboxInteger(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
    return try self.decoder.unboxInteger(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
    return try self.decoder.unboxInteger(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
    return try self.decoder.unboxInteger(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
    return try self.decoder.unboxInteger(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
    return try self.decoder.unboxInteger(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
    return try self.decoder.unbox(try self.node(for: key), as: type, at: self.codingPath + [key])
  }

  func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type,
                                             forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
    let decoder = YAMLDecoderImpl(node: try self.node(for: key),
                                  options: self.decoder.options,
                                  codingPath: self.codingPath + [key])
    return try decoder.container(keyedBy: type)
  }

  func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
    let decoder = YAMLDecoderImpl(node: try self.node(for: key),
                                  options: self.decoder.options,
                                  codingPath: self.codingPath + [key])
    return try decoder.unkeyedContainer()
  }

  func superDecoder() throws -> any Decoder {
    return YAMLDecoderImpl(node: self.entries[YAMLCodingKey.super.stringValue] ?? .null,
                           options: self.decoder.options,
                           codingPath: self.codingPath + [YAMLCodingKey.super])
  }

  func superDecoder(forKey key: Key) throws -> any Decoder {
    return YAMLDecoderImpl(node: self.entries[key.stringValue] ?? .null,
                           options: self.decoder.options,
                           codingPath: self.codingPath + [key])
  }
}

// MARK: - Unkeyed container

/// Decodes the elements of a sequence.
struct YAMLUnkeyedDecodingContainer: UnkeyedDecodingContainer {

  let decoder: YAMLDecoderImpl
  let codingPath: [any CodingKey]
  private let elements: [YAMLNode]
  private(set) var currentIndex = 0

  init(decoder: YAMLDecoderImpl, elements: [YAMLNode]) {
    self.decoder = decoder
    self.codingPath = decoder.codingPath
    self.elements = elements
  }

  var count: Int? {
    return self.elements.count
  }

  var isAtEnd: Bool {
    return self.currentIndex >= self.elements.count
  }

  private var currentPath: [any CodingKey] {
    return self.codingPath + [YAMLCodingKey(index: self.currentIndex)]
  }

  private func current(_ type: Any.Type) throws -> YAMLNode {
    guard !self.isAtEnd else {
      throw DecodingError.valueNotFound(
        type,
        DecodingError.Context(codingPath: self.currentPath,
                              debugDescription: "Unkeyed container is at end."))
    }
    return self.elements[self.currentIndex]
  }

  private mutating func next<T>(_ type: T.Type,
                                _ unbox: (YAMLDecoderImpl, YAMLNode, [any CodingKey]) throws -> T) throws -> T {
    let value = try unbox(self.decoder, try self.current(type), self.currentPath)
    self.currentIndex += 1
    return value
  }

  mutating func decodeNil() throws -> Bool {
    if self.decoder.isNull(try self.current(Never.self)) {
      self.currentIndex += 1
      return true
    }
    return false
  }

  mutating func decode(_ type: Bool.Type) throws -> Bool {
    return try self.next(type) { try $0.unboxBool($1, at: $2) }
  }

  mutating func decode(_ type: String.Type) throws -> String {
    return try self.next(type) { try $0.unboxString($1, at: $2) }
  }

  mutating func decode(_ type: Double.Type) throws -> Double {
    return try self.next(type) { try $0.unboxFloat($1, as: type, at: $2) }
  }

  mutating func decode(_ type: Float.Type) throws -> Float {
    return try self.next(type) { try $0.unboxFloat($1, as: type, at: $2) }
  }

  mutating func decode(_ type: Int.Type) throws -> Int {
    return try self.next(type) { try $0.unboxInteger($1, as: type, at: $2) }
  }

  mutating func decode(_ type: Int8.Type) throws -> Int8 {
    return try self.next(type) { try $0.unboxInteger($1, as: type, at: $2) }
  }

  mutating func decode(_ type: Int16.Type) throws -> Int16 {
    return try self.next(type) { try $0.unboxInteger($1, as: type, at: $2) }
  }

  mutating func decode(_ type: Int32.Type) throws -> Int32 {
    return try self.next(type) { try $0.unboxInteger($1, as: type, at: $2) }
  }

  mutating func decode(_ type: Int64.Type) throws -> Int64 {
    return try self.next(type) { try $0.unboxInteger($1, as: type, at: $2) }
  }

  mutating func decode(_ type: UInt.Type) throws -> UInt {
    return try self.next(type) { try $0.unboxInteger($1, as: type, at: $2) }
  }

  mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
    return try self.next(type) { try $0.unboxInteger($1, as: type, at: $2) }
  }

  mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
    return try self.next(type) { try $0.unboxInteger($1, as: type, at: $2) }
  }

  mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
    return try self.next(type) { try $0.unboxInteger($1, as: type, at: $2) }
  }

  mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
    return try self.next(type) { try $0.unboxInteger($1, as: type, at: $2) }
  }

  mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
    return try self.next(type) { try $0.unbox($1, as: type, at: $2) }
  }

  mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type)
      throws -> KeyedDecodingContainer<NestedKey> {
    return try self.next(KeyedDecodingContainer<NestedKey>.self) { decoder, node, path in
      try YAMLDecoderImpl(node: node, options: decoder.options, codingPath: path)
        .container(keyedBy: type)
    }
  }

  mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
    return try self.next((any UnkeyedDecodingContainer).self) { decoder, node, path in
      try YAMLDecoderImpl(node: node, options: decoder.options, codingPath: path)
        .unkeyedContainer()
    }
  }

  mutating func superDecoder() throws -> any Decoder {
    return try self.next((any Decoder).self) { decoder, node, path in
      YAMLDecoderImpl(node: node, options: decoder.options, codingPath: path)
    }
  }
}
