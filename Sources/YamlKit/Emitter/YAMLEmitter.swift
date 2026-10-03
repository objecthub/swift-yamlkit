//
//  YAMLEmitter.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// Turns a stream of ``YAMLEvent`` values into YAML text
/// (YAML 1.2.2, section 3.1.3 "Present").
///
/// The emitter honors the requested presentation styles where possible and
/// falls back to a style that can represent the content otherwise; e.g. a
/// plain scalar that contains `": "` is emitted single-quoted, and a scalar
/// that contains non-printable characters is emitted double-quoted. Empty
/// collections are always emitted in flow style.
///
/// ```swift
/// var emitter = YAMLEmitter()
/// try emitter.emit(YAMLEvent(.streamStart))
/// try emitter.emit(YAMLEvent(.documentStart(version: nil, tagDirectives: [], isImplicit: true)))
/// try emitter.emit(.scalar("Hello, world!"))
/// try emitter.emit(YAMLEvent(.documentEnd(isImplicit: true)))
/// try emitter.emit(YAMLEvent(.streamEnd))
/// print(emitter.output) // Hello, world!
/// ```
public struct YAMLEmitter {

  /// Options controlling the formatting of the output.
  public struct Options: Sendable, Hashable {

    /// The number of spaces used for each level of indentation (2...9).
    public var indentation: Int

    /// The preferred maximum line width. Longer lines are folded where
    /// possible. Use `Int.max` to disable folding.
    public var lineWidth: Int

    /// Can non-ASCII characters be written unescaped?
    public var allowsUnicode: Bool

    /// Should block sequences nested in block mappings be indented?
    ///
    /// ```yaml
    /// # true          # false
    /// key:            key:
    ///   - a           - a
    ///   - b           - b
    /// ```
    public var indentsSequencesInMappings: Bool

    /// Should every document start with an explicit `---` marker?
    public var explicitDocumentStart: Bool

    /// Creates formatting options.
    public init(indentation: Int = 2,
                lineWidth: Int = 80,
                allowsUnicode: Bool = true,
                indentsSequencesInMappings: Bool = true,
                explicitDocumentStart: Bool = false) {
      self.indentation = indentation
      self.lineWidth = lineWidth
      self.allowsUnicode = allowsUnicode
      self.indentsSequencesInMappings = indentsSequencesInMappings
      self.explicitDocumentStart = explicitDocumentStart
    }
  }

  /// The states of the emitter state machine.
  private enum State {
    case streamStart
    case documentStart(isFirst: Bool)
    case documentContent
    case documentEnd
    case flowSequenceItem(isFirst: Bool)
    case flowMappingKey(isFirst: Bool)
    case flowMappingValue(isSimple: Bool)
    case blockSequenceItem(isFirst: Bool)
    case blockMappingKey(isFirst: Bool)
    case blockMappingValue(isSimple: Bool)
    case end
  }

  /// The result of analyzing a scalar.
  private struct ScalarAnalysis {
    var isMultiline = false
    var isFlowPlainAllowed = true
    var isBlockPlainAllowed = true
    var isSingleQuotedAllowed = true
    var isBlockAllowed = true
  }

  /// The formatting options.
  public let options: Options

  /// The text emitted so far.
  public private(set) var output = ""

  // MARK: - State

  private var state = State.streamStart
  private var states: [State] = []
  private var events: [YAMLEvent] = []
  private var head = 0
  private var indent = -1
  private var indents: [Int] = []
  private var flowLevel = 0
  private var isRootContext = false
  private var isSequenceContext = false
  private var isMappingContext = false
  private var isSimpleKeyContext = false
  private var column = 0
  private var isWhitespace = true
  private var isIndention = true
  private var isOpenEnded = false
  private var tagDirectives: [TagDirective] = []
  private var needsSpaceBeforeValueIndicator = false

  /// Creates an emitter.
  public init(options: Options = Options()) {
    var options = options
    options.indentation = min(max(options.indentation, 2), 9)
    options.lineWidth = max(options.lineWidth, options.indentation * 2 + 1)
    self.options = options
  }

  /// Emits an event.
  public mutating func emit(_ event: YAMLEvent) throws {
    self.events.append(event)
    while !self.needsMoreEvents() {
      try self.process(self.events[self.head])
      self.head += 1
      if self.head > 32 && self.head * 2 > self.events.count {
        self.events.removeFirst(self.head)
        self.head = 0
      }
    }
  }

  /// Emits a sequence of events.
  public mutating func emit<S: Swift.Sequence>(contentsOf events: S) throws where S.Element == YAMLEvent {
    for event in events {
      try self.emit(event)
    }
  }

