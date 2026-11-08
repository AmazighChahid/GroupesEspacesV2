import Foundation

struct CrossSpaceFixture: Codable {
    struct Target: Codable {
        let window: UInt32
        let space: String
        let name: String
        var ownerPID: Int32? = nil
    }

    let pid: Int32
    let originalSpace: String
    let targets: [Target]
}
