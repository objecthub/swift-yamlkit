//
//  YAMLParser.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation

/// A pull parser turning YAML text into a stream of ``YAMLEvent`` values.
///
/// The parser implements the structural productions of YAML 1.2.2,
/// chapters 6 to 9, as an LL(1) state machine over the tokens produced by
/// the scanner:
///
/// ```
/// stream            ::= STREAM-START implicit_document? explicit_document* STREAM-END
/// implicit_document ::= block_node DOCUMENT-END*
/// explicit_document ::= DIRECTIVE* DOCUMENT-START block_node? DOCUMENT-END*
/// block_node        ::= ALIAS | properties? (block_content | indentless_sequence)?
/// block_content     ::= block_collection | flow_collection | SCALAR
/// flow_node         ::= ALIAS | properties? (flow_collection | SCALAR)?
/// block_sequence    ::= BLOCK-SEQUENCE-START (BLOCK-ENTRY block_node?)* BLOCK-END
/// block_mapping     ::= BLOCK-MAPPING-START
///                         ((KEY block_node_or_indentless_sequence?)?
///                          (VALUE block_node_or_indentless_sequence?)?)* BLOCK-END
/// flow_sequence     ::= FLOW-SEQUENCE-START
///                         (flow_sequence_entry FLOW-ENTRY)* flow_sequence_entry? FLOW-SEQUENCE-END
/// flow_mapping      ::= FLOW-MAPPING-START
///                         (flow_mapping_entry FLOW-ENTRY)* flow_mapping_entry? FLOW-MAPPING-END
/// ```
///
/// Use ``next()`` to pull events one at a time, or ``YAML/parseEvents(_:)-(String)``
/// to obtain all events of a stream at once.
public struct YAMLParser {

  /// The states of the parser state machine.
  enum State {
    case streamStart
    case documentStart(isImplicitAllowed: Bool)
    case documentContent
    case documentEnd
    case blockNode
    case blockSequenceEntry(isFirst: Bool)
    case indentlessSequenceEntry
    case blockMappingKey(isFirst: Bool)
    case blockMappingValue
    case flowSequenceEntry(isFirst: Bool)
    case flowSequenceEntryMappingKey
    case flowSequenceEntryMappingValue
    case flowSequenceEntryMappingEnd
    case flowMappingKey(isFirst: Bool)
    case flowMappingValue(isEmpty: Bool)
    case end
  }

  /// The underlying scanner.
  private var scanner: Scanner

  /// The current state.
  private var state = State.streamStart

  /// The stack of states to return to.
  private var states: [State] = []

  /// The tag directives in effect for the current document.
  private var tagDirectives: [String: String] = [:]

  /// The maximum nesting depth of collections.
  private let maximumDepth: Int

  /// The current nesting depth of collections.
  private var depth = 0

  /// Creates a parser for a YAML string.
  ///
  /// - Parameters:
  ///   - string: The YAML text.
  ///   - maximumDepth: The maximum nesting depth of collections. Exceeding
  ///     it raises a ``YAMLError/Kind/limitExceeded`` error.
  public init(string: String, maximumDepth: Int = 512) throws {
    self.scanner = Scanner(try Reader.normalize(string))
    self.maximumDepth = maximumDepth
  }

  /// Creates a parser for YAML data. The character encoding (UTF-8, UTF-16,
  /// or UTF-32) is detected automatically.
  ///
  /// - Parameters:
  ///   - data: The encoded YAML text.
  ///   - maximumDepth: The maximum nesting depth of collections.
  public init(data: Data, maximumDepth: Int = 512) throws {
    self.scanner = Scanner(try Reader.decode(data))
    self.maximumDepth = maximumDepth
  }

