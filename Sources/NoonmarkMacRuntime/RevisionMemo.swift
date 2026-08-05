import Foundation

/// 按数据版本备忘的单值投影：版本一致时复用上次结果，版本变化后重算一次。
/// 供视图层在多次 body 求值之间共享同一数据版本的派生投影，
/// 避免每次渲染重复全量计算。
public struct RevisionMemo<Revision: Equatable, Value> {
    private var cached: (revision: Revision, value: Value)?

    public init() {}

    public var cachedRevision: Revision? {
        cached?.revision
    }

    public mutating func value(
        at revision: Revision,
        _ compute: () -> Value
    ) -> Value {
        if let cached, cached.revision == revision {
            return cached.value
        }
        let value = compute()
        cached = (revision, value)
        return value
    }

    public mutating func invalidate() {
        cached = nil
    }
}

/// 按数据版本备忘的键值投影：版本变化时整体失效，单键惰性计算并缓存，
/// 同一版本内相同键只计算一次。
public struct KeyedRevisionMemo<Revision: Equatable, Key: Hashable, Value> {
    private var revision: Revision?
    private var values: [Key: Value] = [:]

    public init() {}

    public var cachedRevision: Revision? {
        revision
    }

    public mutating func value(
        for key: Key,
        at revision: Revision,
        _ compute: (Key) -> Value
    ) -> Value {
        if self.revision != revision {
            self.revision = revision
            values.removeAll()
        }
        if let cached = values[key] {
            return cached
        }
        let value = compute(key)
        values[key] = value
        return value
    }

    public mutating func invalidate() {
        revision = nil
        values.removeAll()
    }
}
