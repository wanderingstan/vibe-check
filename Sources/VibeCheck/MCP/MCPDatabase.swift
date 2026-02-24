import Foundation
import GRDB

/// Read-only database access for MCP tools
/// Mirrors the Python database.py module
actor MCPDatabase {
    private let dbPath: String
    private var pool: DatabasePool?

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Execute a read-only query and return rows as dictionaries
    func executeQuery(_ sql: String, arguments: [DatabaseValueConvertible] = []) async throws -> [[String: DatabaseValue]] {
        // Open database in read-only mode
        let pool = try getDatabasePool()

        return try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.map { row in
                var dict: [String: DatabaseValue] = [:]
                for column in row.columnNames {
                    dict[column] = row[column]
                }
                return dict
            }
        }
    }

    /// Execute a query and return single scalar value
    func executeScalar(_ sql: String, arguments: [DatabaseValueConvertible] = []) async throws -> DatabaseValue? {
        let pool = try getDatabasePool()

        return try await pool.read { db in
            try DatabaseValue.fetchOne(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// Get or create database pool
    private func getDatabasePool() throws -> DatabasePool {
        if let pool = pool {
            return pool
        }

        // Check if database exists
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw MCPError.databaseError("Database not found at: \(dbPath)")
        }

        // Open database in read-only mode
        var config = Configuration()
        config.readonly = true
        config.label = "MCP Read-Only Pool"

        let newPool = try DatabasePool(path: dbPath, configuration: config)
        self.pool = newPool
        return newPool
    }
}

// MARK: - Helper Extensions

extension DatabaseValue {
    /// Convert DatabaseValue to Swift type
    func toSwiftValue() -> Any? {
        if isNull {
            return nil
        }

        // Try each type in order
        if let intValue = Int64.fromDatabaseValue(self) {
            return intValue
        }
        if let doubleValue = Double.fromDatabaseValue(self) {
            return doubleValue
        }
        if let stringValue = String.fromDatabaseValue(self) {
            return stringValue
        }
        if let dataValue = Data.fromDatabaseValue(self) {
            return dataValue
        }

        return nil
    }

    /// Get as String (for display)
    func asString() -> String {
        if isNull {
            return "NULL"
        }

        if let value = toSwiftValue() {
            return "\(value)"
        }

        return "NULL"
    }

    /// Get as Int
    func asInt() -> Int? {
        if let int64 = Int64.fromDatabaseValue(self) {
            return Int(int64)
        }
        return nil
    }

    /// Get as Double
    func asDouble() -> Double? {
        return Double.fromDatabaseValue(self)
    }
}

/// Helper to convert dictionary of DatabaseValues to [String: Any]
extension Dictionary where Key == String, Value == DatabaseValue {
    func toSwiftDict() -> [String: Any?] {
        return mapValues { $0.toSwiftValue() }
    }

    func getString(_ key: String) -> String? {
        return self[key]?.toSwiftValue() as? String
    }

    func getInt(_ key: String) -> Int? {
        if let int64 = self[key]?.toSwiftValue() as? Int64 {
            return Int(int64)
        }
        return self[key]?.toSwiftValue() as? Int
    }

    func getDouble(_ key: String) -> Double? {
        return self[key]?.toSwiftValue() as? Double
    }
}
