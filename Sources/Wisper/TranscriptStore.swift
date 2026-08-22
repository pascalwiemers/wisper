import Foundation
import SQLite3

/// Local-only SQLite log of every dictation. Powers history, recovery, and
/// the Phase 4 style analytics.
final class TranscriptStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisper", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("Wisper: could not create app support dir: \(error)")
            return nil
        }
        let path = dir.appendingPathComponent("transcripts.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            NSLog("Wisper: could not open transcript database")
            return nil
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS transcripts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            raw TEXT NOT NULL,
            clean TEXT,
            duration_s REAL NOT NULL,
            word_count INTEGER NOT NULL,
            app_bundle TEXT,
            delivery TEXT NOT NULL,
            asr_ms INTEGER,
            cleanup_ms INTEGER
        );
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            NSLog("Wisper: could not create transcripts table")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func save(raw: String, clean: String?, durationSeconds: Double, appBundleID: String?, delivery: String, asrMs: Int, cleanupMs: Int? = nil) {
        let sql = """
        INSERT INTO transcripts (ts, raw, clean, duration_s, word_count, app_bundle, delivery, asr_ms, cleanup_ms)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("Wisper: failed to prepare insert")
            return
        }
        defer { sqlite3_finalize(stmt) }

        let wordCount = raw.split(whereSeparator: \.isWhitespace).count
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, raw, -1, transient)
        if let clean {
            sqlite3_bind_text(stmt, 3, clean, -1, transient)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_double(stmt, 4, durationSeconds)
        sqlite3_bind_int(stmt, 5, Int32(wordCount))
        if let appBundleID {
            sqlite3_bind_text(stmt, 6, appBundleID, -1, transient)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_text(stmt, 7, delivery, -1, transient)
        sqlite3_bind_int(stmt, 8, Int32(asrMs))
        if let cleanupMs {
            sqlite3_bind_int(stmt, 9, Int32(cleanupMs))
        } else {
            sqlite3_bind_null(stmt, 9)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("Wisper: failed to insert transcript")
        }
    }

    struct Row {
        let timestamp: Date
        let raw: String
        let clean: String?
        let durationSeconds: Double
        let wordCount: Int
        let appBundleID: String?
        let delivery: String
        let asrMs: Int?
        let cleanupMs: Int?
    }

    func allRows() -> [Row] {
        let sql = "SELECT ts, raw, clean, duration_s, word_count, app_bundle, delivery, asr_ms, cleanup_ms FROM transcripts ORDER BY ts ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Row(
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                raw: String(cString: sqlite3_column_text(stmt, 1)),
                clean: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 2)),
                durationSeconds: sqlite3_column_double(stmt, 3),
                wordCount: Int(sqlite3_column_int(stmt, 4)),
                appBundleID: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 5)),
                delivery: String(cString: sqlite3_column_text(stmt, 6)),
                asrMs: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 7)),
                cleanupMs: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8))
            ))
        }
        return rows
    }
}
