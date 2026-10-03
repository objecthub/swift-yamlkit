//
//  Scanner.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// The scanner splits a stream of Unicode scalars into ``Token`` values.
///
/// The design follows the classic libyaml architecture, adapted to the
/// YAML 1.2.2 specification:
///
/// - Indentation is tracked with a stack. Whenever a block collection starts
///   at a deeper indentation, a `blockSequenceStart` or `blockMappingStart`
///   token is generated ("rolling" the indentation); whenever a line starts
///   at a lower indentation, matching `blockEnd` tokens are generated
///   ("unrolling").
/// - Implicit keys (YAML 1.2.2, section 7.4.2 `ns-s-implicit-yaml-key` and
///   section 8.2.2 `ns-s-block-map-implicit-key`) can only be recognized
///   once the following `:` indicator is found. The scanner therefore
///   records *possible simple keys* and retroactively inserts a `key` token
///   (and, in block context, a `blockMappingStart` token) when the value
///   indicator is encountered.
///
/// The scanner is responsible for all lexical restrictions of the grammar
/// (indentation, tab usage, separation, comments, scalar folding and
/// escaping). The ``YAMLParser`` validates the structure of the token
/// stream.
struct Scanner {

  /// A potential implicit key.
  struct SimpleKey {
    /// Is the key still a candidate?
    var isPossible: Bool
    /// Must the key be followed by `:` (because it starts at the current
    /// block indentation)?
    var isRequired: Bool
    /// The ordinal number of the first token of the key.
    var tokenNumber: Int
    /// The position of the key.
    var mark: Mark

    static let none = SimpleKey(isPossible: false,
                                isRequired: false,
                                tokenNumber: 0,
                                mark: .start)
  }

  /// The maximum length of an implicit key (YAML 1.2.2, section 7.4.2).
  static let maxSimpleKeyLength = 1024

  // MARK: - Input

  /// The normalized input.
  let input: [Unicode.Scalar]

  /// The index of the current character.
  var index = 0

  /// The 0-based line of the current character.
  var line = 0

  /// The 0-based column of the current character.
  var column = 0

  // MARK: - Token queue

  /// The queue of scanned but not yet consumed tokens. Consumed tokens are
  /// found before `head`.
  var tokens: [Token] = []

  /// The index of the first unconsumed token in `tokens`.
  var head = 0

  /// The number of tokens that have been consumed so far.
  var tokensParsed = 0

  /// Has the `streamStart` token been produced?
  var streamStartProduced = false

  /// Has the `streamEnd` token been produced?
  var streamEndProduced = false

  // MARK: - Context

  /// The current block indentation level (-1 at the top level).
  var indent = -1

  /// The stack of enclosing block indentation levels.
  var indents: [Int] = []

  /// Is a simple key allowed at the current position?
  var simpleKeyAllowed = false

  /// Possible simple keys, one per flow level (plus one for block context).
  var simpleKeys: [SimpleKey] = [.none]

  /// The stack of open flow collections; `true` denotes a flow mapping.
  var flowCollections: [Bool] = []

  /// The line on which a value indicator of an implicit key or a document
  /// start marker was found. Block collections must not start on that line
  /// (`s-l+block-collection` requires a line break before the collection).
  var noBlockCollectionLine = -1

  /// Can a `:` immediately following the previous token act as a value
  /// indicator even if it is not followed by a space? This is the case after
  /// JSON-like nodes (quoted scalars and flow collections) in flow context
  /// (YAML 1.2.2, production [151] `c-ns-flow-pair-json-key-entry`).
  var adjacentValueAllowed = false

  /// The kind and line of the most recently queued token, used to detect
  /// properties that are followed by a block collection on the same line.
  var lastQueued: (kind: Token.Kind, line: Int)? = nil

  /// Creates a scanner for the given normalized input.
  init(_ input: [Unicode.Scalar]) {
    self.input = input
  }

