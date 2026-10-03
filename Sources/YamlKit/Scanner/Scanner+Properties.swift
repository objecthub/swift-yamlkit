//
//  Scanner+Properties.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

extension Scanner {

  // MARK: - Anchors and aliases (YAML 1.2.2, section 6.9.2 and 7.1)

  /// Scans an anchor (`&name`) or an alias (`*name`). Production [102]
  /// `ns-anchor-char` allows all non-space characters except flow
  /// indicators.
  mutating func scanAnchor(isAlias: Bool) throws -> Token {
    let start = self.mark
    self.advance()
    var name = String.UnicodeScalarView()
    while !Scanner.isBlankOrBreakOrEnd(self.peek()) && !Scanner.isFlowIndicator(self.peek()) {
      name.append(self.peek())
      self.advance()
    }
    guard !name.isEmpty else {
      throw self.error("\(isAlias ? "alias" : "anchor") name must not be empty", at: start)
    }
    let value = String(name)
    return Token(kind: isAlias ? .alias(value) : .anchor(value), start: start, end: self.mark)
  }

  // MARK: - Tags (YAML 1.2.2, section 6.9.1)

  /// Scans a tag property (production [97] `c-ns-tag-property`).
  mutating func scanTag() throws -> Token {
    let start = self.mark
    let handle: String?
    let suffix: String
    if self.peek(1) == "<" {
      // Production [98] `c-verbatim-tag`.
      self.advance(2)
      suffix = try self.scanTagURI(allowsAllURIChars: true, start: start)
      guard self.peek() == ">" else {
        throw self.error("expected '>' terminating verbatim tag", at: start)
      }
      guard !suffix.isEmpty else {
        throw self.error("verbatim tag must not be empty", at: start)
      }
      self.advance()
      handle = nil
    } else {
      // Production [99] `c-ns-shorthand-tag` or [100] `c-non-specific-tag`.
      let candidate = self.scanTagHandle()
      if candidate.count > 1 && candidate.hasSuffix("!") {
        handle = candidate
        suffix = try self.scanTagURI(allowsAllURIChars: false, start: start)
        guard !suffix.isEmpty else {
          throw self.error("tag suffix must not be empty", at: start)
        }
      } else {
        // The primary handle `!` followed by a (possibly empty) suffix.
        handle = "!"
        suffix = String(candidate.dropFirst())
          + (try self.scanTagURI(allowsAllURIChars: false, start: start))
      }
    }
    let c = self.peek()
    if !Scanner.isBlankOrBreakOrEnd(c) && !(self.flowLevel > 0 && Scanner.isFlowIndicator(c)) {
      throw self.error("tag must be followed by white space")
    }
    return Token(kind: .tag(handle: handle, suffix: suffix), start: start, end: self.mark)
  }

  /// Scans a tag handle: `!`, `!!`, or `!word!` (production [89]
  /// `c-tag-handle`). If no terminating `!` is found, the returned string is
  /// the leading `!` followed by word characters.
  mutating func scanTagHandle() -> String {
    var handle = String.UnicodeScalarView()
    handle.append("!")
    self.advance()
    var length = 0
    while Scanner.isWordChar(self.peek(length)) {
      length += 1
    }
    if self.peek(length) == "!" {
      for _ in 0...length {
        handle.append(self.peek())
        self.advance()
      }
    }
    return String(handle)
  }

  /// Scans a URI (production [39] `ns-uri-char`) or tag suffix (production
  /// [40] `ns-tag-char`). Percent-escapes are validated but kept as-is.
  mutating func scanTagURI(allowsAllURIChars: Bool, start: Mark) throws -> String {
    var uri = String.UnicodeScalarView()
    while true {
      let c = self.peek()
      if c == "%" {
        guard Scanner.isHexDigit(self.peek(1)) && Scanner.isHexDigit(self.peek(2)) else {
          throw self.error("invalid percent-escape in tag")
        }
        uri.append(c)
        uri.append(self.peek(1))
        uri.append(self.peek(2))
        self.advance(3)
      } else if allowsAllURIChars ? Scanner.isURIChar(c) : Scanner.isTagChar(c) {
        uri.append(c)
        self.advance()
      } else {
        return String(uri)
      }
    }
  }

  // MARK: - Directives (YAML 1.2.2, section 6.8)

  /// Scans a directive line (production [82] `l-directive`).
  mutating func scanDirective() throws -> Token {
    let start = self.mark
    self.advance()
    var name = String.UnicodeScalarView()
    while !Scanner.isBlankOrBreakOrEnd(self.peek()) {
      name.append(self.peek())
      self.advance()
    }
    guard !name.isEmpty else {
      throw self.error("directive name must not be empty", at: start)
    }
    let kind: Token.Kind
    switch String(name) {
      case "YAML":
        try self.skipDirectiveSeparator()
        let major = try self.scanVersionNumber()
        guard self.peek() == "." else {
          throw self.error("expected '.' in %YAML directive")
        }
        self.advance()
        let minor = try self.scanVersionNumber()
        kind = .versionDirective(YAMLVersion(major: major, minor: minor))
      case "TAG":
        try self.skipDirectiveSeparator()
        guard self.peek() == "!" else {
          throw self.error("expected tag handle in %TAG directive")
        }
        let handle = self.scanTagHandle()
        guard handle.count == 1 || handle.hasSuffix("!") else {
          throw self.error("invalid tag handle '\(handle)' in %TAG directive")
        }
        try self.skipDirectiveSeparator()
        // Production [93] `ns-tag-prefix`.
        let first = self.peek()
        guard first == "!" || (first != "%" && Scanner.isTagChar(first)) || first == "%" else {
          throw self.error("expected tag prefix in %TAG directive")
        }
        var prefix = ""
        if first == "!" {
          prefix = "!"
          self.advance()
        }
        prefix += try self.scanTagURI(allowsAllURIChars: true, start: start)
        kind = .tagDirective(TagDirective(handle: handle, prefix: prefix))
      default:
        // Reserved directive: skip its parameters.
        while !Scanner.isBreakOrEnd(self.peek()) {
          if self.peek() == "#" && Scanner.isBlank(self.input[self.index - 1]) {
            break
          }
          self.advance()
        }
        kind = .reservedDirective(String(name))
    }
    let end = self.mark
    // Production [79] `s-l-comments`.
    while Scanner.isBlank(self.peek()) {
      self.advance()
    }
    if self.peek() == "#" {
      guard Scanner.isBlank(self.input[self.index - 1]) else {
        throw self.error("comments must be separated from other tokens by white space")
      }
      while !Scanner.isBreakOrEnd(self.peek()) {
        self.advance()
      }
    }
    guard Scanner.isBreakOrEnd(self.peek()) else {
      throw self.error("unexpected content after directive")
    }
    return Token(kind: kind, start: start, end: end)
  }

  /// Skips the mandatory white space separating directive parameters.
  mutating func skipDirectiveSeparator() throws {
    guard Scanner.isBlank(self.peek()) else {
      throw self.error("expected white space in directive")
    }
    while Scanner.isBlank(self.peek()) {
      self.advance()
    }
  }

  /// Scans a version number component of a `%YAML` directive.
  mutating func scanVersionNumber() throws -> Int {
    var value = 0
    var length = 0
    while Scanner.isDigit(self.peek()) {
      length += 1
      guard length <= 9 else {
        throw self.error("version number is too long")
      }
      value = value * 10 + Int(self.peek().value - 0x30)
      self.advance()
    }
    guard length > 0 else {
      throw self.error("expected version number in %YAML directive")
    }
    return value
  }
}
