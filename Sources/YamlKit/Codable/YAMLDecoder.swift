//
//  YAMLDecoder.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation

/// An object that decodes instances of a data type from YAML documents.
///
/// `YAMLDecoder` mirrors `JSONDecoder`: create a decoder, optionally
/// configure its strategies, and call `decode(_:from:)`.
///
/// ```swift
/// struct Config: Decodable {
///   var name: String
///   var replicas: Int
///   var labels: [String: String]
/// }
///
/// let yaml = """
///   name: web
///   replicas: 3
///   labels:
///     tier: frontend
///   """
/// let config = try YAMLDecoder().decode(Config.self, from: yaml)
/// ```
///
/// Scalars are interpreted according to the configured ``YAMLSchema``
/// (the core schema by default): `3` is an integer, `true` a boolean, `~` or
/// an empty value is null, and `"3"` (quoted) is a string. Strings can be
/// decoded from any non-null scalar, so `version: 1.10` decodes into a
/// `String` property as `"1.10"`.
///
/// The decoder is thread-safe: its configuration is protected by a lock and
/// it can be shared between tasks.
open class YAMLDecoder: @unchecked Sendable {

  /// The strategy used to decode `Date` values.
  public enum DateDecodingStrategy: Sendable {
    /// Decode YAML timestamps (https://yaml.org/type/timestamp.html), e.g.
    /// `2001-12-14`, `2001-12-14T21:59:43.10Z`, or
    /// `2001-12-14 21:59:43.10 -5`. This is the default strategy.
    case timestamp
    /// Defer to `Date` for decoding.
    case deferredToDate
    /// Decode the date from a number of seconds since January 1, 1970.
    case secondsSince1970
    /// Decode the date from a number of milliseconds since January 1, 1970.
    case millisecondsSince1970
    /// Decode the date from a strict ISO 8601 string.
    case iso8601
    /// Decode the date from a string parsed by the given formatter.
    case formatted(DateFormatter)
    /// Decode the date using a custom function.
    case custom(@Sendable (_ decoder: any Decoder) throws -> Date)
  }

  /// The strategy used to decode `Data` values.
  public enum DataDecodingStrategy: Sendable {
    /// Decode base64-encoded data (as used by the `!!binary` tag). White space
    /// within the encoded text is ignored. This is the default strategy.
    case base64
    /// Defer to `Data` for decoding.
    case deferredToData
    /// Decode the data using a custom function.
    case custom(@Sendable (_ decoder: any Decoder) throws -> Data)
  }

  /// The strategy used to convert mapping keys into coding keys.
  public enum KeyDecodingStrategy: Sendable {
    /// Use the keys as they appear in the document.
    case useDefaultKeys
    /// Convert `snake_case` keys into `camelCase` keys.
    case convertFromSnakeCase
    /// Convert `kebab-case` keys into `camelCase` keys.
    case convertFromKebabCase
    /// Convert keys using a custom function. The function receives the
    /// coding path of the key, including the key itself as the last element.
    case custom(@Sendable (_ codingPath: [any CodingKey]) -> any CodingKey)
  }

  /// The configuration of a decoder.
  struct Options: @unchecked Sendable {
    var dateDecodingStrategy = DateDecodingStrategy.timestamp
    var dataDecodingStrategy = DataDecodingStrategy.base64
    var keyDecodingStrategy = KeyDecodingStrategy.useDefaultKeys
    var parseOptions = YAML.ParseOptions()
    var userInfo: [CodingUserInfoKey: any Sendable] = [:]
  }

  private let lock = NSLock()
  private var options = Options()

  /// The strategy used to decode `Date` values. Defaults to
  /// ``DateDecodingStrategy/timestamp``.
  open var dateDecodingStrategy: DateDecodingStrategy {
    get { self.lock.withLock { self.options.dateDecodingStrategy } }
    set { self.lock.withLock { self.options.dateDecodingStrategy = newValue } }
  }

