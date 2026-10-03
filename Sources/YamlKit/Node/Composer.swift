//
//  Composer.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// Composes the events of a ``YAMLParser`` into ``YAMLNode`` trees
/// (YAML 1.2.2, section 3.1.2 "Compose").
///
/// The composer
///
/// - resolves the tags of all nodes using a ``YAMLSchema``,
/// - replaces aliases with the nodes they refer to,
/// - validates the uniqueness of mapping keys (section 3.2.1.1), and
/// - optionally expands YAML 1.1 merge keys (`<<`).
///
/// Composition is implemented iteratively, so deeply nested documents do not
/// exhaust the call stack.
struct Composer {

  /// A collection under construction. Frames are classes so that their
  /// collections can be extended in place without copying.
  private final class Frame {
    var sequence: YAMLNode.Sequence?
    var mapping: YAMLNode.Mapping?
    var pendingKey: YAMLNode?
    var keys: Set<YAMLNode> = []
    var size = 1

    init(sequence: YAMLNode.Sequence) {
      self.sequence = sequence
    }

    init(mapping: YAMLNode.Mapping) {
      self.mapping = mapping
    }
  }

  /// The parser providing the events.
  private var parser: YAMLParser

  /// The composition options.
  private let options: YAML.ParseOptions

  /// The anchors defined in the current document with their nodes and sizes.
  private var anchors: [String: (node: YAMLNode, size: Int)] = [:]

  /// The total number of nodes copied by resolving aliases.
  private var aliasExpansion = 0

  /// Has the stream start event been consumed?
  private var started = false

  /// Creates a composer.
  init(parser: YAMLParser, options: YAML.ParseOptions) {
    self.parser = parser
    self.options = options
  }

  /// Returns the next document of the stream, or `nil` at the end of the
  /// stream.
  mutating func nextDocument() throws -> YAMLNode? {
    if !self.started {
      guard let event = try self.parser.next(), case .streamStart = event.kind else {
        throw YAMLError(.composer, "missing stream start")
      }
      self.started = true
    }
    guard let event = try self.parser.next() else {
      return nil
    }
    switch event.kind {
      case .streamEnd:
        return nil
      case .documentStart:
        break
      default:
        throw YAMLError(.composer, "expected document start", at: event.start)
    }
    self.anchors = [:]
    self.aliasExpansion = 0
    let root = try self.composeNode()
    guard let end = try self.parser.next(), case .documentEnd = end.kind else {
      throw YAMLError(.composer, "expected document end")
    }
    return root
  }

  /// Composes all remaining documents of the stream.
  mutating func allDocuments() throws -> [YAMLNode] {
    var documents: [YAMLNode] = []
    while let document = try self.nextDocument() {
      documents.append(document)
    }
    return documents
  }

