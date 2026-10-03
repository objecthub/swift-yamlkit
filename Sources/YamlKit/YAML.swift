//
//  YAML.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation

/// Entry points for working with YAML at the level of events and nodes.
///
/// YamlKit processes YAML in the stages described in chapter 3 of the
/// YAML 1.2.2 specification:
///
/// ```
///             parse           compose            decode
/// YAML text ───────▶ events ─────────▶ nodes ─────────▶ Swift values
///           ◀─────── events ◀───────── nodes ◀───────── Swift values
///             emit          serialize          encode
/// ```
///
/// ``YAMLDecoder`` and ``YAMLEncoder`` cover the full pipeline. The functions
/// of this namespace give access to the intermediate representations:
///
/// ```swift
/// let node = try YAML.parse("""
///   name: YamlKit
///   tags: [swift, yaml]
///   """)
/// print(node?["tags"]?[0]?.string) // Optional("swift")
/// print(try YAML.serialize(node!))
/// ```
public enum YAML {

  /// Options controlling how YAML text is parsed into nodes.
  public struct ParseOptions: Sendable {

    /// The schema used to resolve the tags of untagged plain scalars.
    public var schema: any YAMLSchema

    /// Are duplicate keys in mappings permitted? The specification requires
    /// keys to be unique; if duplicates are allowed, all entries are kept.
    public var allowsDuplicateKeys: Bool

    /// Should YAML 1.1 merge keys (`<<`) be expanded?
    public var resolvesMergeKeys: Bool

    /// The maximum number of nodes that may be copied by resolving aliases
    /// in a single document. This protects against "billion laughs" attacks.
    public var maximumAliasExpansion: Int

    /// The maximum nesting depth of collections. Decoding values with
    /// `Codable` is recursive; very deeply nested documents may require a
    /// thread with a larger stack than the default 512 KiB of secondary
    /// threads.
    public var maximumDepth: Int

    /// Creates parse options.
    public init(schema: any YAMLSchema = CoreSchema(),
                allowsDuplicateKeys: Bool = false,
                resolvesMergeKeys: Bool = false,
                maximumAliasExpansion: Int = 1_000_000,
                maximumDepth: Int = 512) {
      self.schema = schema
      self.allowsDuplicateKeys = allowsDuplicateKeys
      self.resolvesMergeKeys = resolvesMergeKeys
      self.maximumAliasExpansion = maximumAliasExpansion
      self.maximumDepth = maximumDepth
    }
  }

  /// Options controlling how nodes are serialized into YAML text.
  public struct SerializeOptions: Sendable {

    /// The formatting options of the emitter.
    public var formatting: YAMLEmitter.Options

    /// The schema used to decide which tags can be omitted.
    public var schema: any YAMLSchema

    /// Creates serialization options.
    public init(formatting: YAMLEmitter.Options = YAMLEmitter.Options(),
                schema: any YAMLSchema = CoreSchema()) {
      self.formatting = formatting
      self.schema = schema
    }
  }

  // MARK: - Events

  /// Parses `yaml` into a list of events.
  public static func parseEvents(_ yaml: String) throws -> [YAMLEvent] {
    var parser = try YAMLParser(string: yaml)
    return try parser.parseAll()
  }

  /// Parses `data` into a list of events. The character encoding is
  /// detected automatically.
  public static func parseEvents(_ data: Data) throws -> [YAMLEvent] {
    var parser = try YAMLParser(data: data)
    return try parser.parseAll()
  }

  /// Emits a list of events as YAML text.
  public static func emit<S: Swift.Sequence>(_ events: S,
                                             options: YAMLEmitter.Options = YAMLEmitter.Options()) throws -> String
      where S.Element == YAMLEvent {
    var emitter = YAMLEmitter(options: options)
    try emitter.emit(contentsOf: events)
    return emitter.output
  }

  // MARK: - Nodes

  /// Parses a stream consisting of at most one document and returns its
  /// root node, or `nil` if the stream contains no document.
  public static func parse(_ yaml: String, options: ParseOptions = ParseOptions()) throws -> YAMLNode? {
    let parser = try YAMLParser(string: yaml, maximumDepth: options.maximumDepth)
    return try YAML.single(parser, options: options)
  }

  /// Parses a stream consisting of at most one document and returns its
  /// root node, or `nil` if the stream contains no document. The character
  /// encoding is detected automatically.
  public static func parse(_ data: Data, options: ParseOptions = ParseOptions()) throws -> YAMLNode? {
    let parser = try YAMLParser(data: data, maximumDepth: options.maximumDepth)
    return try YAML.single(parser, options: options)
  }

  /// Parses all documents of a stream.
  public static func parseAll(_ yaml: String, options: ParseOptions = ParseOptions()) throws -> [YAMLNode] {
    let parser = try YAMLParser(string: yaml, maximumDepth: options.maximumDepth)
    var composer = Composer(parser: parser, options: options)
    return try composer.allDocuments()
  }

  /// Parses all documents of a stream. The character encoding is detected
  /// automatically.
  public static func parseAll(_ data: Data, options: ParseOptions = ParseOptions()) throws -> [YAMLNode] {
    let parser = try YAMLParser(data: data, maximumDepth: options.maximumDepth)
    var composer = Composer(parser: parser, options: options)
    return try composer.allDocuments()
  }

  private static func single(_ parser: YAMLParser, options: ParseOptions) throws -> YAMLNode? {
    var composer = Composer(parser: parser, options: options)
    guard let document = try composer.nextDocument() else {
      return nil
    }
    if try composer.nextDocument() != nil {
      throw YAMLError(.composer, "expected a single document, but found more than one")
    }
    return document
  }

  /// Serializes a node as a YAML document.
  public static func serialize(_ node: YAMLNode, options: SerializeOptions = SerializeOptions()) throws -> String {
    return try YAML.serialize(documents: [node], options: options)
  }

  /// Serializes a list of nodes as a stream of YAML documents.
  public static func serialize<S: Swift.Sequence>(documents: S,
                                                  options: SerializeOptions = SerializeOptions()) throws -> String
      where S.Element == YAMLNode {
    var emitter = YAMLEmitter(options: options.formatting)
    var serializer = Serializer(schema: options.schema)
    try emitter.emit(YAMLEvent(.streamStart))
    for document in documents {
      try emitter.emit(contentsOf: serializer.events(forDocument: document, isImplicit: true))
    }
    try emitter.emit(YAMLEvent(.streamEnd))
    return emitter.output
  }
}
