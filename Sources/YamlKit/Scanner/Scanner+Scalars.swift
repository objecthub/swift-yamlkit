//
//  Scanner+Scalars.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

extension Scanner {

  // MARK: - Plain scalars (YAML 1.2.2, section 7.3.3)

  /// Scans a plain scalar, folding line breaks according to production
  /// [73] `s-flow-folded(n)`.
  mutating func scanPlainScalar() throws -> Token {
    let start = self.mark
    var end = self.mark
    var string = String.UnicodeScalarView()
    var whitespaces = String.UnicodeScalarView()
    var trailingBreaks = 0
    var leadingBlanks = false
    let indent = self.indent + 1
    while true {
      // Document markers and comments terminate the scalar.
      if self.isAtDocumentIndicator || self.peek() == "#" {
        break
      }
      // Consume non-blank characters (production [130] `ns-plain-char(c)`).
      var consumed = false
      while !Scanner.isBlankOrBreakOrEnd(self.peek()) {
        let c = self.peek()
        if c == ":" {
          let next = self.peek(1)
          if Scanner.isBlankOrBreakOrEnd(next)
              || (self.flowLevel > 0 && Scanner.isFlowIndicator(next)) {
            break
          }
        } else if self.flowLevel > 0 && Scanner.isFlowIndicator(c) {
          break
        }
        if leadingBlanks {
          // Fold the line break(s) preceding the current line.
          if trailingBreaks == 0 {
            string.append(" ")
          } else {
            for _ in 0..<trailingBreaks {
              string.append("\n")
            }
          }
          trailingBreaks = 0
          leadingBlanks = false
        } else if !whitespaces.isEmpty {
          string.append(contentsOf: whitespaces)
          whitespaces.removeAll()
        }
        string.append(c)
        self.advance()
        end = self.mark
        consumed = true
      }
      if !consumed && !leadingBlanks && string.isEmpty {
        break
      }
      // Is the scalar continued?
      guard Scanner.isBlank(self.peek()) || Scanner.isBreak(self.peek()) else {
        break
      }
      // Consume white space and line breaks.
      var lineSpaces = 0
      var countingSpaces = false
      while Scanner.isBlank(self.peek()) || Scanner.isBreak(self.peek()) {
        let c = self.peek()
        if Scanner.isBlank(c) {
          if leadingBlanks {
            if c == " " && countingSpaces {
              lineSpaces += 1
            } else {
              countingSpaces = false
            }
          } else {
            whitespaces.append(c)
          }
        } else {
          if leadingBlanks {
            trailingBreaks += 1
          } else {
            whitespaces.removeAll()
            leadingBlanks = true
          }
          lineSpaces = 0
          countingSpaces = true
        }
        self.advance()
      }
      // A continuation line must be indented more than the parent block
      // collection (production [69] `s-flow-line-prefix(n)`, which only
      // allows spaces for indentation).
      if leadingBlanks && lineSpaces < indent && self.peek() != "\0" && self.peek() != "#" {
        if self.flowLevel > 0 && self.indent >= 0 && !self.isAtDocumentIndicator {
          throw self.error("insufficient indentation of flow scalar continuation line")
        }
        break
      }
      if self.flowLevel == 0 && self.column < indent {
        break
      }
    }
    if leadingBlanks {
      self.simpleKeyAllowed = true
    }
    return Token(kind: .scalar(String(string), .plain), start: start, end: end)
  }

  // MARK: - Quoted scalars (YAML 1.2.2, sections 7.3.1 and 7.3.2)