  /// The current flow nesting level.
  var flowLevel: Int {
    return self.flowCollections.count
  }

  /// Is the scanner inside a flow mapping (as the innermost flow
  /// collection)?
  var inFlowMapping: Bool {
    return self.flowCollections.last ?? false
  }

  // MARK: - Public interface

  /// Returns the next token without consuming it.
  mutating func peekToken() throws -> Token {
    try self.fetchMoreTokens()
    return self.tokens[self.head]
  }

  /// Returns and consumes the next token.
  @discardableResult
  mutating func nextToken() throws -> Token {
    try self.fetchMoreTokens()
    let token = self.tokens[self.head]
    self.skipToken()
    return token
  }

  /// Consumes the token previously returned by `peekToken()`.
  mutating func skipToken() {
    self.head += 1
    self.tokensParsed += 1
    if self.head > 64 && self.head * 2 > self.tokens.count {
      self.tokens.removeFirst(self.head)
      self.head = 0
    }
  }

  // MARK: - Character access

  /// Returns the character at `offset` relative to the current position or
  /// `"\0"` beyond the end of the input. The reader guarantees that the
  /// input does not contain NUL characters.
  @inline(__always)
  func peek(_ offset: Int = 0) -> Unicode.Scalar {
    let i = self.index + offset
    return i < self.input.count ? self.input[i] : "\0"
  }

  /// The current position.
  var mark: Mark {
    return Mark(offset: self.index, line: self.line + 1, column: self.column + 1)
  }

  /// Advances to the next character.
  @inline(__always)
  mutating func advance() {
    guard self.index < self.input.count else {
      return
    }
    if self.input[self.index] == "\n" {
      self.line += 1
      self.column = 0
    } else {
      self.column += 1
    }
    self.index += 1
  }

  /// Advances `count` characters.
  @inline(__always)
  mutating func advance(_ count: Int) {
    for _ in 0..<count {
      self.advance()
    }
  }

  /// Returns a scanner error at the current position.
  func error(_ message: String, at mark: Mark? = nil) -> YAMLError {
    return YAMLError(.scanner, message, at: mark ?? self.mark)
  }

  /// Is the current position at a document marker (`---` or `...` at the
  /// beginning of a line followed by white space)? These markers are
  /// production [204] `c-forbidden` within content.
  var isAtDocumentIndicator: Bool {
    guard self.column == 0 else {
      return false
    }
    let c = self.peek()
    return (c == "-" || c == ".")
      && self.peek(1) == c
      && self.peek(2) == c
      && Scanner.isBlankOrBreakOrEnd(self.peek(3))
  }

  /// Returns information about the part of the current line preceding the
  /// current position: whether it consists of white space only, the number
  /// of leading spaces (before the first tab), and whether it contains a tab.
  func linePrefix(before position: Int? = nil) -> (isBlank: Bool, spaces: Int, hasTab: Bool) {
    var i = (position ?? self.index) - 1
    var spaces = 0
    var hasTab = false
    while i >= 0 && self.input[i] != "\n" {
      switch self.input[i] {
        case " ":
          spaces += 1
        case "\t":
          hasTab = true
          spaces = 0
        case "\u{FEFF}" where i == 0:
          break
        default:
          return (false, 0, false)
      }
      i -= 1
    }
    return (true, spaces, hasTab)
  }

  /// Does the white space immediately preceding `position` contain a tab?
  func whitespaceBeforeContainsTab(_ position: Int) -> Bool {
    var i = position - 1
    while i >= 0 {
      switch self.input[i] {
        case " ":
          i -= 1
        case "\t":
          return true
        default:
          return false
      }
    }
    return false
  }

  // MARK: - Character classes (YAML 1.2.2, chapter 5)

  /// Production [31] `s-space` and [32] `s-tab`, i.e. `s-white`.
  @inline(__always)
  static func isBlank(_ c: Unicode.Scalar) -> Bool {
    return c == " " || c == "\t"
  }

