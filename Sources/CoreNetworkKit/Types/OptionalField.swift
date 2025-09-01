//
//  OptionalField.swift
//  CoreNetworkKit
//
//  Created by Claude on 2025/8/21.
//  通用三态语义系统：完全自动化的undefined/null/value处理
//

import Foundation

/// 通用的可选字段类型，支持三态语义
/// 用于精确控制JSON序列化中字段的出现与否
public enum OptionalField<T: Codable>: Codable {
    /// 字段不出现在JSON中（对应JS的undefined）
    case undefined
    
    /// 字段出现在JSON中，值为null（对应JS的null）
    case null
    
    /// 字段出现在JSON中，值为具体数据（对应JS的value）
    case value(T)
    
    // MARK: - Codable Implementation
    
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .undefined:
            // 关键：什么都不做，让上层容器跳过这个字段
            return
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .value(let val):
            var container = encoder.singleValueContainer()
            try container.encode(val)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else {
            let value = try container.decode(T.self)
            self = .value(value)
        }
    }
    
    // MARK: - Convenience Properties
    
    /// 获取实际值（如果有的话）
    public var value: T? {
        switch self {
        case .value(let val):
            return val
        case .undefined, .null:
            return nil
        }
    }
    
    /// 是否为undefined状态
    public var isUndefined: Bool {
        switch self {
        case .undefined:
            return true
        case .null, .value:
            return false
        }
    }
    
    /// 是否为null状态
    public var isNull: Bool {
        switch self {
        case .null:
            return true
        case .undefined, .value:
            return false
        }
    }
    
    /// 是否有具体值
    public var hasValue: Bool {
        switch self {
        case .value:
            return true
        case .undefined, .null:
            return false
        }
    }
}

// MARK: - Convenience Initializers

public extension OptionalField {
    /// 从可选值创建OptionalField
    /// - Parameter optionalValue: 可选值
    /// - Returns: 如果值为nil则返回.null，否则返回.value
    static func fromOptional(_ optionalValue: T?) -> OptionalField<T> {
        if let value = optionalValue {
            return .value(value)
        } else {
            return .null
        }
    }
    
    /// 从可选值创建OptionalField，nil时返回undefined
    /// - Parameter optionalValue: 可选值
    /// - Returns: 如果值为nil则返回.undefined，否则返回.value
    static func fromOptionalAsUndefined(_ optionalValue: T?) -> OptionalField<T> {
        if let value = optionalValue {
            return .value(value)
        } else {
            return .undefined
        }
    }
}

// MARK: - Equatable & Hashable

extension OptionalField: Equatable where T: Equatable {
    public static func == (lhs: OptionalField<T>, rhs: OptionalField<T>) -> Bool {
        switch (lhs, rhs) {
        case (.undefined, .undefined), (.null, .null):
            return true
        case (.value(let lhsValue), .value(let rhsValue)):
            return lhsValue == rhsValue
        default:
            return false
        }
    }
}

extension OptionalField: Hashable where T: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .undefined:
            hasher.combine(0)
        case .null:
            hasher.combine(1)
        case .value(let val):
            hasher.combine(2)
            hasher.combine(val)
        }
    }
}

// MARK: - CustomStringConvertible

extension OptionalField: CustomStringConvertible {
    public var description: String {
        switch self {
        case .undefined:
            return "undefined"
        case .null:
            return "null"
        case .value(let val):
            return "value(\(val))"
        }
    }
}

// MARK: - 属性包装器：极简三态语义

/// 属性包装器：自动处理三态语义
/// @OptionalUpdate var title: String?
@propertyWrapper
public struct OptionalUpdate<T: Codable>: Codable {
    private var field: OptionalField<T>
    
    public var wrappedValue: T? {
        get { field.value }
        set {
            switch newValue {
            case .none: field = .null
            case .some(let value): field = .value(value)
            }
        }
    }
    
    public var projectedValue: OptionalField<T> {
        get { field }
        set { field = newValue }
    }
    
    public init(wrappedValue: T? = nil) {
        self.field = wrappedValue.map { .value($0) } ?? .undefined
    }
    
    public init(_ field: OptionalField<T>) {
        self.field = field
    }
    
    // 关键：属性包装器的encode直接处理三态
    public func encode(to encoder: Encoder) throws {
        switch field {
        case .undefined:
            return
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .value(let val):
            var container = encoder.singleValueContainer()
            try container.encode(val)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            field = .null
        } else {
            field = .value(try container.decode(T.self))
        }
    }
}

// MARK: - 通用编码工具函数

/// 通用的OptionalField编码函数，用于手动encode实现
/// 只有非.undefined的字段才会被编码到JSON中
public func encodeOptionalField<T: Codable, K: CodingKey>(
    _ field: OptionalField<T>,
    to container: inout KeyedEncodingContainer<K>,
    forKey key: K
) throws {
    switch field {
    case .undefined:
        // 不编码，字段不会出现在JSON中
        break
    case .null:
        try container.encodeNil(forKey: key)
    case .value(let val):
        try container.encode(val, forKey: key)
    }
}