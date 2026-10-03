//
//  YAMLEncoder.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation

/// An object that encodes instances of a data type as YAML documents.
///
/// `YAMLEncoder` mirrors `JSONEncoder`:
///
/// ```swift
/// struct Config: Encodable {
///   var name: String
///   var replicas: Int
///   var labels: [String: String]
/// }
///
/// let encoder = YAMLEncoder()
/// encoder.outputFormatting = .sortedKeys
/// let yaml = try encoder.encodeToString(Config(name: "web", replicas: 3,
///                                              labels: ["tier": "frontend"]))
/// // labels:
/// //   tier: frontend
/// // name: web
/// // replicas: 3
/// ```
///
/// Keyed containers are encoded as block mappings preserving the order in
/// which the keys were encoded (unless ``OutputFormatting/sortedKeys`` is
/// set), unkeyed containers as block sequences, and empty collections as
/// `[]` and `{}`. Strings are quoted only where necessary, i.e. if they
/// would otherwise be read back as a different type (such as `"true"` or
/// `"1.0"`) or contain characters that cannot be written in plain style.
/// Multi-line strings are written as literal block scalars.
///
/// The encoder is thread-safe: its configuration is protected by a lock and
/// it can be shared between tasks.
open class YAMLEncoder: @unchecked Sendable {

  /// Options determining the formatting of the encoded YAML.
  public struct OutputFormatting: OptionSet, Sendable {

    public let rawValue: UInt

    public init(rawValue: UInt) {
      self.rawValue = rawValue
    }

    /// Sort mapping keys lexicographically instead of preserving the order
    /// in which they were encoded.
    public static let sortedKeys = OutputFormatting(rawValue: 1 << 0)

    /// Start every document with an explicit `---` marker.
    public static let explicitDocumentStart = OutputFormatting(rawValue: 1 << 1)

    /// Do not indent block sequences nested in block mappings.
    public static let indentlessSequences = OutputFormatting(rawValue: 1 << 2)

    /// Escape all non-ASCII characters in double-quoted scalars.
    public static let escapeNonASCII = OutputFormatting(rawValue: 1 << 3)

    /// Use flow style (`[...]` and `{...}`) for all collections.
    public static let flowStyle = OutputFormatting(rawValue: 1 << 4)
  }

  /// The strategy used to encode `Date` values.
  public enum DateEncodingStrategy: Sendable {
    /// Encode the date as an ISO 8601 timestamp in UTC with fractional
    /// seconds if necessary, e.g. `2001-12-14T21:59:43.1Z`. This is the
    /// default strategy.
    case timestamp
    /// Defer to `Date` for encoding.
    case deferredToDate
    /// Encode the date as the number of seconds since January 1, 1970.
    case secondsSince1970
    /// Encode the date as the number of milliseconds since January 1, 1970.
    case millisecondsSince1970
    /// Encode the date as an ISO 8601 string without fractional seconds.
    case iso8601
    /// Encode the date as a string formatted by the given formatter.
    case formatted(DateFormatter)
    /// Encode the date using a custom function.
    case custom(@Sendable (_ date: Date, _ encoder: any Encoder) throws -> Void)
  }

  /// The strategy used to encode `Data` values.
  public enum DataEncodingStrategy: Sendable {
    /// Encode the data as base64 text tagged `!!binary`. This is the default
    /// strategy.
    case base64
    /// Defer to `Data` for encoding.
    case deferredToData
    /// Encode the data using a custom function.
    case custom(@Sendable (_ data: Data, _ encoder: any Encoder) throws -> Void)
  }

  /// The strategy used to convert coding keys into mapping keys.
  public enum KeyEncodingStrategy: Sendable {
    /// Use the coding keys unchanged.
    case useDefaultKeys
    /// Convert `camelCase` keys into `snake_case` keys.
    case convertToSnakeCase
    /// Convert `camelCase` keys into `kebab-case` keys.
    case convertToKebabCase
    /// Convert keys using a custom function. The function receives the
    /// coding path of the key, including the key itself as the last element.
    case custom(@Sendable (_ codingPath: [any CodingKey]) -> any CodingKey)
  }

  /// The configuration of an encoder.
  struct Options: @unchecked Sendable {
    var outputFormatting: OutputFormatting = []
    var indentation = 2
    var lineWidth = 80
    var dateEncodingStrategy = DateEncodingStrategy.timestamp
    var dataEncodingStrategy = DataEncodingStrategy.base64
    var keyEncodingStrategy = KeyEncodingStrategy.useDefaultKeys
    var userInfo: [CodingUserInfoKey: any Sendable] = [:]