  /// Some events require lookahead: document starts need one event to check
  /// for empty documents, collection starts need to know whether the
  /// collection is empty or short enough to be a simple key.
  private func needsMoreEvents() -> Bool {
    guard self.head < self.events.count else {
      return true
    }
    let accumulate: Int
    switch self.events[self.head].kind {
      case .documentStart:
        accumulate = 1
      case .sequenceStart:
        accumulate = 2
      case .mappingStart:
        accumulate = 3
      default:
        return false
    }
    if self.events.count - self.head > accumulate {
      return false
    }
    var level = 0
    for event in self.events[self.head...] {
      switch event.kind {
        case .streamStart, .documentStart, .sequenceStart, .mappingStart:
          level += 1
        case .streamEnd, .documentEnd, .sequenceEnd, .mappingEnd:
          level -= 1
        default:
          break
      }
      if level == 0 {
        return false
      }
    }
    return true
  }

  private func error(_ message: String) -> YAMLError {
    return YAMLError(.emitter, message)
  }

  // MARK: - State machine

  private mutating func process(_ event: YAMLEvent) throws {
    switch self.state {
      case .streamStart:
        try self.emitStreamStart(event)
      case .documentStart(let isFirst):
        try self.emitDocumentStart(event, isFirst: isFirst)
      case .documentContent:
        try self.emitDocumentContent(event)
      case .documentEnd:
        try self.emitDocumentEnd(event)
      case .flowSequenceItem(let isFirst):
        try self.emitFlowSequenceItem(event, isFirst: isFirst)
      case .flowMappingKey(let isFirst):
        try self.emitFlowMappingKey(event, isFirst: isFirst)
      case .flowMappingValue(let isSimple):
        try self.emitFlowMappingValue(event, isSimple: isSimple)
      case .blockSequenceItem(let isFirst):
        try self.emitBlockSequenceItem(event, isFirst: isFirst)
      case .blockMappingKey(let isFirst):
        try self.emitBlockMappingKey(event, isFirst: isFirst)
      case .blockMappingValue(let isSimple):
        try self.emitBlockMappingValue(event, isSimple: isSimple)
      case .end:
        throw self.error("unexpected event \(event.kind) after the end of the stream")
    }
  }

  private mutating func emitStreamStart(_ event: YAMLEvent) throws {
    guard case .streamStart = event.kind else {
      throw self.error("expected stream start, but found \(event.kind)")
    }
    self.indent = -1
    self.column = 0
    self.isWhitespace = true
    self.isIndention = true
    self.state = .documentStart(isFirst: true)
  }

  private mutating func emitDocumentStart(_ event: YAMLEvent, isFirst: Bool) throws {
    switch event.kind {
      case .documentStart(let version, let directives, let isImplicit):
        let hasDirectives = version != nil || !directives.isEmpty
        if hasDirectives && self.isOpenEnded {
          // Directives may only follow an explicitly terminated document.
          self.writeIndicator("...", needsWhitespace: true)
          self.writeIndent()
        }
        self.isOpenEnded = false
        if let version {
          self.writeIndicator("%YAML", needsWhitespace: true)
          self.writeIndicator(version.description, needsWhitespace: true)
          self.writeIndent()
        }
        self.tagDirectives = []
        for directive in directives {
          guard YAMLEmitter.isValidTagHandle(directive.handle) else {
            throw self.error("invalid tag handle '\(directive.handle)'")
          }
          guard !directive.prefix.isEmpty else {
            throw self.error("tag prefix must not be empty")
          }
          if !self.tagDirectives.contains(where: { $0.handle == directive.handle }) {
            self.tagDirectives.append(directive)
          }
          self.writeIndicator("%TAG", needsWhitespace: true)
          self.writeIndicator(directive.handle, needsWhitespace: true)
          self.writeIndicator(YAMLEmitter.escapeURI(directive.prefix, allowsAllURIChars: true),
                              needsWhitespace: true)
          self.writeIndent()
        }
        var isImplicit = isImplicit && isFirst && !hasDirectives && !self.options.explicitDocumentStart
        if isImplicit && self.isEmptyDocument() {
          // An empty implicit document would vanish.
          isImplicit = false
        }
        if !isImplicit {
          self.writeIndent()
          self.writeIndicator("---", needsWhitespace: true)
        }
        self.state = .documentContent
      case .streamEnd:
        self.state = .end
      default:
        throw self.error("expected document start or stream end, but found \(event.kind)")
    }
  }

  private mutating func emitDocumentContent(_ event: YAMLEvent) throws {
    self.states.append(.documentEnd)
    try self.emitNode(event, isRoot: true)
  }

