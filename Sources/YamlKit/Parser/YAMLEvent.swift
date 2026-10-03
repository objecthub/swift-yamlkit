//
//  YAMLEvent.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// An event of the YAML serialization tree (YAML 1.2.2, section 3.1.2).
///
/// Events are produced by ``YAMLParser`` and consumed by ``YAMLEmitter``.
/// They form a flat, streaming representation of a YAML stream: documents
/// are bracketed by ``Kind/documentStart(version:tagDirectives:isImplicit:)``
/// and ``Kind/documentEnd(isImplicit:)``, collections by their respective
/// start and end events.
public struct YAMLEvent: Sendable, Hashable, CustomStringConvertible {

  /// The kind of an event together with its payload.
  public enum Kind: Sendable, Hashable {
    /// The start of a stream.
    case streamStart
    /// The end of a stream.
    case streamEnd
    /// The start of a document. `isImplicit` is `false` if the document was
    /// started with an explicit `---` marker.
    case documentStart(version: YAMLVersion?, tagDirectives: [TagDirective], isImplicit: Bool)
    /// The end of a document. `isImplicit` is `false` if the document was
    /// terminated by an explicit `...` marker.
    case documentEnd(isImplicit: Bool)
    /// An alias node referring to a previously anchored node.
    case alias(anchor: String)
    /// A scalar node. `tag` is `nil` if the scalar has no tag property.
    case scalar(value: String, style: ScalarStyle, tag: YAMLTag?, anchor: String?)
    /// The start of a sequence node.
    case sequenceStart(style: CollectionStyle, tag: YAMLTag?, anchor: String?)
    /// The end of a sequence node.
    case sequenceEnd
    /// The start of a mapping node.
    case mappingStart(style: CollectionStyle, tag: YAMLTag?, anchor: String?)
    /// The end of a mapping node.
    case mappingEnd
  }

  /// The kind of the event.
  public var kind: Kind

  /// The source position at which the event starts.
  public var start: Mark

  /// The source position at which the event ends.
  public var end: Mark

  /// Creates a new event.
  public init(_ kind: Kind, start: Mark = .start, end: Mark = .start) {
    self.kind = kind
    self.start = start
    self.end = end
  }

  /// Convenience initializer for scalar events.
  public static func scalar(_ value: String,
                            style: ScalarStyle = .plain,
                            tag: YAMLTag? = nil,
                            anchor: String? = nil) -> YAMLEvent {
    return YAMLEvent(.scalar(value: value, style: style, tag: tag, anchor: anchor))
  }

  public var description: String {
    return "\(self.kind)"
  }
}
