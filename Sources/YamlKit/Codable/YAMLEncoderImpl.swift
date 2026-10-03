//
//  YAMLEncoderImpl.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation

/// A mutable reference to a node under construction. Containers write into
/// references so that nested containers can be filled after they have been
/// inserted into their parent.
final class NodeReference {

  private enum Backing {
    case node(YAMLNode)
    case sequence([NodeReference])
    case mapping(keys: [YAMLNode], values: [String: NodeReference], order: [String])
  }

  private var backing: Backing

  private init(_ backing: Backing) {
    self.backing = backing
  }

  /// Creates a reference to a complete node.
  convenience init(_ node: YAMLNode) {
    self.init(.node(node))
  }

  /// Creates a reference to an empty sequence.
  static func sequence() -> NodeReference {
    return NodeReference(.sequence([]))
  }

  /// Creates a reference to an empty mapping.
  static func mapping() -> NodeReference {
    return NodeReference(.mapping(keys: [], values: [:], order: []))
  }

  var isSequence: Bool {
    if case .sequence = self.backing {
      return true
    }
    return false
  }

  var isMapping: Bool {
    if case .mapping = self.backing {
      return true
    }
    return false
  }

  /// The number of elements of a sequence.
  var count: Int {
    if case .sequence(let elements) = self.backing {
      return elements.count
    }
    return 0
  }

  /// Appends an element to a sequence.
  func append(_ reference: NodeReference) {
    guard case .sequence(var elements) = self.backing else {
      preconditionFailure("not a sequence")
    }
    self.backing = .node(.null)
    elements.append(reference)
    self.backing = .sequence(elements)
  }

  /// Inserts an element into a sequence.
  func insert(_ reference: NodeReference, at index: Int) {
    guard case .sequence(var elements) = self.backing else {
      preconditionFailure("not a sequence")
    }
    self.backing = .node(.null)
    elements.insert(reference, at: min(index, elements.count))
    self.backing = .sequence(elements)
  }

  /// Returns the value for `key` of a mapping.
  subscript(key: String) -> NodeReference? {
    guard case .mapping(_, let values, _) = self.backing else {
      return nil
    }
    return values[key]
  }

  /// Sets the value for `key` of a mapping. Keys with an integer value whose
  /// string representation matches are encoded as integer scalars.
  func set(_ reference: NodeReference, for key: String, intValue: Int? = nil) {
    guard case .mapping(var keys, var values, var order) = self.backing else {
      preconditionFailure("not a mapping")
    }
    self.backing = .node(.null)
    if values.updateValue(reference, forKey: key) == nil {
      order.append(key)
      if let intValue, String(intValue) == key {
        keys.append(YAMLNode(intValue))
      } else {
        keys.append(YAMLNode(key))
      }
    }
    self.backing = .mapping(keys: keys, values: values, order: order)
  }

  /// Converts the reference into a node.
  func node(sortedKeys: Bool, flowStyle: Bool) -> YAMLNode {
    let style: CollectionStyle? = flowStyle ? .flow : nil
    switch self.backing {
      case .node(let node):
        return node
      case .sequence(let elements):
        return .sequence(YAMLNode.Sequence(
          elements.map { $0.node(sortedKeys: sortedKeys, flowStyle: flowStyle) },
          style: style))
      case .mapping(let keys, let values, let order):
        var indices = Array(order.indices)
        if sortedKeys {
          indices.sort { order[$0] < order[$1] }
        }
        let entries = indices.map { i in
          YAMLNode.Mapping.Entry(
            key: keys[i],
            value: values[order[i]]?.node(sortedKeys: sortedKeys, flowStyle: flowStyle) ?? .null)
        }
        return .mapping(YAMLNode.Mapping(entries, style: style))
    }
  }
}

/// The `Encoder` implementation used by ``YAMLEncoder``.
class YAMLEncoderImpl: Encoder {

  /// The encoder configuration.
  let options: YAMLEncoder.Options

  let codingPath: [any CodingKey]

  /// The value encoded by this encoder.
  var reference: NodeReference?

  var userInfo: [CodingUserInfoKey: Any] {
    return self.options.userInfo
  }

  init(options: YAMLEncoder.Options, codingPath: [any CodingKey]) {
    self.options = options
    self.codingPath = codingPath
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    let reference: NodeReference
    if let existing = self.reference {
      precondition(existing.isMapping,
                   "Attempt to push new keyed encoding container when already previously encoded at this path.")
      reference = existing
    } else {
      reference = .mapping()
      self.reference = reference
    }
    return KeyedEncodingContainer(YAMLKeyedEncodingContainer<Key>(encoder: self,
                                                                  reference: reference,
                                                                  codingPath: self.codingPath))
  }

  func unkeyedContainer() -> any UnkeyedEncodingContainer {
    let reference: NodeReference
    if let existing = self.reference {
      precondition(existing.isSequence,
                   "Attempt to push new unkeyed encoding container when already previously encoded at this path.")
      reference = existing
    } else {
      reference = .sequence()
      self.reference = reference
    }
    return YAMLUnkeyedEncodingContainer(encoder: self, reference: reference, codingPath: self.codingPath)
  }

