import Foundation
import HangarCore

public struct WorkerConfiguration: Codable, Equatable, Sendable {
    public var serverURL: URL
    public var token: String
    public var maxConcurrentJobs: Int
    public var dataDirectory: String

    public init(serverURL: URL, token: String, maxConcurrentJobs: Int = 1, dataDirectory: String) {
        self.serverURL = serverURL
        self.token = token
        self.maxConcurrentJobs = maxConcurrentJobs
        self.dataDirectory = dataDirectory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decode(URL.self, forKey: .serverURL)
        token = try container.decode(String.self, forKey: .token)
        maxConcurrentJobs = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentJobs) ?? 1
        dataDirectory = try container.decode(String.self, forKey: .dataDirectory)
    }

    public struct LoadError: Error, CustomStringConvertible, Equatable {
        public var description: String
    }

    public static func load(from path: String) throws -> WorkerConfiguration {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LoadError(description: "Worker configuration not found or unreadable at \(path)")
        }
        do {
            return try JSONCoding.decoder.decode(WorkerConfiguration.self, from: data)
        } catch {
            throw LoadError(description: "Invalid worker configuration at \(path): \(error)")
        }
    }
}
