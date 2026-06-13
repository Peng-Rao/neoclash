import Foundation

public struct RingBuffer<Element>: Sendable where Element: Sendable {
    private var storage: [Element] = []
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var elements: [Element] {
        storage
    }

    public mutating func append(_ element: Element) {
        storage.append(element)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
    }
}