  /// Scans a single-quoted or double-quoted scalar.
  mutating func scanFlowScalar(isDoubleQuoted: Bool) throws -> Token {
    let start = self.mark
    let quote: Unicode.Scalar = isDoubleQuoted ? "\"" : "'"
    self.advance()
    var string = String.UnicodeScalarView()
    var whitespaces = String.UnicodeScalarView()
    var trailingBreaks = 0
    var hasLeadingBreak = false
    while true {
      if self.isAtDocumentIndicator {
        throw self.error("unexpected document marker within quoted scalar")
      }
      if self.peek() == "\0" {
        throw self.error("unexpected end of stream within quoted scalar", at: start)
      }
      // Consume non-blank characters.
      var leadingBlanks = false
      while !Scanner.isBlankOrBreakOrEnd(self.peek()) {
        let c = self.peek()
        if !isDoubleQuoted && c == "'" && self.peek(1) == "'" {
          // Production [118] `c-quoted-quote`.
          string.append("'")
          self.advance(2)
        } else if c == quote {
          break
        } else if isDoubleQuoted && c == "\\" && Scanner.isBreak(self.peek(1)) {
          // Production [112] `s-double-escaped(n)`: an escaped line break.
          self.advance(2)
          leadingBlanks = true
          hasLeadingBreak = false
          break
        } else if isDoubleQuoted && c == "\\" {
          try self.scanEscapeSequence(into: &string)
        } else {
          string.append(c)
          self.advance()
        }
      }
      if self.peek() == quote {
        break
      }
      // Consume white space and line breaks.
      while Scanner.isBlank(self.peek()) || Scanner.isBreak(self.peek()) {
        let c = self.peek()
        if Scanner.isBlank(c) {
          if !leadingBlanks {
            whitespaces.append(c)
          }
        } else {
          if leadingBlanks {
            trailingBreaks += 1
          } else {
            whitespaces.removeAll()
            hasLeadingBreak = true
            leadingBlanks = true
          }
        }
        self.advance()
      }
      // Continuation lines must be indented (production [69]
      // `s-flow-line-prefix(n)`).
      if leadingBlanks && self.peek() != "\0" && !self.isAtDocumentIndicator {
        let prefix = self.linePrefix()
        if prefix.isBlank && prefix.spaces <= self.indent {
          throw self.error("insufficient indentation of quoted scalar continuation line")
        }
      }
      // Join the lines.
      if leadingBlanks {
        if hasLeadingBreak && trailingBreaks == 0 {
          string.append(" ")
        } else {
          for _ in 0..<trailingBreaks {
            string.append("\n")
          }
        }
        trailingBreaks = 0
        hasLeadingBreak = false
      } else {
        string.append(contentsOf: whitespaces)
        whitespaces.removeAll()
      }
    }
    self.advance()
    return Token(kind: .scalar(String(string), isDoubleQuoted ? .doubleQuoted : .singleQuoted),
                 start: start,
                 end: self.mark)
  }

  /// Scans an escape sequence (production [62] `c-ns-esc-char`) of a
  /// double-quoted scalar.
  mutating func scanEscapeSequence(into string: inout String.UnicodeScalarView) throws {
    let start = self.mark
    self.advance()
    let c = self.peek()
    var length = 0
    switch c {
      case "0": string.append("\0")
      case "a": string.append("\u{07}")
      case "b": string.append("\u{08}")
      case "t", "\t": string.append("\t")
      case "n": string.append("\n")
      case "v": string.append("\u{0B}")
      case "f": string.append("\u{0C}")
      case "r": string.append("\r")
      case "e": string.append("\u{1B}")
      case " ": string.append(" ")
      case "\"": string.append("\"")
      case "/": string.append("/")
      case "\\": string.append("\\")
      case "N": string.append("\u{85}")
      case "_": string.append("\u{A0}")
      case "L": string.append("\u{2028}")
      case "P": string.append("\u{2029}")
      case "x": length = 2
      case "u": length = 4
      case "U": length = 8
      default:
        throw self.error("found unknown escape character '\(c.escapedDescription)'", at: start)
    }
    self.advance()
    guard length > 0 else {
      return
    }
    var value: UInt32 = 0
    for _ in 0..<length {
      let digit = self.peek()
      guard Scanner.isHexDigit(digit), let v = UInt32(String(digit), radix: 16) else {
        throw self.error("expected \(length) hexadecimal digits in escape sequence", at: start)
      }
      value = value * 16 + v
      self.advance()
    }
    guard let scalar = Unicode.Scalar(value) else {
      throw self.error("invalid Unicode character in escape sequence", at: start)
    }
    string.append(scalar)
  }

  // MARK: - Block scalars (YAML 1.2.2, section 8.1)

  /// The chomping indicator of a block scalar (section 8.1.1.2).
  enum Chomping {
    case strip
    case clip
    case keep
  }

