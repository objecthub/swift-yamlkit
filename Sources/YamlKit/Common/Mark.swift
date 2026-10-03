//
//  Mark.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// A position within a YAML character stream.
///
/// Marks are attached to tokens, events, nodes, and errors so that problems
/// can be reported with a precise source location. Lines and columns are
/// 1-based; ``offset`` is the 0-based index of the Unicode scalar in the
/// (line-break normalized) input.
public struct Mark: Sendable, Hashable, Comparable, CustomStringConvertible {

  /// The 0-based offset of the Unicode scalar in the input.
  public var offset: Int

  /// The 1-based line number.
  public var line: Int

  /// The 1-based column number (counted in Unicode scalars).
  public var column: Int

  /// Creates a new mark.
  public init(offset: Int, line: Int, column: Int) {
    self.offset = offset
    self.line = line
    self.column = column
  }

  /// The mark denoting the start of a stream.
  public static let start = Mark(offset: 0, line: 1, column: 1)

  public static func < (lhs: Mark, rhs: Mark) -> Bool {
    return lhs.offset < rhs.offset
  }

  public var description: String {
    return "line \(self.line), column \(self.column)"
  }
}
