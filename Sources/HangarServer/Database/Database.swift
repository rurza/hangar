import Foundation
import GRDB

/// The server's SQLite store. A file path opens a WAL `DatabasePool`; `":memory:"` a `DatabaseQueue`.
public final class Database: Sendable {
    public let pool: any DatabaseWriter

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        if path == ":memory:" {
            pool = try DatabaseQueue(configuration: configuration)
        } else {
            pool = try DatabasePool(path: path, configuration: configuration)
        }
    }

    public func migrate() throws {
        try Migrations.migrator.migrate(pool)
    }

    func read<T>(_ body: (GRDB.Database) throws -> T) throws -> T { try pool.read(body) }

    func write<T>(_ body: (GRDB.Database) throws -> T) throws -> T { try pool.write(body) }
}

/// Dates are stored as seconds since 1970 rounded to the millisecond, matching `JSONCoding`.
func dbTime(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() / 1000 }

func dbDate(_ time: Double) -> Date { Date(timeIntervalSince1970: time) }

func dbDate(_ time: Double?) -> Date? { time.map(dbDate) }
