//
//  YAMLNode.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// A node of a YAML representation graph (YAML 1.2.2, section 3.2.1).
///
/// A node is either a scalar, a sequence, or a mapping. Every node has a
/// resolved ``YAMLTag``; untagged nodes are resolved when composed by
/// `YAML.parse(_:options:)` using the configured ``YAMLSchema``.
///
/// Aliases are resolved during composition: an alias node is replaced by a
/// copy of the anchored node. Since nodes are value types, copies share their
/// storage. The anchor name is retained in the node so that
/// ``YAML/serialize(_:options:)`` can turn repeated occurrences back into
/// aliases.
///
/// Equality of nodes is defined on their content as specified in section
/// 3.2.1.3: scalars are equal if their tags and canonical values (see
/// ``Scalar/canonicalValue``) are equal; sequences
/// if their tags and elements are equal; mappings if their tags are equal and
/// they contain the same key/value pairs, irrespective of order. Presentation
/// details such as styles, anchors, and source locations are ignored.
public enum YAMLNode: Sendable, Hashable {

  /// A scalar node.
  case scalar(Scalar)

  /// A sequence node.
  case sequence(Sequence)

  /// A mapping node.
  case mapping(Mapping)

  // MARK: - Scalars

  /// The content of a scalar node.
  public struct Scalar: Sendable, Hashable, CustomStringConvertible {

    /// The textual content of the scalar.
    public var value: String

    /// The resolved tag of the scalar.
    public var tag: YAMLTag

    /// The presentation style, or `nil` to let the serializer choose.
    public var style: ScalarStyle?

    /// The anchor of the node, if any.
    public var anchor: String?

    /// The source location of the node, if it was parsed.
    public var mark: Mark?

    /// Creates a scalar.
    public init(_ value: String,
                tag: YAMLTag = .str,
                style: ScalarStyle? = nil,
                anchor: String? = nil,
                mark: Mark? = nil) {
      self.value = value
      self.tag = tag
      self.style = style
      self.anchor = anchor
      self.mark = mark
    }

    /// The canonical form of the value, which is used to compare scalars
    /// (YAML 1.2.2, section 3.2.1.3). For the types of the core schema,
    /// different notations of the same value are equal, e.g. `~` and `null`,
    /// or `0x1F` and `31`. Other values are compared literally.
    public var canonicalValue: String {
      switch self.tag {
        case .null:
          return "null"
        case .bool:
          if let bool = CoreSchema.parseBool(self.value) {
            return bool ? "true" : "false"
          }
        case .int:
          if let int = CoreSchema.parseInteger(self.value, as: Int64.self) {
            return String(int)
          } else if let (isNegative, digits, radix) = CoreSchema.integerComponents(self.value), radix == 10 {
            let trimmed = digits.drop(while: { $0 == "0" })
            return (isNegative && !trimmed.isEmpty ? "-" : "") + (trimmed.isEmpty ? "0" : String(trimmed))
          }
        case .float:
          if let double = CoreSchema.parseFloat(self.value) {
            return double.isNaN ? ".nan" : (double == 0 ? "0.0" : double.description)
          }
        default:
          break
      }
      return self.value
    }

    public static func == (lhs: Scalar, rhs: Scalar) -> Bool {
      return lhs.tag == rhs.tag
        && (lhs.value == rhs.value || lhs.canonicalValue == rhs.canonicalValue)
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(self.tag)
      hasher.combine(self.canonicalValue)
    }

    public var description: String {
      return self.value
    }
  }

  // MARK: - Sequences