  /// The strategy used to decode `Data` values. Defaults to
  /// ``DataDecodingStrategy/base64``.
  open var dataDecodingStrategy: DataDecodingStrategy {
    get { self.lock.withLock { self.options.dataDecodingStrategy } }
    set { self.lock.withLock { self.options.dataDecodingStrategy = newValue } }
  }

  /// The strategy used to convert mapping keys. Defaults to
  /// ``KeyDecodingStrategy/useDefaultKeys``.
  open var keyDecodingStrategy: KeyDecodingStrategy {
    get { self.lock.withLock { self.options.keyDecodingStrategy } }
    set { self.lock.withLock { self.options.keyDecodingStrategy = newValue } }
  }

  /// The options used to parse YAML text, including the schema used for
  /// resolving plain scalars, the handling of duplicate and merge keys,
  /// and resource limits.
  open var parseOptions: YAML.ParseOptions {
    get { self.lock.withLock { self.options.parseOptions } }
    set { self.lock.withLock { self.options.parseOptions = newValue } }
  }

  /// Contextual information passed to the types being decoded.
  open var userInfo: [CodingUserInfoKey: any Sendable] {
    get { self.lock.withLock { self.options.userInfo } }
    set { self.lock.withLock { self.options.userInfo = newValue } }
  }

  /// Creates a new decoder.
  public init() {}

  private var currentOptions: Options {
    return self.lock.withLock { self.options }
  }

  // MARK: - Decoding

  /// Decodes a value of the given type from a YAML string consisting of a
  /// single document. An empty stream is decoded as `null`.
  ///
  /// - Throws: `DecodingError.dataCorrupted` if the input is not valid YAML
  ///   or contains more than one document, and any error thrown by the
  ///   value's initializer.
  open func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
    let options = self.currentOptions
    let node = try YAMLDecoder.parse { try YAML.parse(string, options: options.parseOptions) }
    return try self.decode(type, from: node ?? .null, options: options)
  }

  /// Decodes a value of the given type from YAML data consisting of a single
  /// document. The character encoding (UTF-8, UTF-16 or UTF-32) is detected
  /// automatically.
  open func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let options = self.currentOptions
    let node = try YAMLDecoder.parse { try YAML.parse(data, options: options.parseOptions) }
    return try self.decode(type, from: node ?? .null, options: options)
  }

  /// Decodes a value of the given type from a node.
  open func decode<T: Decodable>(_ type: T.Type, from node: YAMLNode) throws -> T {
    return try self.decode(type, from: node, options: self.currentOptions)
  }

  /// Decodes a value of the given type from every document of a YAML stream.
  open func decodeAll<T: Decodable>(_ type: T.Type, from string: String) throws -> [T] {
    let options = self.currentOptions
    let nodes = try YAMLDecoder.parse { try YAML.parseAll(string, options: options.parseOptions) }
    return try nodes.map { try self.decode(type, from: $0, options: options) }
  }

  /// Decodes a value of the given type from every document of a YAML stream.
  open func decodeAll<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
    let options = self.currentOptions
    let nodes = try YAMLDecoder.parse { try YAML.parseAll(data, options: options.parseOptions) }
    return try nodes.map { try self.decode(type, from: $0, options: options) }
  }

  private func decode<T: Decodable>(_ type: T.Type, from node: YAMLNode, options: Options) throws -> T {
    let decoder = YAMLDecoderImpl(node: node, options: options, codingPath: [])
    return try decoder.unbox(node, as: type)
  }

  /// Wraps parsing errors into `DecodingError.dataCorrupted`.
  private static func parse<R>(_ body: () throws -> R) throws -> R {
    do {
      return try body()
    } catch let error as YAMLError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: [],
                              debugDescription: "The given data was not valid YAML.",
                              underlyingError: error))
    }
  }
}

#if canImport(Combine)
import Combine

extension YAMLDecoder: TopLevelDecoder {
  public typealias Input = Data
}
#endif