    var serializeOptions: YAML.SerializeOptions {
      return YAML.SerializeOptions(formatting: YAMLEmitter.Options(
        indentation: self.indentation,
        lineWidth: self.lineWidth,
        allowsUnicode: !self.outputFormatting.contains(.escapeNonASCII),
        indentsSequencesInMappings: !self.outputFormatting.contains(.indentlessSequences),
        explicitDocumentStart: self.outputFormatting.contains(.explicitDocumentStart)))
    }
  }

  private let lock = NSLock()
  private var options = Options()

  /// The output format of the encoded YAML. Defaults to `[]`.
  open var outputFormatting: OutputFormatting {
    get { self.lock.withLock { self.options.outputFormatting } }
    set { self.lock.withLock { self.options.outputFormatting = newValue } }
  }

  /// The number of spaces used per indentation level (2 to 9). Defaults to 2.
  open var indentation: Int {
    get { self.lock.withLock { self.options.indentation } }
    set { self.lock.withLock { self.options.indentation = newValue } }
  }

  /// The preferred maximum line width; longer scalars are folded where
  /// possible. Defaults to 80.
  open var lineWidth: Int {
    get { self.lock.withLock { self.options.lineWidth } }
    set { self.lock.withLock { self.options.lineWidth = newValue } }
  }

  /// The strategy used to encode `Date` values. Defaults to
  /// ``DateEncodingStrategy/timestamp``.
  open var dateEncodingStrategy: DateEncodingStrategy {
    get { self.lock.withLock { self.options.dateEncodingStrategy } }
    set { self.lock.withLock { self.options.dateEncodingStrategy = newValue } }
  }

  /// The strategy used to encode `Data` values. Defaults to
  /// ``DataEncodingStrategy/base64``.
  open var dataEncodingStrategy: DataEncodingStrategy {
    get { self.lock.withLock { self.options.dataEncodingStrategy } }
    set { self.lock.withLock { self.options.dataEncodingStrategy = newValue } }
  }

  /// The strategy used to convert coding keys. Defaults to
  /// ``KeyEncodingStrategy/useDefaultKeys``.
  open var keyEncodingStrategy: KeyEncodingStrategy {
    get { self.lock.withLock { self.options.keyEncodingStrategy } }
    set { self.lock.withLock { self.options.keyEncodingStrategy = newValue } }
  }

  /// Contextual information passed to the types being encoded.
  open var userInfo: [CodingUserInfoKey: any Sendable] {
    get { self.lock.withLock { self.options.userInfo } }
    set { self.lock.withLock { self.options.userInfo = newValue } }
  }

  /// Creates a new encoder.
  public init() {}

  private var currentOptions: Options {
    return self.lock.withLock { self.options }
  }

  // MARK: - Encoding

  /// Encodes `value` as a YAML document and returns its UTF-8 representation.
  open func encode<T: Encodable>(_ value: T) throws -> Data {
    return Data(try self.encodeToString(value).utf8)
  }

  /// Encodes `value` as a YAML document.
  open func encodeToString<T: Encodable>(_ value: T) throws -> String {
    return try self.encodeAllToString([value])
  }

  /// Encodes each element of `values` as a separate document of a YAML
  /// stream and returns its UTF-8 representation.
  open func encodeAll<S: Swift.Sequence>(_ values: S) throws -> Data where S.Element: Encodable {
    return Data(try self.encodeAllToString(values).utf8)
  }

  /// Encodes each element of `values` as a separate document of a YAML
  /// stream.
  open func encodeAllToString<S: Swift.Sequence>(_ values: S) throws -> String where S.Element: Encodable {
    let options = self.currentOptions
    let nodes = try values.map { try self.encodeToNode($0, options: options) }
    do {
      return try YAML.serialize(documents: nodes, options: options.serializeOptions)
    } catch {
      throw EncodingError.invalidValue(
        values,
        EncodingError.Context(codingPath: [],
                              debugDescription: "Unable to serialize the encoded value.",
                              underlyingError: error))
    }
  }

  /// Encodes `value` into a node.
  open func encodeToNode<T: Encodable>(_ value: T) throws -> YAMLNode {
    return try self.encodeToNode(value, options: self.currentOptions)
  }

  private func encodeToNode<T: Encodable>(_ value: T, options: Options) throws -> YAMLNode {
    let encoder = YAMLEncoderImpl(options: options, codingPath: [])
    let reference = try encoder.box(value) ?? .mapping()
    return reference.node(sortedKeys: options.outputFormatting.contains(.sortedKeys),
                          flowStyle: options.outputFormatting.contains(.flowStyle))
  }
}

#if canImport(Combine)
import Combine

extension YAMLEncoder: TopLevelEncoder {
  public typealias Output = Data
}
#endif