  /// The content of a sequence node.
  public struct Sequence: Sendable, Hashable, RandomAccessCollection, MutableCollection,
                          RangeReplaceableCollection, ExpressibleByArrayLiteral {

    /// The elements of the sequence.
    public var elements: [YAMLNode]

    /// The resolved tag of the sequence.
    public var tag: YAMLTag

    /// The presentation style, or `nil` to let the serializer choose.
    public var style: CollectionStyle?

    /// The anchor of the node, if any.
    public var anchor: String?

    /// The source location of the node, if it was parsed.
    public var mark: Mark?

    /// Creates a sequence.
    public init(_ elements: [YAMLNode] = [],
                tag: YAMLTag = .seq,
                style: CollectionStyle? = nil,
                anchor: String? = nil,
                mark: Mark? = nil) {
      self.elements = elements
      self.tag = tag
      self.style = style
      self.anchor = anchor
      self.mark = mark
    }

    public init() {
      self.init([])
    }

    public init(arrayLiteral elements: YAMLNode...) {
      self.init(elements)
    }

    public var startIndex: Int {
      return self.elements.startIndex
    }

    public var endIndex: Int {
      return self.elements.endIndex
    }

    public subscript(position: Int) -> YAMLNode {
      get {
        return self.elements[position]
      }
      set {
        self.elements[position] = newValue
      }
    }

    public mutating func replaceSubrange<C>(_ subrange: Range<Int>, with newElements: C)
        where C: Swift.Collection, C.Element == YAMLNode {
      self.elements.replaceSubrange(subrange, with: newElements)
    }

    public static func == (lhs: Sequence, rhs: Sequence) -> Bool {
      return lhs.tag == rhs.tag && lhs.elements == rhs.elements
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(self.tag)
      hasher.combine(self.elements)
    }
  }

  // MARK: - Mappings

  /// The content of a mapping node. The order of entries is preserved, but
  /// not significant for equality.
  public struct Mapping: Sendable, Hashable, RandomAccessCollection,
                         ExpressibleByDictionaryLiteral {

    /// A key/value pair of a mapping.
    public struct Entry: Sendable, Hashable {

      /// The key of the entry.
      public var key: YAMLNode

      /// The value of the entry.
      public var value: YAMLNode

      /// Creates a new entry.
      public init(key: YAMLNode, value: YAMLNode) {
        self.key = key
        self.value = value
      }
    }

    /// The entries of the mapping in presentation order.
    public var entries: [Entry]

    /// The resolved tag of the mapping.
    public var tag: YAMLTag

    /// The presentation style, or `nil` to let the serializer choose.
    public var style: CollectionStyle?

    /// The anchor of the node, if any.
    public var anchor: String?

    /// The source location of the node, if it was parsed.
    public var mark: Mark?

    /// Creates a mapping.
    public init(_ entries: [Entry] = [],
                tag: YAMLTag = .map,
                style: CollectionStyle? = nil,
                anchor: String? = nil,
                mark: Mark? = nil) {
      self.entries = entries
      self.tag = tag
      self.style = style
      self.anchor = anchor
      self.mark = mark
    }

    /// Creates a mapping from key/value pairs.
    public init(_ pairs: [(YAMLNode, YAMLNode)], tag: YAMLTag = .map) {
      self.init(pairs.map { Entry(key: $0.0, value: $0.1) }, tag: tag)
    }

    public init(dictionaryLiteral elements: (YAMLNode, YAMLNode)...) {
      self.init(elements)
    }

    public var startIndex: Int {
      return self.entries.startIndex
    }

    public var endIndex: Int {
      return self.entries.endIndex
    }

    public subscript(position: Int) -> Entry {
      return self.entries[position]
    }

    /// The keys of the mapping in presentation order.
    public var keys: [YAMLNode] {
      return self.entries.map(\.key)
    }

    /// The values of the mapping in presentation order.
    public var values: [YAMLNode] {
      return self.entries.map(\.value)
    }

    /// Accesses the value associated with `key`. Setting a value replaces
    /// an existing entry or appends a new one; setting `nil` removes the
    /// entry.
    public subscript(key: YAMLNode) -> YAMLNode? {
      get {
        return self.entries.first { $0.key == key }?.value
      }
      set {
        let index = self.entries.firstIndex { $0.key == key }
        switch (index, newValue) {
          case (.some(let i), .some(let value)):
            self.entries[i].value = value
          case (.some(let i), .none):
            self.entries.remove(at: i)
          case (.none, .some(let value)):
            self.entries.append(Entry(key: key, value: value))
          case (.none, .none):
            break
        }
      }
    }

    /// Accesses the value associated with the string key `key`. Any scalar
    /// key whose value equals `key` matches, irrespective of its tag.
    public subscript(key: String) -> YAMLNode? {
      get {
        return self.entries.first { $0.key.scalar?.value == key }?.value
      }
      set {
        if let i = self.entries.firstIndex(where: { $0.key.scalar?.value == key }) {
          if let newValue {
            self.entries[i].value = newValue
          } else {
            self.entries.remove(at: i)
          }
        } else if let newValue {
          self.entries.append(Entry(key: YAMLNode(key), value: newValue))
        }
      }
    }

    public static func == (lhs: Mapping, rhs: Mapping) -> Bool {
      guard lhs.tag == rhs.tag && lhs.entries.count == rhs.entries.count else {
        return false
      }
      if lhs.entries == rhs.entries {
        return true
      }
      var remaining: [Entry: Int] = [:]
      for entry in lhs.entries {
        remaining[entry, default: 0] += 1
      }
      for entry in rhs.entries {
        guard let count = remaining[entry], count > 0 else {
          return false
        }
        remaining[entry] = count - 1
      }
      return true
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(self.tag)
      hasher.combine(self.entries.count)
      // Combine the entry hashes in an order-independent way.
      var combined = 0
      for entry in self.entries {
        combined ^= entry.hashValue
      }
      hasher.combine(combined)
    }
  }
}

