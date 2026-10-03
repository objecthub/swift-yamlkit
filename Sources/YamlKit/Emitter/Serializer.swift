//
//  Serializer.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// Converts ``YAMLNode`` trees into events (YAML 1.2.2, section 3.1.1
/// "Serialize").
///
/// The serializer decides which tags must be written explicitly and which
/// can be left implicit because the schema resolves them correctly. Strings
/// that would otherwise be resolved to a different type (e.g. `"true"` or
/// `"1.0"`) are quoted. Multi-line strings are emitted as literal block
/// scalars unless a different style was requested.
///
/// Nodes with an anchor that occur repeatedly are emitted once and referenced
/// via aliases afterwards.
struct Serializer {

  /// The schema used to determine whether tags can be omitted.
  let schema: any YAMLSchema

  /// The anchored nodes emitted so far in the current document.
  private var anchors: [String: YAMLNode] = [:]

  /// Creates a serializer.
  init(schema: any YAMLSchema) {
    self.schema = schema
  }

  /// Returns the events for a document with root node `node`.
  mutating func events(forDocument node: YAMLNode, isImplicit: Bool) -> [YAMLEvent] {
    self.anchors = [:]
    var events = [YAMLEvent(.documentStart(version: nil, tagDirectives: [], isImplicit: isImplicit))]
    self.serialize(node, into: &events)
    events.append(YAMLEvent(.documentEnd(isImplicit: true)))
    return events
  }

  /// Appends the events of `node` to `events`.
  private mutating func serialize(_ node: YAMLNode, into events: inout [YAMLEvent]) {
    if let anchor = node.anchor {
      if let previous = self.anchors[anchor], previous == node {
        events.append(YAMLEvent(.alias(anchor: anchor)))
        return
      }
      self.anchors[anchor] = node
    }
    switch node {
      case .scalar(let scalar):
        let (style, tag) = self.presentation(of: scalar)
        events.append(YAMLEvent(.scalar(value: scalar.value, style: style, tag: tag, anchor: scalar.anchor)))
      case .sequence(let sequence):
        events.append(YAMLEvent(.sequenceStart(style: sequence.style ?? .block,
                                               tag: sequence.tag == .seq ? nil : sequence.tag,
                                               anchor: sequence.anchor)))
        for element in sequence.elements {
          self.serialize(element, into: &events)
        }
        events.append(YAMLEvent(.sequenceEnd))
      case .mapping(let mapping):
        events.append(YAMLEvent(.mappingStart(style: mapping.style ?? .block,
                                              tag: mapping.tag == .map ? nil : mapping.tag,
                                              anchor: mapping.anchor)))
        for entry in mapping.entries {
          self.serialize(entry.key, into: &events)
          self.serialize(entry.value, into: &events)
        }
        events.append(YAMLEvent(.mappingEnd))
    }
  }

  /// Determines the style of a scalar and whether its tag must be written.
  private func presentation(of scalar: YAMLNode.Scalar) -> (ScalarStyle, YAMLTag?) {
    let isMultiline = scalar.value.contains("\n")
    let plainTag = self.schema.tag(forPlainScalar: scalar.value)
    if scalar.tag == .str {
      var style = scalar.style ?? (isMultiline ? .literal : .plain)
      if style == .plain && plainTag != .str {
        style = .doubleQuoted
      }
      return (style, nil)
    }
    let style = scalar.style ?? .plain
    if style == .plain && plainTag == scalar.tag {
      return (.plain, nil)
    }
    return (scalar.style ?? (isMultiline ? .literal : .plain), scalar.tag)
  }
}