  /// Returns the next event or `nil` once the stream has been parsed
  /// completely.
  public mutating func next() throws -> YAMLEvent? {
    switch self.state {
      case .streamStart:
        return try self.parseStreamStart()
      case .documentStart(let isImplicitAllowed):
        return try self.parseDocumentStart(isImplicitAllowed: isImplicitAllowed)
      case .documentContent:
        return try self.parseDocumentContent()
      case .documentEnd:
        return try self.parseDocumentEnd()
      case .blockNode:
        return try self.parseNode(isBlock: true, allowsIndentlessSequence: false)
      case .blockSequenceEntry(let isFirst):
        return try self.parseBlockSequenceEntry(isFirst: isFirst)
      case .indentlessSequenceEntry:
        return try self.parseIndentlessSequenceEntry()
      case .blockMappingKey(let isFirst):
        return try self.parseBlockMappingKey(isFirst: isFirst)
      case .blockMappingValue:
        return try self.parseBlockMappingValue()
      case .flowSequenceEntry(let isFirst):
        return try self.parseFlowSequenceEntry(isFirst: isFirst)
      case .flowSequenceEntryMappingKey:
        return try self.parseFlowSequenceEntryMappingKey()
      case .flowSequenceEntryMappingValue:
        return try self.parseFlowSequenceEntryMappingValue()
      case .flowSequenceEntryMappingEnd:
        return try self.parseFlowSequenceEntryMappingEnd()
      case .flowMappingKey(let isFirst):
        return try self.parseFlowMappingKey(isFirst: isFirst)
      case .flowMappingValue(let isEmpty):
        return try self.parseFlowMappingValue(isEmpty: isEmpty)
      case .end:
        return nil
    }
  }

  /// Parses the remaining stream and returns all events.
  public mutating func parseAll() throws -> [YAMLEvent] {
    var events: [YAMLEvent] = []
    while let event = try self.next() {
      events.append(event)
    }
    return events
  }

  // MARK: - Helpers

  private func error(_ message: String, at token: Token) -> YAMLError {
    return YAMLError(.parser, message, at: token.start)
  }

  private func unexpected(_ token: Token, expected: String) -> YAMLError {
    return YAMLError(.parser, "expected \(expected), but found \(token.name)", at: token.start)
  }

  private mutating func popState() {
    self.state = self.states.removeLast()
  }

  private mutating func enterCollection(at token: Token) throws {
    self.depth += 1
    if self.depth > self.maximumDepth {
      throw YAMLError(.limitExceeded,
                      "maximum nesting depth of \(self.maximumDepth) exceeded",
                      at: token.start)
    }
  }

  private mutating func leaveCollection() {
    self.depth -= 1
  }

  private func emptyScalar(at mark: Mark) -> YAMLEvent {
    return YAMLEvent(.scalar(value: "", style: .plain, tag: nil, anchor: nil), start: mark, end: mark)
  }

  // MARK: - Stream and documents

  private mutating func parseStreamStart() throws -> YAMLEvent {
    let token = try self.scanner.nextToken()
    guard case .streamStart = token.kind else {
      throw self.unexpected(token, expected: "stream start")
    }
    self.state = .documentStart(isImplicitAllowed: true)
    return YAMLEvent(.streamStart, start: token.start, end: token.end)
  }

  /// Parses the start of a document (production [210] `l-any-document`).
  /// A bare document is only allowed at the start of the stream and after
  /// a document end marker (production [211] `l-yaml-stream`).
  private mutating func parseDocumentStart(isImplicitAllowed: Bool) throws -> YAMLEvent {
    var isImplicitAllowed = isImplicitAllowed
    var token = try self.scanner.peekToken()
    while case .documentEnd = token.kind {
      self.scanner.skipToken()
      token = try self.scanner.peekToken()
      isImplicitAllowed = true
    }
    switch token.kind {
      case .streamEnd:
        self.scanner.skipToken()
        self.state = .end
        return YAMLEvent(.streamEnd, start: token.start, end: token.end)
      case .versionDirective, .tagDirective, .reservedDirective, .documentStart:
        let start = token.start
        let (version, directives) = try self.processDirectives()
        token = try self.scanner.peekToken()
        guard case .documentStart = token.kind else {
          throw self.unexpected(token, expected: "document start '---' after directives")
        }
        self.scanner.skipToken()
        self.states.append(.documentEnd)
        self.state = .documentContent
        return YAMLEvent(.documentStart(version: version, tagDirectives: directives, isImplicit: false),
                         start: start,
                         end: token.end)
      default:
        guard isImplicitAllowed else {
          throw self.unexpected(token, expected: "document start '---'")
        }
        self.tagDirectives = [:]
        self.states.append(.documentEnd)
        self.state = .blockNode
        return YAMLEvent(.documentStart(version: nil, tagDirectives: [], isImplicit: true),
                         start: token.start,
                         end: token.start)
    }
  }

