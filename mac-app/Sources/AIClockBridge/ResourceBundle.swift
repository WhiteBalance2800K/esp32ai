import Foundation

extension Bundle {
    static let aiClockResources: Bundle = {
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("AIClockBridge_AIClockBridge.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