// MARK: - Constructors

extension YAMLNode {

  /// The canonical null node.
  public static let null = YAMLNode.scalar(Scalar("null", tag: .null))

  /// Creates a string scalar.
  public init(_ string: String) {
    self = .scalar(Scalar(string, tag: .str))
  }

  /// Creates a boolean scalar.
  public init(_ bool: Bool) {
    self = .scalar(Scalar(bool ? "true" : "false", tag: .bool))
  }

  /// Creates an integer scalar.
  public init<T: BinaryInteger>(_ int: T) {
    self = .scalar(Scalar(String(int), tag: .int))
  }

  /// Creates a floating-point scalar. Infinite values and NaN are
  /// represented as `.inf`, `-.inf`, and `.nan`.
  public init<T: BinaryFloatingPoint & LosslessStringConvertible>(_ float: T) {
    self = .scalar(Scalar(YAMLNode.canonicalFloat(float), tag: .float))
  }

  /// Creates a sequence.
  public init(_ elements: [YAMLNode]) {
    self = .sequence(Sequence(elements))
  }

  /// Creates a mapping from key/value pairs.
  public init(_ pairs: [(YAMLNode, YAMLNode)]) {
    self = .mapping(Mapping(pairs))
  }

  /// Returns the canonical core schema representation of a floating-point
  /// number.
  static func canonicalFloat<T: BinaryFloatingPoint & LosslessStringConvertible>(_ value: T) -> String {
    if value.isNaN {
      return ".nan"
    } else if value.isInfinite {
      return value < 0 ? "-.inf" : ".inf"
    }
    let text = value.description
    // Make sure the value is not resolved as an integer.
    if text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) {
      return text
    }
    return text + ".0"
  }
}

// MARK: - Literals

extension YAMLNode: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                    ExpressibleByNilLiteral, ExpressibleByArrayLiteral,
                    ExpressibleByDictionaryLiteral {

  public init(stringLiteral value: String) {
    self.init(value)
  }

  public init(integerLiteral value: Int) {
    self.init(value)
  }

  public init(floatLiteral value: Double) {
    self.init(value)
  }

  public init(booleanLiteral value: Bool) {
    self.init(value)
  }

  public init(nilLiteral: ()) {
    self = .null
  }

  public init(arrayLiteral elements: YAMLNode...) {
    self.init(elements)
  }

  public init(dictionaryLiteral elements: (YAMLNode, YAMLNode)...) {
    self.init(elements)
  }
}

// MARK: - Accessors

extension YAMLNode {

  /// The scalar content, if this is a scalar node.
  public var scalar: Scalar? {
    if case .scalar(let scalar) = self {
      return scalar
    }
    return nil
  }

  /// The sequence content, if this is a sequence node.
  public var sequence: Sequence? {
    if case .sequence(let sequence) = self {
      return sequence
    }
    return nil
  }