  /// Line breaks; the reader normalizes all breaks to `LF`.
  @inline(__always)
  static func isBreak(_ c: Unicode.Scalar) -> Bool {
    return c == "\n"
  }

  @inline(__always)
  static func isBreakOrEnd(_ c: Unicode.Scalar) -> Bool {
    return c == "\n" || c == "\0"
  }

  @inline(__always)
  static func isBlankOrBreakOrEnd(_ c: Unicode.Scalar) -> Bool {
    return c == " " || c == "\t" || c == "\n" || c == "\0"
  }

  /// Production [23] `c-flow-indicator`.
  @inline(__always)
  static func isFlowIndicator(_ c: Unicode.Scalar) -> Bool {
    return c == "," || c == "[" || c == "]" || c == "{" || c == "}"
  }

  /// Production [35] `ns-dec-digit`.
  @inline(__always)
  static func isDigit(_ c: Unicode.Scalar) -> Bool {
    return c >= "0" && c <= "9"
  }

  /// Production [36] `ns-hex-digit`.
  @inline(__always)
  static func isHexDigit(_ c: Unicode.Scalar) -> Bool {
    return (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
  }

  /// Production [37] `ns-ascii-letter`.
  @inline(__always)
  static func isLetter(_ c: Unicode.Scalar) -> Bool {
    return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
  }

  /// Production [38] `ns-word-char`.
  @inline(__always)
  static func isWordChar(_ c: Unicode.Scalar) -> Bool {
    return Scanner.isDigit(c) || Scanner.isLetter(c) || c == "-"
  }

  /// Production [39] `ns-uri-char` (without the `%` escape, which is handled
  /// separately).
  @inline(__always)
  static func isURIChar(_ c: Unicode.Scalar) -> Bool {
    if Scanner.isWordChar(c) {
      return true
    }
    switch c {
      case "#", ";", "/", "?", ":", "@", "&", "=", "+", "$", ",", "_", ".", "!",
           "~", "*", "'", "(", ")", "[", "]":
        return true
      default:
        return false
    }
  }

  /// Production [40] `ns-tag-char` (without the `%` escape).
  @inline(__always)
  static func isTagChar(_ c: Unicode.Scalar) -> Bool {
    return Scanner.isURIChar(c) && c != "!" && !Scanner.isFlowIndicator(c)
  }

  // MARK: - Token fetching

  /// Ensures that the token queue contains at least one token that can be
  /// handed out, i.e. a token that cannot be preceded by a retroactively
  /// inserted `key` token anymore.
  mutating func fetchMoreTokens() throws {
    while true {
      var needMore = false
      if self.head >= self.tokens.count {
        needMore = true
      } else {
        try self.staleSimpleKeys()
        for key in self.simpleKeys where key.isPossible && key.tokenNumber == self.tokensParsed {
          needMore = true
          break
        }
      }
      guard needMore else {
        return
      }
      try self.fetchNextToken()
    }
  }

  /// Appends a token to the queue.
  mutating func enqueue(_ kind: Token.Kind, start: Mark, end: Mark) {
    self.tokens.append(Token(kind: kind, start: start, end: end))
    self.lastQueued = (kind, start.line)
  }

  /// Scans the next token and appends it to the queue.
  mutating func fetchNextToken() throws {
    guard self.streamStartProduced else {
      return self.fetchStreamStart()
    }
    guard !self.streamEndProduced else {
      throw self.error("unexpected end of stream")
    }
    try self.scanToNextToken()
    try self.staleSimpleKeys()
    try self.checkIndentation()
    self.unrollIndent(self.column)
    let c = self.peek()
    if c == "\0" {
      return try self.fetchStreamEnd()
    }
    if self.column == 0 && c == "%" {
      return try self.fetchDirective()
    }
    if self.isAtDocumentIndicator {
      return try self.fetchDocumentIndicator(isStart: c == "-")
    }
    switch c {
      case "[":
        return try self.fetchFlowCollectionStart(isMapping: false)
      case "{":
        return try self.fetchFlowCollectionStart(isMapping: true)
      case "]":
        return try self.fetchFlowCollectionEnd(isMapping: false)
      case "}":
        return try self.fetchFlowCollectionEnd(isMapping: true)
      case ",":
        return try self.fetchFlowEntry()
      case "-" where Scanner.isBlankOrBreakOrEnd(self.peek(1)):
        return try self.fetchBlockEntry()
      case "?" where Scanner.isBlankOrBreakOrEnd(self.peek(1)):
        return try self.fetchKey()
      case ":" where self.isValueIndicator:
        return try self.fetchValue()
      case "*":
        return try self.fetchAnchor(isAlias: true)
      case "&":
        return try self.fetchAnchor(isAlias: false)
      case "!":
        return try self.fetchTag()
      case "|" where self.flowLevel == 0:
        return try self.fetchBlockScalar(isLiteral: true)
      case ">" where self.flowLevel == 0:
        return try self.fetchBlockScalar(isLiteral: false)
      case "'":
        return try self.fetchFlowScalar(isDoubleQuoted: false)
      case "\"":
        return try self.fetchFlowScalar(isDoubleQuoted: true)
      default:
        break
    }
    if self.isPlainScalarStart {
      return try self.fetchPlainScalar()
    }
    throw self.error("found character '\(c.escapedDescription)' that cannot start any token")
  }

  /// Is the `:` at the current position a value indicator
  /// (production [151] `c-ns-flow-map-separate-value` and friends)?
  var isValueIndicator: Bool {
    let next = self.peek(1)
    if Scanner.isBlankOrBreakOrEnd(next) {
      return true
    }
    if self.flowLevel > 0 {
      return Scanner.isFlowIndicator(next) || self.adjacentValueAllowed
    }
    return false
  }

  /// Can a plain scalar start at the current position (production [126]
  /// `ns-plain-first(c)`)?
  var isPlainScalarStart: Bool {
    let c = self.peek()
    switch c {
      case "-", "?", ":":
        let next = self.peek(1)
        return !Scanner.isBlankOrBreakOrEnd(next)
          && !(self.flowLevel > 0 && Scanner.isFlowIndicator(next))
      case ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`":
        return false
      default:
        return !Scanner.isBlankOrBreakOrEnd(c)
    }
  }

  /// Skips white space, comments and line breaks preceding the next token.
  mutating func scanToNextToken() throws {
    while true {
      if self.index == 0 && self.peek() == "\u{FEFF}" {
        self.advance()
      }
      while Scanner.isBlank(self.peek()) {
        self.advance()
      }
      if self.peek() == "#" {
        // Comments must be separated from other tokens by white space
        // (production [75] `c-nb-comment-text` is always preceded by
        // `s-separate-in-line` unless it starts a line).
        if self.index > 0 && !Scanner.isBlankOrBreakOrEnd(self.input[self.index - 1]) {
          throw self.error("comments must be separated from other tokens by white space")
        }
        while !Scanner.isBreakOrEnd(self.peek()) {
          self.advance()
        }
      }
      guard Scanner.isBreak(self.peek()) else {
        return
      }
      self.advance()
      if self.flowLevel == 0 {
        self.simpleKeyAllowed = true
      }
    }
  }

  /// Validates the indentation of a token starting a line.
  ///
  /// - In block context, tabs must not be used for indentation
  ///   (YAML 1.2.2, section 6.1): a token that starts a line whose leading
  ///   white space contains a tab must be indented by more spaces than the
  ///   current block indentation.
  /// - In flow context, continuation lines must be indented by more spaces
  ///   than the surrounding block collection (production [69]
  ///   `s-flow-line-prefix(n)`).
  mutating func checkIndentation() throws {
    guard self.peek() != "\0" else {
      return
    }
    let prefix = self.linePrefix()
    guard prefix.isBlank else {
      return
    }
    if self.flowLevel > 0 {
      if self.indent >= 0 && prefix.spaces <= self.indent && !self.isAtDocumentIndicator {
        throw self.error("insufficient indentation of flow content")
      }
    } else if prefix.hasTab && prefix.spaces <= self.indent {
      throw self.error("tabs must not be used for indentation")
    }
  }

  // MARK: - Simple keys

  /// Invalidates simple keys that can no longer be followed by `:`.
  /// Implicit keys are restricted to a single line and 1024 characters
  /// except for keys of flow mappings, which may span multiple lines.
  mutating func staleSimpleKeys() throws {
    let inFlowMapping = self.inFlowMapping
    for i in self.simpleKeys.indices where self.simpleKeys[i].isPossible {
      let key = self.simpleKeys[i]
      let isLast = i == self.simpleKeys.count - 1
      if isLast && inFlowMapping {
        continue
      }
      if key.mark.line < self.line + 1
          || self.index - key.mark.offset > Scanner.maxSimpleKeyLength {
        if key.isRequired {
          throw self.error("could not find expected ':' for implicit key", at: key.mark)
        }
        self.simpleKeys[i].isPossible = false
      }
    }
  }

  /// Records the current position as a possible simple key.
  mutating func saveSimpleKey() throws {
    let isRequired = self.flowLevel == 0 && self.indent == self.column
    guard self.simpleKeyAllowed else {
      return
    }
    try self.removeSimpleKey()
    self.simpleKeys[self.simpleKeys.count - 1] = SimpleKey(
      isPossible: true,
      isRequired: isRequired,
      tokenNumber: self.tokensParsed + (self.tokens.count - self.head),
      mark: self.mark)
  }

  /// Removes the possible simple key of the current flow level.
  mutating func removeSimpleKey() throws {
    let key = self.simpleKeys[self.simpleKeys.count - 1]
    if key.isPossible && key.isRequired {
      throw self.error("could not find expected ':' for implicit key", at: key.mark)
    }
    self.simpleKeys[self.simpleKeys.count - 1].isPossible = false
  }

  // MARK: - Indentation

  /// Pushes a new block indentation level if `column` is deeper than the
  /// current level, inserting a collection start token either at the end of
  /// the queue or before the token with ordinal `number`.
  mutating func rollIndent(_ column: Int,
                           number: Int?,
                           kind: Token.Kind,
                           mark: Mark) throws {
    guard self.flowLevel == 0, self.indent < column else {
      return
    }
    // A block collection must start on a new line, except in the compact
    // forms nested in block sequence entries and explicit keys/values.
    if mark.line - 1 == self.noBlockCollectionLine {
      throw self.error("block collection must not start on the same line as its key or the document start marker",
                       at: mark)
    }
    // Compact collections must be separated from their parent indicator by
    // spaces only (`s-indent` in production [185] `s-l+block-indented`).
    if self.whitespaceBeforeContainsTab(mark.offset) {
      throw self.error("tabs must not be used for indentation", at: mark)
    }
    self.indents.append(self.indent)
    self.indent = column
    let token = Token(kind: kind, start: mark, end: mark)
    if let number {
      self.tokens.insert(token, at: self.head + (number - self.tokensParsed))
    } else {
      self.tokens.append(token)
    }
  }

  /// Pops block indentation levels deeper than `column`, generating
  /// `blockEnd` tokens.
  mutating func unrollIndent(_ column: Int) {
    guard self.flowLevel == 0 else {
      return
    }
    while self.indent > column {
      self.enqueue(.blockEnd, start: self.mark, end: self.mark)
      self.indent = self.indents.removeLast()
    }
  }

  // MARK: - Fetching individual tokens

  mutating func fetchStreamStart() {
    self.streamStartProduced = true
    self.simpleKeyAllowed = true
    self.enqueue(.streamStart, start: self.mark, end: self.mark)
  }

  mutating func fetchStreamEnd() throws {
    // Force a new line.
    if self.column != 0 {
      self.column = 0
      self.line += 1
    }
    if self.flowLevel > 0 {
      throw self.error("unterminated flow collection")
    }
    self.unrollIndent(-1)
    try self.removeSimpleKey()
    self.simpleKeyAllowed = false
    self.streamEndProduced = true
    self.enqueue(.streamEnd, start: self.mark, end: self.mark)
  }

  mutating func fetchDirective() throws {
    self.unrollIndent(-1)
    try self.removeSimpleKey()
    self.simpleKeyAllowed = false
    let token = try self.scanDirective()
    self.enqueue(token.kind, start: token.start, end: token.end)
  }

  mutating func fetchDocumentIndicator(isStart: Bool) throws {
    self.unrollIndent(-1)
    try self.removeSimpleKey()
    self.simpleKeyAllowed = false
    self.adjacentValueAllowed = false
    let start = self.mark
    self.advance(3)
    let end = self.mark
    if isStart {
      self.noBlockCollectionLine = self.line
    } else {
      // Production [203] `l-document-suffix`: only comments may follow.
      while Scanner.isBlank(self.peek()) {
        self.advance()
      }
      if !Scanner.isBreakOrEnd(self.peek()) && self.peek() != "#" {
        throw self.error("unexpected content after document end marker")
      }
    }
    self.enqueue(isStart ? .documentStart : .documentEnd, start: start, end: end)
  }

  mutating func fetchFlowCollectionStart(isMapping: Bool) throws {
    try self.saveSimpleKey()
    self.flowCollections.append(isMapping)
    self.simpleKeys.append(.none)
    self.simpleKeyAllowed = true
    self.adjacentValueAllowed = false
    let start = self.mark
    self.advance()
    self.enqueue(isMapping ? .flowMappingStart : .flowSequenceStart, start: start, end: self.mark)
  }

  mutating func fetchFlowCollectionEnd(isMapping: Bool) throws {
    try self.removeSimpleKey()
    if !self.flowCollections.isEmpty {
      self.flowCollections.removeLast()
      self.simpleKeys.removeLast()
    }
    self.simpleKeyAllowed = false
    self.adjacentValueAllowed = true
    let start = self.mark
    self.advance()
    self.enqueue(isMapping ? .flowMappingEnd : .flowSequenceEnd, start: start, end: self.mark)
    try self.checkTokenSeparation()
  }

  mutating func fetchFlowEntry() throws {
    try self.removeSimpleKey()
    self.simpleKeyAllowed = true
    self.adjacentValueAllowed = false
    let start = self.mark
    self.advance()
    self.enqueue(.flowEntry, start: start, end: self.mark)
  }

  mutating func fetchBlockEntry() throws {
    if self.flowLevel == 0 {
      guard self.simpleKeyAllowed else {
        throw self.error("block sequence entries are not allowed in this context")
      }
      if let last = self.lastQueued, last.line == self.line + 1 {
        switch last.kind {
          case .anchor, .tag:
            throw self.error("a block sequence must not start on the same line as its properties")
          default:
            break
        }
      }
      try self.rollIndent(self.column, number: nil, kind: .blockSequenceStart, mark: self.mark)
    }
    // In flow context, the parser reports the misplaced indicator.
    try self.removeSimpleKey()
    self.simpleKeyAllowed = true
    self.adjacentValueAllowed = false
    let start = self.mark
    self.advance()
    self.enqueue(.blockEntry, start: start, end: self.mark)
  }

  mutating func fetchKey() throws {
    if self.flowLevel == 0 {
      guard self.simpleKeyAllowed else {
        throw self.error("mapping keys are not allowed in this context")
      }
      try self.rollIndent(self.column, number: nil, kind: .blockMappingStart, mark: self.mark)
    }
    try self.removeSimpleKey()
    self.simpleKeyAllowed = self.flowLevel == 0
    self.adjacentValueAllowed = false
    let start = self.mark
    self.advance()
    self.enqueue(.key, start: start, end: self.mark)
  }

  mutating func fetchValue() throws {
    let key = self.simpleKeys[self.simpleKeys.count - 1]
    if key.isPossible {
      // Insert the `key` token in front of the simple key.
      let token = Token(kind: .key, start: key.mark, end: key.mark)
      self.tokens.insert(token, at: self.head + (key.tokenNumber - self.tokensParsed))
      try self.rollIndent(key.mark.column - 1,
                          number: key.tokenNumber,
                          kind: .blockMappingStart,
                          mark: key.mark)
      self.simpleKeys[self.simpleKeys.count - 1].isPossible = false
      // The value of an implicit key cannot be a block collection starting
      // on the same line, hence no further simple keys are allowed.
      self.simpleKeyAllowed = false
      if self.flowLevel == 0 {
        self.noBlockCollectionLine = self.line
      }
    } else {
      if self.flowLevel == 0 {
        guard self.simpleKeyAllowed else {
          throw self.error("mapping values are not allowed in this context")
        }
        try self.rollIndent(self.column, number: nil, kind: .blockMappingStart, mark: self.mark)
      }
      // An explicit value may be a compact block collection.
      self.simpleKeyAllowed = self.flowLevel == 0
    }
    self.adjacentValueAllowed = false
    let start = self.mark
    self.advance()
    self.enqueue(.value, start: start, end: self.mark)
  }

  mutating func fetchAnchor(isAlias: Bool) throws {
    try self.saveSimpleKey()
    self.simpleKeyAllowed = false
    self.adjacentValueAllowed = false
    let token = try self.scanAnchor(isAlias: isAlias)
    self.enqueue(token.kind, start: token.start, end: token.end)
  }

  mutating func fetchTag() throws {
    try self.saveSimpleKey()
    self.simpleKeyAllowed = false
    self.adjacentValueAllowed = false
    let token = try self.scanTag()
    self.enqueue(token.kind, start: token.start, end: token.end)
  }

  mutating func fetchBlockScalar(isLiteral: Bool) throws {
    try self.removeSimpleKey()
    self.simpleKeyAllowed = true
    self.adjacentValueAllowed = false
    let token = try self.scanBlockScalar(isLiteral: isLiteral)
    self.enqueue(token.kind, start: token.start, end: token.end)
  }

  mutating func fetchFlowScalar(isDoubleQuoted: Bool) throws {
    try self.saveSimpleKey()
    self.simpleKeyAllowed = false
    let token = try self.scanFlowScalar(isDoubleQuoted: isDoubleQuoted)
    self.adjacentValueAllowed = true
    self.enqueue(token.kind, start: token.start, end: token.end)
    try self.checkTokenSeparation()
  }

  mutating func fetchPlainScalar() throws {
    try self.saveSimpleKey()
    self.simpleKeyAllowed = false
    self.adjacentValueAllowed = false
    let token = try self.scanPlainScalar()
    self.enqueue(token.kind, start: token.start, end: token.end)
  }

  /// Verifies that a quoted scalar or flow collection end is not directly
  /// followed by a character that would require separation.
  mutating func checkTokenSeparation() throws {
    let c = self.peek()
    if Scanner.isBlankOrBreakOrEnd(c) || Scanner.isFlowIndicator(c) || c == ":" || c == "#" {
      if c == "#" {
        throw self.error("comments must be separated from other tokens by white space")
      }
      return
    }
    if self.flowLevel == 0 {
      throw self.error("unexpected character '\(c.escapedDescription)' following a flow node")
    }
  }
}

extension Unicode.Scalar {

  /// A printable representation of the scalar for error messages.
  var escapedDescription: String {
    switch self {
      case "\n":
        return "\\n"
      case "\t":
        return "\\t"
      case "\0":
        return "\\0"
      default:
        if self.value < 0x20 || self.value == 0x7F {
          return "\\u{\(String(self.value, radix: 16))}"
        }
        return String(self)
    }
  }
}
