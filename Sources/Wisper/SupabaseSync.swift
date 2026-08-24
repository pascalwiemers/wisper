import Foundation
import CryptoKit

/// Optional cross-device sync against a Supabase project. Everything speaks
/// plain PostgREST + GoTrue REST, so a client on any platform (the Linux
/// twin) can implement the identical protocol — see supabase/schema.sql.
///
/// Sync model:
///  - transcripts: append-only; push local rows with synced=0, pull rows
///    from other devices newer than the last pull.
///  - documents (dictionary / commands / each skill): whole-document
///    last-write-wins keyed by (kind, name), compared via content hash and
///    the server's updated_at.
actor SupabaseSync {
    struct Config {
        var url: String
        var anonKey: String
        var enabled: Bool

        static func current() -> Config {
            let d = UserDefaults.standard
            return Config(
                url: d.string(forKey: "sync.url") ?? "",
                anonKey: d.string(forKey: "sync.anonKey") ?? "",
                enabled: d.bool(forKey: "sync.enabled")
            )
        }
    }

    private struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var email: String
    }

    private struct SyncState: Codable {
        var lastTranscriptPull: Date?
        var docHashes: [String: String] = [:]   // "kind/name" → sha256 of last synced content
    }

    private var session: Session?
    private var state = SyncState()
    private let deviceName = Host.current().localizedName ?? "mac"

    private var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisper", isDirectory: true)
    }
    private var sessionURL: URL { supportDir.appendingPathComponent("sync-session.json") }
    private var stateURL: URL { supportDir.appendingPathComponent("sync-state.json") }

    init() {
        if let data = try? Data(contentsOf: sessionURL) {
            session = try? JSONDecoder.sync.decode(Session.self, from: data)
        }
        if let data = try? Data(contentsOf: stateURL) {
            state = (try? JSONDecoder.sync.decode(SyncState.self, from: data)) ?? SyncState()
        }
    }

    var signedInEmail: String? { session?.email }

    // MARK: - Auth (GoTrue)

    func signIn(email: String, password: String, signUp: Bool) async throws {
        let config = Config.current()
        guard let base = URL(string: config.url), !config.anonKey.isEmpty else {
            throw SyncError("Enter the project URL and anon key first")
        }
        let path = signUp ? "auth/v1/signup" : "auth/v1/token?grant_type=password"
        var request = URLRequest(url: base.appendingPathComponent("auth/v1").deletingLastPathComponent().appendingPathComponent(path))
        request = URLRequest(url: URL(string: config.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path)!)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
            throw SyncError(Self.errorMessage(from: data) ?? "Sign-in failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            // Sign-up with email confirmation enabled returns a user but no session.
            throw SyncError("Account created — confirm the email (or disable confirmations in Supabase Auth settings), then sign in.")
        }
        session = Session(accessToken: access, refreshToken: refresh,
                          expiresAt: Date().addingTimeInterval(expiresIn - 60), email: email)
        persistSession()
    }

    func signOut() {
        session = nil
        try? FileManager.default.removeItem(at: sessionURL)
    }

    private func validAccessToken() async throws -> String {
        guard var session else { throw SyncError("Not signed in") }
        if session.expiresAt > Date() { return session.accessToken }

        let config = Config.current()
        var request = URLRequest(url: URL(string: config.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/auth/v1/token?grant_type=refresh_token")!)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": session.refreshToken])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 300,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            self.session = nil
            try? FileManager.default.removeItem(at: sessionURL)
            throw SyncError("Session expired — sign in again")
        }
        session.accessToken = access
        session.refreshToken = refresh
        session.expiresAt = Date().addingTimeInterval(expiresIn - 60)
        self.session = session
        persistSession()
        return access
    }

    // MARK: - Sync

    /// Runs a full sync; returns a short human-readable summary.
    func syncNow(store: TranscriptStore, dictionaryURL: URL, commandsURL: URL, skillsDir: URL) async throws -> String {
        let pushedCount = try await pushTranscripts(store: store)
        let pulledCount = try await pullTranscripts(store: store)
        var docsChanged = 0
        docsChanged += try await syncDocument(kind: "dictionary", name: "dictionary.txt", fileURL: dictionaryURL)
        docsChanged += try await syncDocument(kind: "commands", name: "commands.json", fileURL: commandsURL)
        let skillFiles = ((try? FileManager.default.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
        for file in skillFiles {
            docsChanged += try await syncDocument(kind: "skill", name: file.lastPathComponent, fileURL: file)
        }
        docsChanged += try await pullNewSkills(into: skillsDir, localNames: Set(skillFiles.map(\.lastPathComponent)))
        persistState()
        return "↑\(pushedCount) ↓\(pulledCount) transcripts, \(docsChanged) documents"
    }

    private func pushTranscripts(store: TranscriptStore) async throws -> Int {
        let rows = store.unsyncedRows()
        guard !rows.isEmpty else { return 0 }
        let payload: [[String: Any]] = rows.compactMap { row in
            guard let uuid = row.uuid else { return nil }
            // PostgREST bulk inserts require identical keys on every object,
            // so optional fields are sent as explicit nulls.
            let object: [String: Any] = [
                "id": uuid,
                "device": deviceName,
                "ts": ISO8601DateFormatter.sync.string(from: row.timestamp),
                "raw": row.raw,
                "duration_s": row.durationSeconds,
                "word_count": row.wordCount,
                "delivery": row.delivery,
                "clean": row.clean ?? NSNull(),
                "app_bundle": row.appBundleID ?? NSNull(),
                "asr_ms": row.asrMs ?? NSNull(),
                "cleanup_ms": row.cleanupMs ?? NSNull(),
            ]
            return object
        }
        _ = try await rest("transcripts?on_conflict=id", method: "POST",
                           body: try JSONSerialization.data(withJSONObject: payload),
                           prefer: "resolution=merge-duplicates,return=minimal")
        store.markSynced(uuids: rows.compactMap(\.uuid))
        return rows.count
    }

    private func pullTranscripts(store: TranscriptStore) async throws -> Int {
        let since = ISO8601DateFormatter.sync.string(from: state.lastTranscriptPull ?? .distantPast)
        let query = "transcripts?select=*&device=neq.\(deviceName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "mac")&created_at=gt.\(since)&order=created_at.asc&limit=1000"
        let data = try await rest(query, method: "GET", body: nil, prefer: nil)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        var pulled = 0
        for remote in rows {
            guard let uuid = remote["id"] as? String,
                  let tsString = remote["ts"] as? String,
                  let ts = ISO8601DateFormatter.sync.date(from: tsString) ?? ISO8601DateFormatter().date(from: tsString),
                  let raw = remote["raw"] as? String else { continue }
            if !store.hasRow(uuid: uuid) {
                store.insertRemote(TranscriptStore.Row(
                    timestamp: ts,
                    raw: raw,
                    clean: remote["clean"] as? String,
                    durationSeconds: remote["duration_s"] as? Double ?? 0,
                    wordCount: remote["word_count"] as? Int ?? 0,
                    appBundleID: remote["app_bundle"] as? String,
                    delivery: remote["delivery"] as? String ?? "pasted",
                    asrMs: remote["asr_ms"] as? Int,
                    cleanupMs: remote["cleanup_ms"] as? Int,
                    uuid: uuid
                ))
                pulled += 1
            }
            if let createdString = remote["created_at"] as? String,
               let created = ISO8601DateFormatter.sync.date(from: createdString) {
                state.lastTranscriptPull = max(state.lastTranscriptPull ?? .distantPast, created)
            }
        }
        return pulled
    }

    /// Last-write-wins document sync. Returns 1 if anything changed.
    private func syncDocument(kind: String, name: String, fileURL: URL) async throws -> Int {
        let key = "\(kind)/\(name)"
        let localContent = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let localHash = Self.hash(localContent)
        let localChanged = state.docHashes[key] != localHash

        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        let data = try await rest("sync_documents?select=content,updated_at&kind=eq.\(kind)&name=eq.\(encodedName)", method: "GET", body: nil, prefer: nil)
        let remoteRow = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first
        let remoteContent = remoteRow?["content"] as? String
        let remoteChanged = remoteContent != nil && Self.hash(remoteContent!) != state.docHashes[key]

        switch (localChanged, remoteChanged) {
        case (false, false):
            return 0
        case (true, false), (true, true):
            // Local wins (on true/true this is last-writer-wins with a log).
            if remoteChanged { wlog("sync: conflict on \(key) — keeping this device's version") }
            try await upsertDocument(kind: kind, name: name, content: localContent)
            state.docHashes[key] = localHash
            return 1
        case (false, true):
            try remoteContent!.write(to: fileURL, atomically: true, encoding: .utf8)
            state.docHashes[key] = Self.hash(remoteContent!)
            return 1
        }
    }

    /// Skills that exist remotely but not locally yet.
    private func pullNewSkills(into skillsDir: URL, localNames: Set<String>) async throws -> Int {
        let data = try await rest("sync_documents?select=name,content&kind=eq.skill", method: "GET", body: nil, prefer: nil)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        var added = 0
        for row in rows {
            guard let name = row["name"] as? String, !localNames.contains(name),
                  let content = row["content"] as? String else { continue }
            let file = skillsDir.appendingPathComponent(name)
            try? content.write(to: file, atomically: true, encoding: .utf8)
            state.docHashes["skill/\(name)"] = Self.hash(content)
            added += 1
        }
        return added
    }

    private func upsertDocument(kind: String, name: String, content: String) async throws {
        let payload: [String: Any] = [
            "kind": kind, "name": name, "content": content,
            "updated_at": ISO8601DateFormatter.sync.string(from: Date()),
            "updated_by": deviceName,
        ]
        _ = try await rest("sync_documents?on_conflict=user_id,kind,name", method: "POST",
                           body: try JSONSerialization.data(withJSONObject: [payload]),
                           prefer: "resolution=merge-duplicates,return=minimal")
    }

    // MARK: - Plumbing

    private func rest(_ pathAndQuery: String, method: String, body: Data?, prefer: String?) async throws -> Data {
        let config = Config.current()
        let token = try await validAccessToken()
        guard let url = URL(string: config.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/rest/v1/" + pathAndQuery) else {
            throw SyncError("Bad project URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
            let message = Self.errorMessage(from: data) ?? "HTTP error"
            if message.contains("relation") && message.contains("does not exist") {
                throw SyncError("Tables missing — run supabase/schema.sql in the Supabase SQL editor")
            }
            throw SyncError(message)
        }
        return data
    }

    private func persistSession() {
        if let data = try? JSONEncoder.sync.encode(session) {
            try? data.write(to: sessionURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionURL.path)
        }
    }

    private func persistState() {
        if let data = try? JSONEncoder.sync.encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["msg"] ?? json["message"] ?? json["error_description"] ?? json["error"]) as? String
    }
}

struct SyncError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension JSONEncoder {
    static let sync: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let sync: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension ISO8601DateFormatter {
    static let sync: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
