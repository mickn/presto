import Foundation

extension Duration {
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    public var milliseconds: Double { seconds * 1000 }
}