  private mutating func emitDocumentEnd(_ event: YAMLEvent) throws {
    guard case .documentEnd(let isImplicit) = event.kind else {
      throw self.error("expected document end, but found \(event.kind)")
    }
    self.writeIndent()
    if !isImplicit {
      self.writeIndicator("...", needsWhitespace: true)
      self.isOpenEnded = false
      self.writeIndent()
    } else {
      self.isOpenEnded = true
    }
    self.state = .documentStart(isFirst: false)
  }

  /// Is the next document empty (i.e. does it consist of an empty plain
  /// scalar without properties)?
  private func isEmptyDocument() -> Bool {
    guard self.head + 1 < self.events.count,
          case .scalar(let value, let style, let tag, let anchor) = self.events[self.head + 1].kind else {
      return false
    }
    return value.isEmpty && style == .plain && tag == nil && anchor == nil
  }

  // MARK: - Flow collections

  private mutating func emitFlowSequenceItem(_ event: YAMLEvent, isFirst: Bool) throws {
    if isFirst {
      self.writeIndicator("[", needsWhitespace: true, isWhitespace: true)
      self.increaseIndent(isFlow: true)
      self.flowLevel += 1
    }
    if case .sequenceEnd = event.kind {
      self.flowLevel -= 1
      self.indent = self.indents.removeLast()
      self.writeIndicator("]", needsWhitespace: false)
      self.needsSpaceBeforeValueIndicator = false
      self.state = self.states.removeLast()
      return
    }
    if !isFirst {
      self.writeIndicator(",", needsWhitespace: false)
    }
    if self.column > self.options.lineWidth {
      self.writeIndent()
    }
    self.states.append(.flowSequenceItem(isFirst: false))
    try self.emitNode(event, inSequence: true)
  }

  private mutating func emitFlowMappingKey(_ event: YAMLEvent, isFirst: Bool) throws {
    if isFirst {
      self.writeIndicator("{", needsWhitespace: true, isWhitespace: true)
      self.increaseIndent(isFlow: true)
      self.flowLevel += 1
    }
    if case .mappingEnd = event.kind {
      self.flowLevel -= 1
      self.indent = self.indents.removeLast()
      self.writeIndicator("}", needsWhitespace: false)
      self.needsSpaceBeforeValueIndicator = false
      self.state = self.states.removeLast()
      return
    }
    if !isFirst {
      self.writeIndicator(",", needsWhitespace: false)
    }
    if self.column > self.options.lineWidth {
      self.writeIndent()
    }
    if self.isSimpleKey() {
      self.states.append(.flowMappingValue(isSimple: true))
      try self.emitNode(event, inMapping: true, isSimpleKey: true)
    } else {
      self.writeIndicator("?", needsWhitespace: true)
      self.states.append(.flowMappingValue(isSimple: false))
      try self.emitNode(event, inMapping: true)
    }
  }

  private mutating func emitFlowMappingValue(_ event: YAMLEvent, isSimple: Bool) throws {
    if isSimple {
      self.writeIndicator(":", needsWhitespace: self.needsSpaceBeforeValueIndicator)
    } else {
      if self.column > self.options.lineWidth {
        self.writeIndent()
      }
      self.writeIndicator(":", needsWhitespace: true)
    }
    self.states.append(.flowMappingKey(isFirst: false))
    try self.emitNode(event, inMapping: true)
  }

  // MARK: - Block collections

  private mutating func emitBlockSequenceItem(_ event: YAMLEvent, isFirst: Bool) throws {
    if isFirst {
      let isIndentless = self.isMappingContext && !self.isIndention
        && !self.options.indentsSequencesInMappings
      self.increaseIndent(isFlow: false, isIndentless: isIndentless)
    }
    if case .sequenceEnd = event.kind {
      self.indent = self.indents.removeLast()
      self.state = self.states.removeLast()
      return
    }
    self.writeIndent()
    self.writeIndicator("-", needsWhitespace: true, isIndention: true)
    self.states.append(.blockSequenceItem(isFirst: false))
    try self.emitNode(event, inSequence: true)
  }

  private mutating func emitBlockMappingKey(_ event: YAMLEvent, isFirst: Bool) throws {
    if isFirst {
      self.increaseIndent(isFlow: false)
    }
    if case .mappingEnd = event.kind {
      self.indent = self.indents.removeLast()
      self.state = self.states.removeLast()
      return
    }
    self.writeIndent()
    if self.isSimpleKey() {
      self.states.append(.blockMappingValue(isSimple: true))
      try self.emitNode(event, inMapping: true, isSimpleKey: true)
    } else {
      self.writeIndicator("?", needsWhitespace: true, isIndention: true)
      self.states.append(.blockMappingValue(isSimple: false))
      try self.emitNode(event, inMapping: true)
    }
  }