  /// Processes the directives preceding an explicit document (section 6.8).
  private mutating func processDirectives() throws -> (YAMLVersion?, [TagDirective]) {
    var version: YAMLVersion? = nil
    var directives: [TagDirective] = []
    self.tagDirectives = [:]
    while true {
      let token = try self.scanner.peekToken()
      switch token.kind {
        case .versionDirective(let v):
          guard version == nil else {
            throw self.error("duplicate %YAML directive", at: token)
          }
          guard v.major == 1 else {
            throw self.error("unsupported YAML version \(v)", at: token)
          }
          version = v
        case .tagDirective(let directive):
          guard self.tagDirectives[directive.handle] == nil else {
            throw self.error("duplicate %TAG directive for handle '\(directive.handle)'", at: token)
          }
          self.tagDirectives[directive.handle] = directive.prefix
          directives.append(directive)
        case .reservedDirective:
          break
        default:
          return (version, directives)
      }
      self.scanner.skipToken()
    }
  }

  private mutating func parseDocumentContent() throws -> YAMLEvent {
    let token = try self.scanner.peekToken()
    switch token.kind {
      case .versionDirective, .tagDirective, .reservedDirective, .documentStart, .documentEnd, .streamEnd:
        self.popState()
        return self.emptyScalar(at: token.start)
      default:
        return try self.parseNode(isBlock: true, allowsIndentlessSequence: false)
    }
  }

  /// Parses the end of a document (production [203] `l-document-suffix`).
  /// Directives may only follow a document that was terminated explicitly.
  private mutating func parseDocumentEnd() throws -> YAMLEvent {
    let token = try self.scanner.peekToken()
    var isImplicit = true
    var end = token.start
    switch token.kind {
      case .documentEnd:
        self.scanner.skipToken()
        isImplicit = false
        end = token.end
      case .documentStart, .streamEnd:
        break
      case .versionDirective, .tagDirective, .reservedDirective:
        throw self.error("directives must be preceded by a document end marker '...'", at: token)
      default:
        throw self.unexpected(token, expected: "end of document")
    }
    self.state = .documentStart(isImplicitAllowed: !isImplicit)
    return YAMLEvent(.documentEnd(isImplicit: isImplicit), start: token.start, end: end)
  }

  // MARK: - Nodes

  /// Parses a node including its properties (production [96]
  /// `c-ns-properties`).
  private mutating func parseNode(isBlock: Bool, allowsIndentlessSequence: Bool) throws -> YAMLEvent {
    var token = try self.scanner.peekToken()
    if case .alias(let name) = token.kind {
      self.scanner.skipToken()
      self.popState()
      return YAMLEvent(.alias(anchor: name), start: token.start, end: token.end)
    }
    let start = token.start
    var end = token.start
    var anchor: String? = nil
    var tag: YAMLTag? = nil
    var tagToken: Token? = nil
    // Properties may appear in any order, each at most once.
    loop: while true {
      switch token.kind {
        case .anchor(let name):
          guard anchor == nil else {
            throw self.error("a node must not have more than one anchor", at: token)
          }
          anchor = name
        case .tag:
          guard tagToken == nil else {
            throw self.error("a node must not have more than one tag", at: token)
          }
          tagToken = token
        default:
          break loop
      }
      end = token.end
      self.scanner.skipToken()
      token = try self.scanner.peekToken()
    }
    if let tagToken, case .tag(let handle, let suffix) = tagToken.kind {
      tag = try self.resolveTag(handle: handle, suffix: suffix, token: tagToken)
    }
    switch token.kind {
      case .blockEntry where allowsIndentlessSequence:
        try self.enterCollection(at: token)
        self.state = .indentlessSequenceEntry
        return YAMLEvent(.sequenceStart(style: .block, tag: tag, anchor: anchor),
                         start: start,
                         end: token.end)
      case .scalar(let value, let style):
        self.scanner.skipToken()
        self.popState()
        return YAMLEvent(.scalar(value: value, style: style, tag: tag, anchor: anchor),
                         start: start,
                         end: token.end)
      case .flowSequenceStart:
        try self.enterCollection(at: token)
        self.state = .flowSequenceEntry(isFirst: true)
        return YAMLEvent(.sequenceStart(style: .flow, tag: tag, anchor: anchor),
                         start: start,
                         end: token.end)
      case .flowMappingStart:
        try self.enterCollection(at: token)
        self.state = .flowMappingKey(isFirst: true)
        return YAMLEvent(.mappingStart(style: .flow, tag: tag, anchor: anchor),
                         start: start,
                         end: token.end)
      case .blockSequenceStart where isBlock:
        try self.enterCollection(at: token)
        self.state = .blockSequenceEntry(isFirst: true)
        return YAMLEvent(.sequenceStart(style: .block, tag: tag, anchor: anchor),
                         start: start,
                         end: token.end)
      case .blockMappingStart where isBlock:
        try self.enterCollection(at: token)
        self.state = .blockMappingKey(isFirst: true)
        return YAMLEvent(.mappingStart(style: .block, tag: tag, anchor: anchor),
                         start: start,
                         end: token.end)
      case .alias:
        throw self.error("an alias node must not have properties", at: token)
      default:
        guard anchor != nil || tag != nil else {
          throw self.unexpected(token, expected: "node content")
        }
        // A node with properties but empty content (production [106]
        // `e-scalar`).
        self.popState()
        return YAMLEvent(.scalar(value: "", style: .plain, tag: tag, anchor: anchor),
                         start: start,
                         end: end)
    }
  }