  /// Scans a literal or folded block scalar.
  mutating func scanBlockScalar(isLiteral: Bool) throws -> Token {
    let start = self.mark
    self.advance()
    // Production [162] `c-b-block-header(t)`.
    var chomping = Chomping.clip
    var increment = 0
    func scanChomping(_ scanner: inout Scanner) -> Bool {
      switch scanner.peek() {
        case "+":
          chomping = .keep
        case "-":
          chomping = .strip
        default:
          return false
      }
      scanner.advance()
      return true
    }
    func scanIncrement(_ scanner: inout Scanner) throws -> Bool {
      let c = scanner.peek()
      guard Scanner.isDigit(c) else {
        return false
      }
      guard c != "0" else {
        throw scanner.error("indentation indicator must be between 1 and 9")
      }
      increment = Int(c.value - 0x30)
      scanner.advance()
      return true
    }
    if scanChomping(&self) {
      _ = try scanIncrement(&self)
    } else if try scanIncrement(&self) {
      _ = scanChomping(&self)
    }
    // Comment and line break following the header.
    if !Scanner.isBlankOrBreakOrEnd(self.peek()) {
      throw self.error("expected chomping or indentation indicator in block scalar header")
    }
    while Scanner.isBlank(self.peek()) {
      self.advance()
    }
    if self.peek() == "#" {
      if !Scanner.isBlank(self.input[self.index - 1]) {
        throw self.error("comments must be separated from other tokens by white space")
      }
      while !Scanner.isBreakOrEnd(self.peek()) {
        self.advance()
      }
    }
    guard Scanner.isBreakOrEnd(self.peek()) else {
      throw self.error("unexpected content after block scalar header")
    }
    self.advance()
    var end = self.mark
    // Determine the content indentation (section 8.1.1.1).
    let parentIndent = self.indent
    let minIndent = max(parentIndent + 1, 0)
    var contentIndent: Int
    if increment > 0 {
      contentIndent = parentIndent + increment
      if contentIndent < 0 {
        contentIndent = increment - 1
      }
    } else {
      contentIndent = try self.detectBlockScalarIndentation(minimum: minIndent)
    }
    var string = String.UnicodeScalarView()
    var trailingBreaks = 0
    var hasLeadingBreak = false
    var leadingBlank = false
    var isFirstLine = true
    // Production [170] `l-literal-content(n,t)` / [182] `l-folded-content(n,t)`.
    while true {
      // Consume the indentation of the line.
      let lineStart = self.index
      while self.column < contentIndent && self.peek() == " " {
        self.advance()
      }
      let c = self.peek()
      if c == "\0" && self.index > lineStart {
        // A final line consisting of white space only is treated like an
        // empty line, even if it is not terminated by a line break.
        trailingBreaks += 1
        break
      }
      if Scanner.isBreak(c) {
        // An empty line (production [70] `l-empty(n,c)`).
        trailingBreaks += 1
        self.advance()
        end = self.mark
        continue
      }
      if c == "\0" || self.column < contentIndent || self.isAtDocumentIndicator {
        if c == "\t" && self.column < contentIndent {
          // A tab in the indentation of a line that is not a comment line.
          var i = self.index
          while i < self.input.count && Scanner.isBlank(self.input[i]) {
            i += 1
          }
          if i >= self.input.count || self.input[i] != "#" {
            throw self.error("tabs must not be used for indentation of block scalars")
          }
        }
        break
      }
      // A content line.
      let trailingBlank = Scanner.isBlank(c)
      if !isFirstLine {
        if !isLiteral && hasLeadingBreak && !leadingBlank && !trailingBlank {
          // Production [176] `b-l-folded`: a single line break between two
          // non-indented lines is folded into a space.
          if trailingBreaks == 0 {
            string.append(" ")
          }
        } else {
          string.append("\n")
        }
      }
      for _ in 0..<trailingBreaks {
        string.append("\n")
      }
      trailingBreaks = 0
      isFirstLine = false
      leadingBlank = trailingBlank
      var isWhitespaceOnly = true
      while !Scanner.isBreakOrEnd(self.peek()) {
        isWhitespaceOnly = isWhitespaceOnly && Scanner.isBlank(self.peek())
        string.append(self.peek())
        self.advance()
      }
      end = self.mark
      if self.peek() == "\0" {
        // The final line is only terminated by a line break implicitly if
        // it consists of white space only.
        hasLeadingBreak = isWhitespaceOnly
        break
      }
      self.advance()
      end = self.mark
      hasLeadingBreak = true
    }
    // Chomping (production [165] `b-chomped-last(t)` and [166]
    // `l-chomped-empty(n,t)`).
    switch chomping {
      case .strip:
        break
      case .clip:
        if hasLeadingBreak {
          string.append("\n")
        }
      case .keep:
        if hasLeadingBreak {
          string.append("\n")
        }
        for _ in 0..<trailingBreaks {
          string.append("\n")
        }
    }
    return Token(kind: .scalar(String(string), isLiteral ? .literal : .folded),
                 start: start,
                 end: end)
  }

  /// Determines the content indentation of a block scalar without an
  /// explicit indentation indicator. The indentation is the number of leading
  /// spaces of the first non-empty line; it is an error if a leading empty
  /// line contains more spaces than that.
  func detectBlockScalarIndentation(minimum: Int) throws -> Int {
    var i = self.index
    var line = self.line
    var maxEmpty = 0
    var maxEmptyLine = line
    while true {
      var spaces = 0
      while i < self.input.count && self.input[i] == " " {
        spaces += 1
        i += 1
      }
      if i >= self.input.count {
        // Only empty lines: the longest line determines the indentation.
        return max(minimum, maxEmpty, spaces)
      }
      if self.input[i] == "\n" {
        if spaces > maxEmpty {
          maxEmpty = spaces
          maxEmptyLine = line
        }
        i += 1
        line += 1
        continue
      }
      // The first non-empty line.
      if spaces < minimum {
        // The scalar has no content; trailing empty lines belong to it.
        return minimum
      }
      if maxEmpty > spaces {
        throw YAMLError(.scanner,
                        "leading empty line of block scalar contains more spaces than the first content line",
                        at: Mark(offset: i, line: maxEmptyLine + 1, column: maxEmpty + 1))
      }
      return spaces
    }
  }
}