  private mutating func emitBlockMappingValue(_ event: YAMLEvent, isSimple: Bool) throws {
    if isSimple {
      self.writeIndicator(":", needsWhitespace: self.needsSpaceBeforeValueIndicator)
    } else {
      self.writeIndent()
      self.writeIndicator(":", needsWhitespace: true, isIndention: true)
    }
    self.states.append(.blockMappingKey(isFirst: false))
    try self.emitNode(event, inMapping: true)
  }

  // MARK: - Nodes

  private mutating func emitNode(_ event: YAMLEvent,
                                 isRoot: Bool = false,
                                 inSequence: Bool = false,
                                 inMapping: Bool = false,
                                 isSimpleKey: Bool = false) throws {
    self.isRootContext = isRoot
    self.isSequenceContext = inSequence
    self.isMappingContext = inMapping
    self.isSimpleKeyContext = isSimpleKey
    self.needsSpaceBeforeValueIndicator = false
    switch event.kind {
      case .alias(let anchor):
        try self.writeAnchor(anchor, indicator: "*")
        self.needsSpaceBeforeValueIndicator = true
        self.state = self.states.removeLast()
      case .scalar(let value, let style, let tag, let anchor):
        try self.emitScalar(value: value, style: style, tag: tag, anchor: anchor)
      case .sequenceStart(let style, let tag, let anchor):
        if let anchor {
          try self.writeAnchor(anchor, indicator: "&")
        }
        if let tag {
          try self.writeTag(tag)
        }
        if self.flowLevel > 0 || style == .flow || self.isEmptyCollection() {
          self.state = .flowSequenceItem(isFirst: true)
        } else {
          self.state = .blockSequenceItem(isFirst: true)
        }
      case .mappingStart(let style, let tag, let anchor):
        if let anchor {
          try self.writeAnchor(anchor, indicator: "&")
        }
        if let tag {
          try self.writeTag(tag)
        }
        if self.flowLevel > 0 || style == .flow || self.isEmptyCollection() {
          self.state = .flowMappingKey(isFirst: true)
        } else {
          self.state = .blockMappingKey(isFirst: true)
        }
      default:
        throw self.error("expected a node, but found \(event.kind)")
    }
  }

  /// Is the collection starting at the current event empty?
  private func isEmptyCollection() -> Bool {
    guard self.head + 1 < self.events.count else {
      return false
    }
    switch (self.events[self.head].kind, self.events[self.head + 1].kind) {
      case (.sequenceStart, .sequenceEnd), (.mappingStart, .mappingEnd):
        return true
      default:
        return false
    }
  }

  /// Can the node starting at the current event be emitted as an implicit
  /// key? Implicit keys are restricted to a single line of at most 1024
  /// characters (YAML 1.2.2, section 7.4.2).
  private func isSimpleKey() -> Bool {
    let event = self.events[self.head]
    var length = 0
    switch event.kind {
      case .alias(let anchor):
        length = anchor.count
      case .scalar(let value, _, let tag, let anchor):
        if value.contains(where: { $0 == "\n" || $0 == "\r\n" }) {
          return false
        }
        length = value.unicodeScalars.count + (anchor?.count ?? 0) + (tag?.rawValue.count ?? 0)
      case .sequenceStart(_, let tag, let anchor), .mappingStart(_, let tag, let anchor):
        guard self.isEmptyCollection() else {
          return false
        }
        length = (anchor?.count ?? 0) + (tag?.rawValue.count ?? 0)
      default:
        return false
    }
    return length <= 128
  }

  // MARK: - Scalars

  private mutating func emitScalar(value: String, style: ScalarStyle, tag: YAMLTag?, anchor: String?) throws {
    let analysis = self.analyze(value)
    let hasProperties = tag != nil || anchor != nil
    let style = self.selectStyle(style, for: value, analysis: analysis, hasProperties: hasProperties)
    if let anchor {
      try self.writeAnchor(anchor, indicator: "&")
    }
    if let tag {
      try self.writeTag(tag)
    }
    let parentIndent = self.indent
    self.increaseIndent(isFlow: true)
    switch style {
      case .plain:
        self.writePlain(value, allowsBreaks: !self.isSimpleKeyContext)
      case .singleQuoted:
        self.writeSingleQuoted(value, allowsBreaks: !self.isSimpleKeyContext)
      case .doubleQuoted:
        self.writeDoubleQuoted(value, allowsBreaks: !self.isSimpleKeyContext)
      case .literal:
        self.writeLiteral(value, parentIndent: parentIndent)
      case .folded:
        self.writeFolded(value, parentIndent: parentIndent)
    }
    self.indent = self.indents.removeLast()
    self.state = self.states.removeLast()
    // An empty plain scalar with properties must be separated from a
    // following value indicator, e.g. `&anchor : value`.
    self.needsSpaceBeforeValueIndicator = value.isEmpty && style == .plain && hasProperties
  }