  /// The mapping content, if this is a mapping node.
  public var mapping: Mapping? {
    if case .mapping(let mapping) = self {
      return mapping
    }
    return nil
  }

  /// The resolved tag of the node.
  public var tag: YAMLTag {
    get {
      switch self {
        case .scalar(let scalar): return scalar.tag
        case .sequence(let sequence): return sequence.tag
        case .mapping(let mapping): return mapping.tag
      }
    }
    set {
      switch self {
        case .scalar(var scalar):
          scalar.tag = newValue
          self = .scalar(scalar)
        case .sequence(var sequence):
          sequence.tag = newValue
          self = .sequence(sequence)
        case .mapping(var mapping):
          mapping.tag = newValue
          self = .mapping(mapping)
      }
    }
  }

  /// The anchor of the node, if any.
  public var anchor: String? {
    get {
      switch self {
        case .scalar(let scalar): return scalar.anchor
        case .sequence(let sequence): return sequence.anchor
        case .mapping(let mapping): return mapping.anchor
      }
    }
    set {
      switch self {
        case .scalar(var scalar):
          scalar.anchor = newValue
          self = .scalar(scalar)
        case .sequence(var sequence):
          sequence.anchor = newValue
          self = .sequence(sequence)
        case .mapping(var mapping):
          mapping.anchor = newValue
          self = .mapping(mapping)
      }
    }
  }

  /// The source location of the node, if it was parsed.
  public var mark: Mark? {
    switch self {
      case .scalar(let scalar): return scalar.mark
      case .sequence(let sequence): return sequence.mark
      case .mapping(let mapping): return mapping.mark
    }
  }

  /// Is this a scalar tagged `tag:yaml.org,2002:null`?
  public var isNull: Bool {
    return self.scalar?.tag == .null
  }

  /// The textual value of a scalar node, irrespective of its tag.
  public var string: String? {
    return self.scalar?.value
  }

  /// The value of a scalar tagged `tag:yaml.org,2002:bool`.
  public var bool: Bool? {
    guard let scalar = self.scalar, scalar.tag == .bool else {
      return nil
    }
    return CoreSchema.parseBool(scalar.value)
  }

  /// The value of a scalar tagged `tag:yaml.org,2002:int`, or of a
  /// `tag:yaml.org,2002:float` scalar with an integral value.
  public var int: Int? {
    guard let scalar = self.scalar else {
      return nil
    }
    if scalar.tag == .int {
      return CoreSchema.parseInteger(scalar.value, as: Int.self)
    } else if scalar.tag == .float, let value = CoreSchema.parseFloat(scalar.value) {
      return Int(exactly: value)
    }
    return nil
  }

  /// The value of a scalar tagged `tag:yaml.org,2002:float` or
  /// `tag:yaml.org,2002:int`.
  public var double: Double? {
    guard let scalar = self.scalar, scalar.tag == .float || scalar.tag == .int else {
      return nil
    }
    return CoreSchema.parseFloat(scalar.value)
  }

  /// The elements of a sequence node.
  public var array: [YAMLNode]? {
    return self.sequence?.elements
  }

  /// Returns the element at `index` of a sequence node.
  public subscript(index: Int) -> YAMLNode? {
    guard let elements = self.sequence?.elements, elements.indices.contains(index) else {
      return nil
    }
    return elements[index]
  }

  /// Returns the value for the string key `key` of a mapping node.
  public subscript(key: String) -> YAMLNode? {
    return self.mapping?[key]
  }

  /// Returns the value for `key` of a mapping node.
  public subscript(key: YAMLNode) -> YAMLNode? {
    return self.mapping?[key]
  }
}

extension YAMLNode: CustomStringConvertible {

  /// A compact flow-style representation of the node for debugging.
  public var description: String {
    switch self {
      case .scalar(let scalar):
        if scalar.tag == .str {
          return "\"\(scalar.value)\""
        }
        return scalar.value
      case .sequence(let sequence):
        return "[" + sequence.elements.map(\.description).joined(separator: ", ") + "]"
      case .mapping(let mapping):
        return "{" + mapping.entries.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
    }
  }
}