  /// Resolves a tag property to a full tag (section 6.9.1).
  private func resolveTag(handle: String?, suffix: String, token: Token) throws -> YAMLTag {
    guard let handle else {
      // Verbatim tag.
      return YAMLTag(suffix)
    }
    if handle == "!" && suffix.isEmpty {
      return .nonSpecific
    }
    let prefix: String
    if let p = self.tagDirectives[handle] {
      prefix = p
    } else if handle == "!" {
      prefix = "!"
    } else if handle == "!!" {
      prefix = YAMLTag.yamlPrefix
    } else {
      throw self.error("undefined tag handle '\(handle)'", at: token)
    }
    guard let decoded = YAMLParser.percentDecode(suffix) else {
      throw self.error("invalid percent-encoding in tag '\(handle)\(suffix)'", at: token)
    }
    return YAMLTag(prefix + decoded)
  }

  /// Decodes `%XX` escape sequences of a tag suffix (UTF-8 encoded).
  static func percentDecode(_ string: String) -> String? {
    guard string.contains("%") else {
      return string
    }
    var bytes: [UInt8] = []
    var scalars = Array(string.utf8)[...]
    while let byte = scalars.popFirst() {
      if byte == UInt8(ascii: "%") {
        guard scalars.count >= 2,
              let value = UInt8(String(decoding: scalars.prefix(2), as: UTF8.self), radix: 16) else {
          return nil
        }
        bytes.append(value)
        scalars = scalars.dropFirst(2)
      } else {
        bytes.append(byte)
      }
    }
    return String(bytes: bytes, encoding: .utf8)
  }

  // MARK: - Block collections

  /// Production [183] `l+block-sequence(n)`.
  private mutating func parseBlockSequenceEntry(isFirst: Bool) throws -> YAMLEvent {
    if isFirst {
      self.scanner.skipToken()
    }
    let token = try self.scanner.peekToken()
    switch token.kind {
      case .blockEntry:
        self.scanner.skipToken()
        let next = try self.scanner.peekToken()
        switch next.kind {
          case .blockEntry, .blockEnd:
            self.state = .blockSequenceEntry(isFirst: false)
            return self.emptyScalar(at: token.end)
          default:
            self.states.append(.blockSequenceEntry(isFirst: false))
            return try self.parseNode(isBlock: true, allowsIndentlessSequence: false)
        }
      case .blockEnd:
        self.scanner.skipToken()
        self.popState()
        self.leaveCollection()
        return YAMLEvent(.sequenceEnd, start: token.start, end: token.end)
      default:
        throw self.unexpected(token, expected: "'-' indicator of a block sequence entry")
    }
  }