  /// Chooses the style for a scalar, honoring the requested style if the
  /// content allows it.
  private func selectStyle(_ requested: ScalarStyle,
                           for value: String,
                           analysis: ScalarAnalysis,
                           hasProperties: Bool) -> ScalarStyle {
    var style = requested
    if self.isSimpleKeyContext && analysis.isMultiline {
      return .doubleQuoted
    }
    if style == .plain {
      if (self.flowLevel > 0 && !analysis.isFlowPlainAllowed)
          || (self.flowLevel == 0 && !analysis.isBlockPlainAllowed) {
        style = .singleQuoted
      } else if value.isEmpty && !hasProperties && self.flowLevel > 0 && self.isSequenceContext {
        // An empty entry of a flow sequence cannot be expressed in plain
        // style.
        style = .singleQuoted
      }
    }
    if style == .singleQuoted && !analysis.isSingleQuotedAllowed {
      style = .doubleQuoted
    }
    if style.isBlock {
      if !analysis.isBlockAllowed || self.flowLevel > 0 || self.isSimpleKeyContext {
        style = .doubleQuoted
      } else if self.isRootContext, let first = value.unicodeScalars.first,
                Scanner.isBlank(first) || first == "\n" {
        // The indentation indicator of a top-level block scalar is
        // interpreted differently by YAML 1.1 and YAML 1.2 parsers.
        style = .doubleQuoted
      }
    }
    return style
  }