  /// Composes a complete node from the event stream.
  private mutating func composeNode() throws -> YAMLNode {
    var stack: [Frame] = []
    while let event = try self.parser.next() {
      var node: YAMLNode
      var size = 1
      switch event.kind {
        case .scalar(let value, let style, let tag, let anchor):
          let resolved: YAMLTag
          if let tag, tag != .nonSpecific {
            resolved = tag
          } else if tag == nil && style == .plain {
            resolved = self.options.schema.tag(forPlainScalar: value)
          } else {
            resolved = .str
          }
          node = .scalar(YAMLNode.Scalar(value, tag: resolved, style: style,
                                         anchor: anchor, mark: event.start))
          if let anchor {
            self.anchors[anchor] = (node, 1)
          }
        case .alias(let name):
          guard let (target, targetSize) = self.anchors[name] else {
            throw YAMLError(.composer, "undefined alias '\(name)'", at: event.start)
          }
          self.aliasExpansion += targetSize
          if self.aliasExpansion > self.options.maximumAliasExpansion {
            throw YAMLError(.limitExceeded,
                            "aliases expand to more than \(self.options.maximumAliasExpansion) nodes",
                            at: event.start)
          }
          node = target
          size = targetSize
        case .sequenceStart(let style, let tag, let anchor):
          let resolved = (tag == nil || tag == .nonSpecific) ? YAMLTag.seq : tag!
          stack.append(Frame(sequence: YAMLNode.Sequence([], tag: resolved, style: style,
                                                         anchor: anchor, mark: event.start)))
          continue
        case .mappingStart(let style, let tag, let anchor):
          let resolved = (tag == nil || tag == .nonSpecific) ? YAMLTag.map : tag!
          stack.append(Frame(mapping: YAMLNode.Mapping([], tag: resolved, style: style,
                                                       anchor: anchor, mark: event.start)))
          continue
        case .sequenceEnd:
          guard let frame = stack.popLast(), let sequence = frame.sequence else {
            throw YAMLError(.composer, "unbalanced sequence end", at: event.start)
          }
          node = .sequence(sequence)
          size = frame.size
          if let anchor = sequence.anchor {
            self.anchors[anchor] = (node, size)
          }
        case .mappingEnd:
          guard let frame = stack.popLast(), var mapping = frame.mapping else {
            throw YAMLError(.composer, "unbalanced mapping end", at: event.start)
          }
          frame.mapping = nil
          if self.options.resolvesMergeKeys {
            mapping = try self.merge(mapping)
          }
          node = .mapping(mapping)
          size = frame.size
          if let anchor = mapping.anchor {
            self.anchors[anchor] = (node, size)
          }
        default:
          throw YAMLError(.composer, "unexpected event \(event.kind)", at: event.start)
      }
      // Add the completed node to its parent.
      guard let parent = stack.last else {
        return node
      }
      parent.size += size
      if parent.sequence != nil {
        parent.sequence?.elements.append(node)
      } else if let key = parent.pendingKey {
        parent.mapping?.entries.append(YAMLNode.Mapping.Entry(key: key, value: node))
        parent.pendingKey = nil
      } else {
        if !self.options.allowsDuplicateKeys && !self.isMergeKey(node) {
          guard parent.keys.insert(node).inserted else {
            throw YAMLError(.composer, "duplicate mapping key \(node)", at: node.mark ?? event.start)
          }
        }
        parent.pendingKey = node
      }
    }
    throw YAMLError(.composer, "unexpected end of event stream")
  }

  // MARK: - Merge keys

  /// Is `node` a merge key (`<<`, see https://yaml.org/type/merge.html)?
  private func isMergeKey(_ node: YAMLNode) -> Bool {
    guard self.options.resolvesMergeKeys, let scalar = node.scalar else {
      return false
    }
    return scalar.tag == .merge
      || (scalar.value == "<<" && scalar.tag == .str && scalar.style == .plain)
  }

  /// Expands the merge keys of `mapping`. Keys of the mapping itself take
  /// precedence over merged keys; earlier merged mappings take precedence
  /// over later ones.
  private func merge(_ mapping: YAMLNode.Mapping) throws -> YAMLNode.Mapping {
    guard mapping.entries.contains(where: { self.isMergeKey($0.key) }) else {
      return mapping
    }
    var result = mapping
    result.entries = []
    var present = Set(mapping.entries.lazy.filter { !self.isMergeKey($0.key) }.map(\.key))
    for entry in mapping.entries {
      guard self.isMergeKey(entry.key) else {
        result.entries.append(entry)
        continue
      }
      let sources: [YAMLNode]
      switch entry.value {
        case .mapping:
          sources = [entry.value]
        case .sequence(let sequence):
          sources = sequence.elements
        case .scalar:
          throw YAMLError(.composer, "merge key value must be a mapping or a sequence of mappings",
                          at: entry.value.mark)
      }
      for source in sources {
        guard case .mapping(let merged) = source else {
          throw YAMLError(.composer, "merge key value must be a mapping or a sequence of mappings",
                          at: source.mark)
        }
        for mergedEntry in merged.entries where !present.contains(mergedEntry.key) {
          present.insert(mergedEntry.key)
          result.entries.append(mergedEntry)
        }
      }
    }
    return result
  }
}
