//
//  YAMLError.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import Foundation

/// An error raised while reading, parsing, composing, or emitting YAML.
///
/// Every error carries a ``Kind`` identifying the processing stage that
/// failed, a human-readable message, and — where available — the source
/// location of the problem.
public struct YAMLError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {

  /// The processing stage in which an error occurred.
  public enum Kind: String, Sendable, Hashable {
    /// The input could not be decoded into Unicode characters or contains
    /// characters that are not permitted in a YAML stream.
    case reader
    /// The input could not be split into tokens.
    case scanner
    /// The token stream does not conform to the YAML grammar.
    case parser
    /// The event stream could not be composed into a node graph (e.g. an
    /// undefined alias or a duplicate mapping key).
    case composer
    /// The event or node stream could not be serialized to YAML text.
    case emitter
    /// A configured resource limit was exceeded.
    case limitExceeded
  }

  /// The processing stage that failed.
  public let kind: Kind

  /// A description of the problem.
  public let message: String

  /// The location of the problem, if known.
  public let mark: Mark?

  /// Creates a new error.
  public init(_ kind: Kind, _ message: String, at mark: Mark? = nil) {
    self.kind = kind
    self.message = message
    self.mark = mark
  }

  public var description: String {
    if let mark = self.mark {
      return "\(self.kind.rawValue) error at \(mark): \(self.message)"
    } else {
      return "\(self.kind.rawValue) error: \(self.message)"
    }
  }

  public var errorDescription: String? {
    return self.description
  }
}