  func singleValueContainer() -> any SingleValueEncodingContainer {
    return self
  }

  // MARK: - Boxing values

  /// Encodes `value`, special-casing the Foundation types that have a
  /// natural YAML representation. If `codingPath` is `nil`, the value is
  /// encoded by this encoder.
  func box<T: Encodable>(_ value: T, at codingPath: [any CodingKey]? = nil) throws -> NodeReference? {
    let path = codingPath ?? self.codingPath
    switch value {
      case let date as Date:
        return try self.boxDate(date, at: path)
      case let data as Data:
        return try self.boxData(data, at: path)
      case let url as URL:
        return NodeReference(YAMLNode(url.absoluteString))
      case let decimal as Decimal:
        let text = decimal.description
        let tag = CoreSchema().tag(forPlainScalar: text)
        return NodeReference(.scalar(YAMLNode.Scalar(text, tag: tag == .int ? .int : .float)))
      default:
        let encoder = codingPath == nil ? self : YAMLEncoderImpl(options: self.options, codingPath: path)
        try value.encode(to: encoder)
        return encoder.reference
    }
  }

  /// Encodes `value` and returns a reference, using an empty mapping if
  /// the value did not encode anything.
  func boxed<T: Encodable>(_ value: T, at codingPath: [any CodingKey]) throws -> NodeReference {
    return try self.box(value, at: codingPath) ?? .mapping()
  }

  private func boxDate(_ date: Date, at path: [any CodingKey]) throws -> NodeReference? {
    switch self.options.dateEncodingStrategy {
      case .timestamp:
        return NodeReference(YAMLNode(Timestamp.format(date)))
      case .deferredToDate:
        let encoder = YAMLEncoderImpl(options: self.options, codingPath: path)
        try date.encode(to: encoder)
        return encoder.reference
      case .secondsSince1970:
        return NodeReference(YAMLNode(date.timeIntervalSince1970))
      case .millisecondsSince1970:
        return NodeReference(YAMLNode(date.timeIntervalSince1970 * 1000))
      case .iso8601:
        return NodeReference(YAMLNode(date.formatted(Date.ISO8601FormatStyle())))
      case .formatted(let formatter):
        return NodeReference(YAMLNode(formatter.string(from: date)))
      case .custom(let closure):
        let encoder = YAMLEncoderImpl(options: self.options, codingPath: path)
        try closure(date, encoder)
        return encoder.reference ?? .mapping()
    }
  }

  private func boxData(_ data: Data, at path: [any CodingKey]) throws -> NodeReference? {
    switch self.options.dataEncodingStrategy {
      case .base64:
        return NodeReference(.scalar(YAMLNode.Scalar(data.base64EncodedString(), tag: .binary)))
      case .deferredToData:
        let encoder = YAMLEncoderImpl(options: self.options, codingPath: path)
        try data.encode(to: encoder)
        return encoder.reference
      case .custom(let closure):
        let encoder = YAMLEncoderImpl(options: self.options, codingPath: path)
        try closure(data, encoder)
        return encoder.reference ?? .mapping()
    }
  }

  /// Converts a coding key into a mapping key using the key encoding
  /// strategy.
  func convert(_ key: any CodingKey, at codingPath: [any CodingKey]) -> String {
    switch self.options.keyEncodingStrategy {
      case .useDefaultKeys:
        return key.stringValue
      case .convertToSnakeCase:
        return KeyConversion.convertFromCamelCase(key.stringValue, separator: "_")
      case .convertToKebabCase:
        return KeyConversion.convertFromCamelCase(key.stringValue, separator: "-")
      case .custom(let convert):
        return convert(codingPath + [key]).stringValue
    }
  }
}

// MARK: - Single value container

extension YAMLEncoderImpl: SingleValueEncodingContainer {

  private func assertCanEncodeNewValue() {
    precondition(self.reference == nil,
                 "Attempt to encode value through single value container when previously value already encoded.")
  }

  func encodeNil() throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(.null)
  }

  func encode(_ value: Bool) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: String) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: Double) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: Float) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: Int) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: Int8) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: Int16) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: Int32) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: Int64) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: UInt) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: UInt8) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: UInt16) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: UInt32) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode(_ value: UInt64) throws {
    self.assertCanEncodeNewValue()
    self.reference = NodeReference(YAMLNode(value))
  }

  func encode<T: Encodable>(_ value: T) throws {
    self.assertCanEncodeNewValue()
    self.reference = try self.box(value, at: self.codingPath) ?? .mapping()
  }
}

// MARK: - Keyed container

/// Encodes values into a mapping.
struct YAMLKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {

  let encoder: YAMLEncoderImpl
  let reference: NodeReference
  let codingPath: [any CodingKey]