  /// A block sequence nested in a block mapping at the same indentation
  /// (production [201] `seq-space(n,c)` with `c = block-out`).
  private mutating func parseIndentlessSequenceEntry() throws -> YAMLEvent {
    let token = try self.scanner.peekToken()
    guard case .blockEntry = token.kind else {
      self.popState()
      self.leaveCollection()
      return YAMLEvent(.sequenceEnd, start: token.start, end: token.start)
    }
    self.scanner.skipToken()
    let next = try self.scanner.peekToken()
    switch next.kind {
      case .blockEntry, .key, .value, .blockEnd:
        self.state = .indentlessSequenceEntry
        return self.emptyScalar(at: token.end)
      default:
        self.states.append(.indentlessSequenceEntry)
        return try self.parseNode(isBlock: true, allowsIndentlessSequence: false)
    }
  }

  /// Production [187] `l+block-mapping(n)`.
  private mutating func parseBlockMappingKey(isFirst: Bool) throws -> YAMLEvent {
    if isFirst {
      self.scanner.skipToken()
    }
    let token = try self.scanner.peekToken()
    switch token.kind {
      case .key:
        self.scanner.skipToken()
        let next = try self.scanner.peekToken()
        switch next.kind {
          case .key, .value, .blockEnd:
            self.state = .blockMappingValue
            return self.emptyScalar(at: token.end)
          default:
            self.states.append(.blockMappingValue)
            return try self.parseNode(isBlock: true, allowsIndentlessSequence: true)
        }
      case .value:
        // An entry with an empty key.
        self.state = .blockMappingValue
        return self.emptyScalar(at: token.start)
      case .blockEnd:
        self.scanner.skipToken()
        self.popState()
        self.leaveCollection()
        return YAMLEvent(.mappingEnd, start: token.start, end: token.end)
      default:
        throw self.unexpected(token, expected: "a mapping key")
    }
  }

  private mutating func parseBlockMappingValue() throws -> YAMLEvent {
    let token = try self.scanner.peekToken()
    guard case .value = token.kind else {
      self.state = .blockMappingKey(isFirst: false)
      return self.emptyScalar(at: token.start)
    }
    self.scanner.skipToken()
    let next = try self.scanner.peekToken()
    switch next.kind {
      case .key, .value, .blockEnd:
        self.state = .blockMappingKey(isFirst: false)
        return self.emptyScalar(at: token.end)
      default:
        self.states.append(.blockMappingKey(isFirst: false))
        return try self.parseNode(isBlock: true, allowsIndentlessSequence: true)
    }
  }

  // MARK: - Flow collections

  /// Production [137] `c-flow-sequence(n,c)`.
  private mutating func parseFlowSequenceEntry(isFirst: Bool) throws -> YAMLEvent {
    if isFirst {
      self.scanner.skipToken()
    }
    var token = try self.scanner.peekToken()
    if case .flowSequenceEnd = token.kind {
      self.scanner.skipToken()
      self.popState()
      self.leaveCollection()
      return YAMLEvent(.sequenceEnd, start: token.start, end: token.end)
    }
    if !isFirst {
      guard case .flowEntry = token.kind else {
        throw self.unexpected(token, expected: "',' or ']'")
      }
      self.scanner.skipToken()
      token = try self.scanner.peekToken()
      if case .flowSequenceEnd = token.kind {
        self.scanner.skipToken()
        self.popState()
        self.leaveCollection()
        return YAMLEvent(.sequenceEnd, start: token.start, end: token.end)
      }
    }
    switch token.kind {
      case .key:
        // A single pair mapping with an explicit or implicit key
        // (production [150] `ns-flow-pair`).
        self.scanner.skipToken()
        self.state = .flowSequenceEntryMappingKey
        return YAMLEvent(.mappingStart(style: .flow, tag: nil, anchor: nil),
                         start: token.start,
                         end: token.end)
      case .value:
        // A single pair mapping with an empty key.
        self.state = .flowSequenceEntryMappingKey
        return YAMLEvent(.mappingStart(style: .flow, tag: nil, anchor: nil),
                         start: token.start,
                         end: token.start)
      default:
        self.states.append(.flowSequenceEntry(isFirst: false))
        return try self.parseNode(isBlock: false, allowsIndentlessSequence: false)
    }
  }

