import Foundation

struct UsageAccount: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let provider: String
    let planName: String?
    let tokensUsed: Int
    let tokensLimit: Int?
    let costUsed: Double
    let costLimit: Double?
    let requestsCount: Int
    let lastProbed: String?
    let isActive: Bool

    static func decodeList(from data: Data) throws -> [UsageAccount] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([UsageAccount].self, from: data)
    }
}

struct MobileStatus: Codable, Equatable {
    let status: String
    let service: String
    let version: String
    let pairedAgentsOnline: Int?

    static func decode(from data: Data) throws -> MobileStatus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MobileStatus.self, from: data)
    }
}