  /// Analyzes the content of a scalar to determine the admissible styles.
  private func analyze(_ value: String) -> ScalarAnalysis {
    var analysis = ScalarAnalysis()
    let scalars = Array(value.unicodeScalars)
    guard !scalars.isEmpty else {
      // Empty plain scalars are restricted by `selectStyle`.
      analysis.isBlockAllowed = false
      return analysis
    }
    var hasFlowIndicators = false
    var hasBlockIndicators = false
    var hasLineBreaks = false
    var hasSpecialCharacters = false
    var hasLeadingSpace = false
    var hasLeadingBreak = false
    var hasTrailingSpace = false
    var hasTrailingBreak = false
    var hasBreakSpace = false
    var hasSpaceBreak = false
    var previousSpace = false
    var previousBreak = false
    if scalars.count >= 3 {
      let prefix = String(String.UnicodeScalarView(scalars[0..<3]))
      if prefix == "---" || prefix == "..." {
        hasFlowIndicators = true
        hasBlockIndicators = true
      }
    }
    func isBlankOrEnd(_ i: Int) -> Bool {
      return i >= scalars.count || Scanner.isBlankOrBreakOrEnd(scalars[i])
    }
    func isFlowSafe(_ i: Int) -> Bool {
      return i < scalars.count && !Scanner.isBlankOrBreakOrEnd(scalars[i])
        && !Scanner.isFlowIndicator(scalars[i])
    }
    var precededByWhitespace = true
    for (i, c) in scalars.enumerated() {
      let followedByWhitespace = isBlankOrEnd(i + 1)
      // Production [126] `ns-plain-first(c)` and [130] `ns-plain-char(c)`.
      if i == 0 {
        switch c {
          case "#", ",", "[", "]", "{", "}", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`":
            hasFlowIndicators = true
            hasBlockIndicators = true
          case "?", ":", "-":
            if followedByWhitespace {
              hasBlockIndicators = true
            }
            if !isFlowSafe(i + 1) {
              hasFlowIndicators = true
            }
          default:
            break
        }
      } else {
        switch c {
          case ",", "[", "]", "{", "}":
            hasFlowIndicators = true
          case ":":
            if followedByWhitespace {
              hasBlockIndicators = true
            }
            if !isFlowSafe(i + 1) {
              hasFlowIndicators = true
            }
          case "#":
            if precededByWhitespace {
              hasFlowIndicators = true
              hasBlockIndicators = true
            }
          default:
            break
        }
      }
      // NEL, LS and PS are line breaks in YAML 1.1; escape them for
      // interoperability.
      if !YAMLEmitter.isPrintable(c) || (!c.isASCII && !self.options.allowsUnicode)
          || c == "\u{FEFF}" || c == "\u{85}" || c == "\u{2028}" || c == "\u{2029}" {
        hasSpecialCharacters = true
      }
      if c == "\n" {
        hasLineBreaks = true
      }
      if Scanner.isBlank(c) {
        if i == 0 {
          hasLeadingSpace = true
        }
        if i == scalars.count - 1 {
          hasTrailingSpace = true
        }
        if previousBreak {
          hasBreakSpace = true
        }
        previousSpace = true
        previousBreak = false
      } else if c == "\n" {
        if i == 0 {
          hasLeadingBreak = true
        }
        if i == scalars.count - 1 {
          hasTrailingBreak = true
        }
        if previousSpace {
          hasSpaceBreak = true
        }
        previousBreak = true
        previousSpace = false
      } else {
        previousSpace = false
        previousBreak = false
      }
      precededByWhitespace = Scanner.isBlankOrBreakOrEnd(c)
    }
    analysis.isMultiline = hasLineBreaks
    if hasLeadingSpace || hasLeadingBreak || hasTrailingSpace || hasTrailingBreak {
      analysis.isFlowPlainAllowed = false
      analysis.isBlockPlainAllowed = false
    }
    if hasTrailingSpace {
      analysis.isBlockAllowed = false
    }
    if hasBreakSpace {
      analysis.isFlowPlainAllowed = false
      analysis.isBlockPlainAllowed = false
      analysis.isSingleQuotedAllowed = false
    }
    if hasSpaceBreak || hasSpecialCharacters {
      analysis.isFlowPlainAllowed = false
      analysis.isBlockPlainAllowed = false
      analysis.isSingleQuotedAllowed = false
      analysis.isBlockAllowed = false
    }
    if hasLineBreaks {
      analysis.isFlowPlainAllowed = false
      analysis.isBlockPlainAllowed = false
    }
    if hasFlowIndicators {
      analysis.isFlowPlainAllowed = false
    }
    if hasBlockIndicators {
      analysis.isBlockPlainAllowed = false
    }
    return analysis
  }

  /// Is `c` printable (production [1] `c-printable`) and not a line break
  /// that would be normalized by a parser?
  private static func isPrintable(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
      case 0x0A, 0x20...0x7E, 0x85, 0xA0...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
        return true
      case 0x09:
        return true
      default:
        return false
    }
  }

  // MARK: - Writing primitives

  private mutating func write(_ c: Unicode.Scalar) {
    self.output.unicodeScalars.append(c)
    self.column += 1
  }

  private mutating func write(_ string: String) {
    for c in string.unicodeScalars {
      self.write(c)
    }
  }

  private mutating func writeBreak() {
    self.output.unicodeScalars.append("\n")
    self.column = 0
  }

  private mutating func increaseIndent(isFlow: Bool, isIndentless: Bool = false) {
    self.indents.append(self.indent)
    if self.indent < 0 {
      self.indent = isFlow ? self.options.indentation : 0
    } else if !isIndentless {
      self.indent += self.options.indentation
    }
  }

  private mutating func writeIndent() {
    let indent = max(self.indent, 0)
    if !self.isIndention || self.column > indent || (self.column == indent && !self.isWhitespace) {
      self.writeBreak()
    }
    while self.column < indent {
      self.write(" ")
    }
    self.isWhitespace = true
    self.isIndention = true
  }

  private mutating func writeIndicator(_ indicator: String,
                                       needsWhitespace: Bool,
                                       isWhitespace: Bool = false,
                                       isIndention: Bool = false) {
    if needsWhitespace && !self.isWhitespace {
      self.write(" ")
    }
    self.write(indicator)
    self.isWhitespace = isWhitespace
    self.isIndention = self.isIndention && isIndention
    self.isOpenEnded = false
  }

  private mutating func writeAnchor(_ anchor: String, indicator: Unicode.Scalar) throws {
    guard !anchor.isEmpty,
          anchor.unicodeScalars.allSatisfy({ !Scanner.isBlankOrBreakOrEnd($0)
                                             && !Scanner.isFlowIndicator($0)
                                             && YAMLEmitter.isPrintable($0)
                                             && $0 != "\u{FEFF}" }) else {
      throw self.error("invalid anchor name '\(anchor)'")
    }
    self.writeIndicator(String(indicator) + anchor, needsWhitespace: true)
    self.needsSpaceBeforeValueIndicator = true
  }

  private mutating func writeTag(_ tag: YAMLTag) throws {
    let raw = tag.rawValue
    guard !raw.isEmpty else {
      throw self.error("tag must not be empty")
    }
    if raw == "!" {
      self.writeIndicator("!", needsWhitespace: true)
      self.needsSpaceBeforeValueIndicator = true
      return
    }
    // Find the longest matching tag directive.
    var directives = self.tagDirectives
    for directive in TagDirective.defaults
        where !directives.contains(where: { $0.handle == directive.handle }) {
      directives.append(directive)
    }
    var best: TagDirective? = nil
    for directive in directives where raw.hasPrefix(directive.prefix) && raw.count > directive.prefix.count {
      if best == nil || directive.prefix.count > best!.prefix.count {
        best = directive
      }
    }
    if let best {
      let suffix = String(raw.dropFirst(best.prefix.count))
      self.writeIndicator(best.handle + YAMLEmitter.escapeURI(suffix, allowsAllURIChars: false),
                          needsWhitespace: true)
    } else {
      self.writeIndicator("!<" + YAMLEmitter.escapeURI(raw, allowsAllURIChars: true) + ">",
                          needsWhitespace: true)
    }
    self.needsSpaceBeforeValueIndicator = true
  }

  /// Percent-encodes all characters of `string` that are not allowed in a
  /// URI (production [39] `ns-uri-char`) or tag suffix (production [40]
  /// `ns-tag-char`).
  ///
  /// Verbatim tags are not percent-decoded by the parser, hence existing
  /// escape sequences are retained if `allowsAllURIChars` is `true`.
  static func escapeURI(_ string: String, allowsAllURIChars: Bool) -> String {
    var result = ""
    let scalars = Array(string.unicodeScalars)
    for (i, c) in scalars.enumerated() {
      let allowed = allowsAllURIChars ? Scanner.isURIChar(c) : Scanner.isTagChar(c)
      let isEscape = allowsAllURIChars && c == "%" && i + 2 < scalars.count
        && Scanner.isHexDigit(scalars[i + 1]) && Scanner.isHexDigit(scalars[i + 2])
      if (allowed && c != "%") || isEscape {
        result.unicodeScalars.append(c)
      } else {
        for byte in String(c).utf8 {
          result += "%" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
        }
      }
    }
    return result
  }

  /// Is `handle` a valid tag handle (production [89] `c-tag-handle`)?
  static func isValidTagHandle(_ handle: String) -> Bool {
    let scalars = Array(handle.unicodeScalars)
    guard scalars.first == "!" else {
      return false
    }
    if scalars.count == 1 {
      return true
    }
    guard scalars.last == "!" else {
      return false
    }
    return scalars.dropFirst().dropLast().allSatisfy(Scanner.isWordChar)
  }

  // MARK: - Writing scalars

  private mutating func writePlain(_ value: String, allowsBreaks: Bool) {
    if !self.isWhitespace && !value.isEmpty {
      self.write(" ")
    }
    let scalars = Array(value.unicodeScalars)
    var spaces = false
    for (i, c) in scalars.enumerated() {
      if c == " " {
        if allowsBreaks && !spaces && self.column > self.options.lineWidth
            && i + 1 < scalars.count && scalars[i + 1] != " " && scalars[i + 1] != "\t" {
          self.writeIndent()
        } else {
          self.write(c)
        }
        spaces = true
      } else {
        self.write(c)
        spaces = Scanner.isBlank(c)
        self.isWhitespace = false
        self.isIndention = false
      }
    }
    self.isWhitespace = self.isWhitespace && value.isEmpty
    self.isIndention = self.isIndention && value.isEmpty
  }

  private mutating func writeSingleQuoted(_ value: String, allowsBreaks: Bool) {
    self.writeIndicator("'", needsWhitespace: true)
    let scalars = Array(value.unicodeScalars)
    var spaces = false
    var breaks = false
    for (i, c) in scalars.enumerated() {
      if c == " " {
        if allowsBreaks && !spaces && self.column > self.options.lineWidth
            && i != 0 && i != scalars.count - 1 && !Scanner.isBlank(scalars[i + 1]) {
          self.writeIndent()
        } else {
          self.write(c)
        }
        spaces = true
      } else if c == "\n" {
        if !breaks {
          // A single line break is folded into a space; it must be
          // represented by an empty line.
          self.writeBreak()
        }
        self.writeBreak()
        self.isIndention = true
        breaks = true
      } else {
        if breaks {
          self.writeIndent()
        }
        self.write(c)
        if c == "'" {
          self.write("'")
        }
        self.isIndention = false
        spaces = Scanner.isBlank(c)
        breaks = false
      }
    }
    if breaks {
      self.writeIndent()
    }
    self.writeIndicator("'", needsWhitespace: false)
  }

  private mutating func writeDoubleQuoted(_ value: String, allowsBreaks: Bool) {
    self.writeIndicator("\"", needsWhitespace: true)
    let scalars = Array(value.unicodeScalars)
    var spaces = false
    var atLineStart = false
    for (i, c) in scalars.enumerated() {
      // Tabs are escaped where they would be trimmed as leading or trailing
      // white space of a line.
      let isTrimmableTab = c == "\t" && (i == 0 || i == scalars.count - 1 || atLineStart)
      atLineStart = false
      if !YAMLEmitter.isPrintable(c) || (!self.options.allowsUnicode && !c.isASCII)
          || c == "\u{FEFF}" || c == "\n" || c == "\"" || c == "\\" || c == "\u{85}"
          || c == "\u{2028}" || c == "\u{2029}" || isTrimmableTab {
        self.write("\\")
        switch c {
          case "\0": self.write("0")
          case "\u{07}": self.write("a")
          case "\u{08}": self.write("b")
          case "\t": self.write("t")
          case "\n": self.write("n")
          case "\u{0B}": self.write("v")
          case "\u{0C}": self.write("f")
          case "\r": self.write("r")
          case "\u{1B}": self.write("e")
          case "\"": self.write("\"")
          case "\\": self.write("\\")
          case "\u{85}": self.write("N")
          case "\u{A0}": self.write("_")
          case "\u{2028}": self.write("L")
          case "\u{2029}": self.write("P")
          default:
            if c.value <= 0xFF {
              self.write("x" + String(c.value, radix: 16, uppercase: true).leftPadded(to: 2))
            } else if c.value <= 0xFFFF {
              self.write("u" + String(c.value, radix: 16, uppercase: true).leftPadded(to: 4))
            } else {
              self.write("U" + String(c.value, radix: 16, uppercase: true).leftPadded(to: 8))
            }
        }
        spaces = false
      } else if c == " " {
        if allowsBreaks && !spaces && self.column > self.options.lineWidth
            && i != 0 && i != scalars.count - 1 {
          self.writeIndent()
          // A space at the start of the continuation line must be escaped
          // (`\ `); a tab is escaped when it is written.
          if scalars[i + 1] == " " {
            self.write("\\")
          }
          atLineStart = true
        } else {
          self.write(c)
        }
        spaces = true
      } else {
        self.write(c)
        spaces = c == "\t"
      }
    }
    self.writeIndicator("\"", needsWhitespace: false)
  }

  /// Writes the header of a block scalar: an indentation indicator if the
  /// content starts with a space or line break, and a chomping indicator.
  private mutating func writeBlockScalarHints(_ value: String, parentIndent: Int) {
    let scalars = Array(value.unicodeScalars)
    var hints = ""
    if let first = scalars.first, Scanner.isBlank(first) || first == "\n" {
      hints += String(self.indent - parentIndent)
    }
    if scalars.last != "\n" {
      hints += "-"
    } else if scalars.count == 1 {
      hints += "+"
    } else if scalars[scalars.count - 2] == "\n" {
      hints += "+"
    }
    if !hints.isEmpty {
      self.writeIndicator(hints, needsWhitespace: false)
    }
  }

  private mutating func writeLiteral(_ value: String, parentIndent: Int) {
    self.writeIndicator("|", needsWhitespace: true)
    self.writeBlockScalarHints(value, parentIndent: parentIndent)
    self.writeBreak()
    self.isIndention = true
    self.isWhitespace = true
    var breaks = true
    for c in value.unicodeScalars {
      if c == "\n" {
        self.writeBreak()
        self.isIndention = true
        breaks = true
      } else {
        if breaks {
          self.writeIndent()
        }
        self.write(c)
        self.isIndention = false
        breaks = false
      }
    }
    // The block scalar is terminated by the next line break.
    if !breaks {
      self.writeBreak()
    }
    self.isIndention = true
    self.isWhitespace = true
  }

  private mutating func writeFolded(_ value: String, parentIndent: Int) {
    self.writeIndicator(">", needsWhitespace: true)
    self.writeBlockScalarHints(value, parentIndent: parentIndent)
    self.writeBreak()
    self.isIndention = true
    self.isWhitespace = true
    let scalars = Array(value.unicodeScalars)
    var breaks = true
    var leadingSpaces = true
    for (i, c) in scalars.enumerated() {
      if c == "\n" {
        if !breaks && !leadingSpaces {
          // A line break between two non-indented lines would be folded
          // into a space; preserve it by adding an empty line unless the
          // next line is more indented.
          var k = i
          while k < scalars.count && scalars[k] == "\n" {
            k += 1
          }
          if k < scalars.count && !Scanner.isBlank(scalars[k]) {
            self.writeBreak()
          }
        }
        self.writeBreak()
        self.isIndention = true
        breaks = true
      } else {
        if breaks {
          self.writeIndent()
          leadingSpaces = Scanner.isBlank(c)
        }
        if !breaks && c == " " && !leadingSpaces && i + 1 < scalars.count && scalars[i + 1] != " "
            && scalars[i + 1] != "\n" && scalars[i + 1] != "\t"
            && self.column > self.options.lineWidth && i > 0 && scalars[i - 1] != " " {
          self.writeIndent()
        } else {
          self.write(c)
        }
        self.isIndention = false
        breaks = false
      }
    }
    if !breaks {
      self.writeBreak()
    }
    self.isIndention = true
    self.isWhitespace = true
  }
}

extension String {

  /// Pads the string with leading zeros to the given length.
  func leftPadded(to length: Int) -> String {
    return self.count >= length ? self : String(repeating: "0", count: length - self.count) + self
  }
}