  private mutating func parseFlowSequenceEntryMappingKey() throws -> YAMLEvent {
    let token = try self.scanner.peekToken()
    switch token.kind {
      case .value, .flowEntry, .flowSequenceEnd:
        self.state = .flowSequenceEntryMappingValue
        return self.emptyScalar(at: token.start)
      default:
        self.states.append(.flowSequenceEntryMappingValue)
        return try self.parseNode(isBlock: false, allowsIndentlessSequence: false)
    }
  }

  private mutating func parseFlowSequenceEntryMappingValue() throws -> YAMLEvent {
    let token = try self.scanner.peekToken()
    guard case .value = token.kind else {
      self.state = .flowSequenceEntryMappingEnd
      return self.emptyScalar(at: token.start)
    }
    self.scanner.skipToken()
    let next = try self.scanner.peekToken()
    switch next.kind {
      case .flowEntry, .flowSequenceEnd:
        self.state = .flowSequenceEntryMappingEnd
        return self.emptyScalar(at: token.end)
      default:
        self.states.append(.flowSequenceEntryMappingEnd)
        return try self.parseNode(isBlock: false, allowsIndentlessSequence: false)
    }
  }

  private mutating func parseFlowSequenceEntryMappingEnd() throws -> YAMLEvent {
    let token = try self.scanner.peekToken()
    self.state = .flowSequenceEntry(isFirst: false)
    return YAMLEvent(.mappingEnd, start: token.start, end: token.start)
  }

  /// Production [140] `c-flow-mapping(n,c)`.
  private mutating func parseFlowMappingKey(isFirst: Bool) throws -> YAMLEvent {
    if isFirst {
      self.scanner.skipToken()
    }
    var token = try self.scanner.peekToken()
    if case .flowMappingEnd = token.kind {
      self.scanner.skipToken()
      self.popState()
      self.leaveCollection()
      return YAMLEvent(.mappingEnd, start: token.start, end: token.end)
    }
    if !isFirst {
      guard case .flowEntry = token.kind else {
        throw self.unexpected(token, expected: "',' or '}'")
      }
      self.scanner.skipToken()
      token = try self.scanner.peekToken()
      if case .flowMappingEnd = token.kind {
        self.scanner.skipToken()
        self.popState()
        self.leaveCollection()
        return YAMLEvent(.mappingEnd, start: token.start, end: token.end)
      }
    }
    switch token.kind {
      case .key:
        self.scanner.skipToken()
        let next = try self.scanner.peekToken()
        switch next.kind {
          case .value, .flowEntry, .flowMappingEnd:
            self.state = .flowMappingValue(isEmpty: false)
            return self.emptyScalar(at: token.end)
          default:
            self.states.append(.flowMappingValue(isEmpty: false))
            return try self.parseNode(isBlock: false, allowsIndentlessSequence: false)
        }
      case .value:
        // An entry with an empty key.
        self.state = .flowMappingValue(isEmpty: false)
        return self.emptyScalar(at: token.start)
      default:
        // An entry without a value.
        self.states.append(.flowMappingValue(isEmpty: true))
        return try self.parseNode(isBlock: false, allowsIndentlessSequence: false)
    }
  }

  private mutating func parseFlowMappingValue(isEmpty: Bool) throws -> YAMLEvent {
    let token = try self.scanner.peekToken()
    if isEmpty {
      self.state = .flowMappingKey(isFirst: false)
      return self.emptyScalar(at: token.start)
    }
    guard case .value = token.kind else {
      self.state = .flowMappingKey(isFirst: false)
      return self.emptyScalar(at: token.start)
    }
    self.scanner.skipToken()
    let next = try self.scanner.peekToken()
    switch next.kind {
      case .flowEntry, .flowMappingEnd:
        self.state = .flowMappingKey(isFirst: false)
        return self.emptyScalar(at: token.end)
      default:
        self.states.append(.flowMappingKey(isFirst: false))
        return try self.parseNode(isBlock: false, allowsIndentlessSequence: false)
    }
  }
}