  private func set(_ node: YAMLNode, for key: Key) {
    self.set(NodeReference(node), for: key)
  }

  private func set(_ reference: NodeReference, for key: Key) {
    self.reference.set(reference,
                       for: self.encoder.convert(key, at: self.codingPath),
                       intValue: key.intValue)
  }

  mutating func encodeNil(forKey key: Key) throws {
    self.set(.null, for: key)
  }

  mutating func encode(_ value: Bool, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: String, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: Double, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: Float, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: Int, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: Int8, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: Int16, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: Int32, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: Int64, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: UInt, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: UInt8, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: UInt16, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: UInt32, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode(_ value: UInt64, forKey key: Key) throws {
    self.set(YAMLNode(value), for: key)
  }

  mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
    self.set(try self.encoder.boxed(value, at: self.codingPath + [key]), for: key)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type,
                                                      forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
    let name = self.encoder.convert(key, at: self.codingPath)
    let nested: NodeReference
    if let existing = self.reference[name], existing.isMapping {
      nested = existing
    } else {
      nested = .mapping()
      self.set(nested, for: key)
    }
    return KeyedEncodingContainer(YAMLKeyedEncodingContainer<NestedKey>(encoder: self.encoder,
                                                                        reference: nested,
                                                                        codingPath: self.codingPath + [key]))
  }

  mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
    let name = self.encoder.convert(key, at: self.codingPath)
    let nested: NodeReference
    if let existing = self.reference[name], existing.isSequence {
      nested = existing
    } else {
      nested = .sequence()
      self.set(nested, for: key)
    }
    return YAMLUnkeyedEncodingContainer(encoder: self.encoder,
                                        reference: nested,
                                        codingPath: self.codingPath + [key])
  }

  mutating func superEncoder() -> any Encoder {
    return YAMLReferencingEncoder(encoder: self.encoder,
                                  parent: self.reference,
                                  location: .key(YAMLCodingKey.super.stringValue),
                                  codingPath: self.codingPath + [YAMLCodingKey.super])
  }

  mutating func superEncoder(forKey key: Key) -> any Encoder {
    return YAMLReferencingEncoder(encoder: self.encoder,
                                  parent: self.reference,
                                  location: .key(self.encoder.convert(key, at: self.codingPath)),
                                  codingPath: self.codingPath + [key])
  }
}

// MARK: - Unkeyed container

/// Encodes values into a sequence.
struct YAMLUnkeyedEncodingContainer: UnkeyedEncodingContainer {

  let encoder: YAMLEncoderImpl
  let reference: NodeReference
  let codingPath: [any CodingKey]

  var count: Int {
    return self.reference.count
  }

  private var nextPath: [any CodingKey] {
    return self.codingPath + [YAMLCodingKey(index: self.count)]
  }

  private func append(_ node: YAMLNode) {
    self.reference.append(NodeReference(node))
  }

  mutating func encodeNil() throws {
    self.append(.null)
  }

  mutating func encode(_ value: Bool) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: String) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: Double) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: Float) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: Int) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: Int8) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: Int16) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: Int32) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: Int64) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: UInt) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: UInt8) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: UInt16) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: UInt32) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode(_ value: UInt64) throws {
    self.append(YAMLNode(value))
  }

  mutating func encode<T: Encodable>(_ value: T) throws {
    self.reference.append(try self.encoder.boxed(value, at: self.nextPath))
  }

  mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type)
      -> KeyedEncodingContainer<NestedKey> {
    let path = self.nextPath
    let nested = NodeReference.mapping()
    self.reference.append(nested)
    return KeyedEncodingContainer(YAMLKeyedEncodingContainer<NestedKey>(encoder: self.encoder,
                                                                        reference: nested,
                                                                        codingPath: path))
  }

  mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
    let path = self.nextPath
    let nested = NodeReference.sequence()
    self.reference.append(nested)
    return YAMLUnkeyedEncodingContainer(encoder: self.encoder, reference: nested, codingPath: path)
  }

  mutating func superEncoder() -> any Encoder {
    return YAMLReferencingEncoder(encoder: self.encoder,
                                  parent: self.reference,
                                  location: .index(self.count),
                                  codingPath: self.nextPath)
  }
}

// MARK: - Referencing encoder

/// An encoder returned by `superEncoder()`, which writes its value into the
/// parent container when it is deallocated.
final class YAMLReferencingEncoder: YAMLEncoderImpl {

  /// The position of the encoded value in the parent container.
  enum Location {
    case key(String)
    case index(Int)
  }

  private let parent: NodeReference
  private let location: Location

  init(encoder: YAMLEncoderImpl, parent: NodeReference, location: Location, codingPath: [any CodingKey]) {
    self.parent = parent
    self.location = location
    super.init(options: encoder.options, codingPath: codingPath)
  }

  deinit {
    let value = self.reference ?? .mapping()
    switch self.location {
      case .key(let key):
        self.parent.set(value, for: key)
      case .index(let index):
        self.parent.insert(value, at: index)
    }
  }
}
