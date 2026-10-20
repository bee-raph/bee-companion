import Foundation
import GRDB

/// GRDB serializes every read and write on its database queue.
final class LocalStore: @unchecked Sendable {
  let db: DatabaseQueue
  init(url: URL) throws {
    db = try DatabaseQueue(path: url.path)
    var migrations = DatabaseMigrator()
    migrations.registerMigration("v1") { db in
      try db.execute(
        sql: "CREATE TABLE items(id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload BLOB NOT NULL)")
      try db.execute(
        sql:
          "CREATE TABLE outbox(sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, operation TEXT NOT NULL UNIQUE, payload BLOB NOT NULL)"
      )
      try db.execute(sql: "CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
      try db.execute(
        sql: "CREATE TABLE conflicts(id TEXT PRIMARY KEY, local BLOB NOT NULL, server BLOB)")
      try db.execute(
        sql: "CREATE VIRTUAL TABLE search USING fts5(id UNINDEXED, title, description, body)")
    }
    migrations.registerMigration("v2-outbox") { db in
      try db.execute(sql: "ALTER TABLE outbox ADD COLUMN sent INTEGER NOT NULL DEFAULT 0")
    }
    migrations.registerMigration("v3-query-indexes") { db in
      try db.execute(sql: "CREATE INDEX outbox_record_sequence ON outbox(id, sequence)")
    }
    migrations.registerMigration("v4-record-revisions") { db in
      try db.execute(sql: "ALTER TABLE items ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
      try db.execute(
        sql:
          "UPDATE items SET revision=COALESCE(json_extract(CAST(payload AS TEXT), '$.revision'), 0)"
      )
    }
    migrations.registerMigration("v5-workspace-search") { db in
      let keys = WorkspaceSearchIndex.fields.map { "'" + $0 + "'" }.joined(separator: ",")
      try db.execute(sql: "DELETE FROM search")
      try db.execute(
        sql: """
          INSERT INTO search(id,title,description,body)
          SELECT json_extract(CAST(payload AS TEXT),'$.id'),
            COALESCE(json_extract(CAST(payload AS TEXT),'$.body.title'),''),
            COALESCE(json_extract(CAST(payload AS TEXT),'$.body.description'),''),
            COALESCE((SELECT group_concat(value, char(10))
              FROM json_each(json_extract(CAST(payload AS TEXT),'$.body'))
              WHERE key IN (\(keys))), '')
          FROM items WHERE COALESCE(json_extract(CAST(payload AS TEXT),'$.deleted'),0)=0
          """)
    }
    try migrations.migrate(db)
  }
  func all() throws -> [Item] {
    try db.read { db in
      try Data.fetchAll(db, sql: "SELECT payload FROM items").map {
        try JSONDecoder().decode(Item.self, from: $0)
      }
    }
  }
  static func put(_ item: Item, db: Database) throws {
    try db.execute(
      sql: "INSERT OR REPLACE INTO items(id,kind,payload,revision) VALUES (?, ?, ?, ?)",
      arguments: [item.id, item.kind, try JSONEncoder().encode(item), item.revision])
    try db.execute(sql: "DELETE FROM search WHERE id=?", arguments: [item.id])
    if !item.deleted {
      try db.execute(
        sql: "INSERT INTO search VALUES(?,?,?,?)",
        arguments: [
          item.id, item.title, item.body["description"] ?? "", WorkspaceSearchIndex.text(item),
        ])
    }
  }
  func save(_ input: Item) throws {
    try db.write { db in
      var item = input
      if let revision = try Int.fetchOne(
        db, sql: "SELECT revision FROM items WHERE id=?", arguments: [item.id])
      {
        item.revision = revision
      }
      try Self.put(item, db: db)
      // Preserve mutations already sent; coalesce only drafts that never left this device.
      if try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM conflicts WHERE id=?", arguments: [item.id])! > 0
      {
        try db.execute(
          sql: "UPDATE conflicts SET local=? WHERE id=?",
          arguments: [try JSONEncoder().encode(item), item.id])
        return
      }
      try db.execute(sql: "DELETE FROM outbox WHERE id=? AND sent=0", arguments: [item.id])
      let m = Mutation(item)
      try db.execute(
        sql: "INSERT INTO outbox(id,operation,payload) VALUES(?,?,?)",
        arguments: [item.id, m.operationID, try JSONEncoder().encode(m)])
    }
  }
  func nextMutation() throws -> Mutation? {
    try db.write { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT sequence,payload FROM outbox ORDER BY sequence LIMIT 1")
      else { return nil }
      try db.execute(
        sql: "UPDATE outbox SET sent=1 WHERE sequence=?", arguments: [row["sequence"] as Int])
      return try JSONDecoder().decode(Mutation.self, from: row["payload"] as Data)
    }
  }
  func pendingCount() throws -> Int {
    try db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox") ?? 0 }
  }
  func pending() throws -> [Mutation] {
    try db.read { db in
      try Data.fetchAll(db, sql: "SELECT payload FROM outbox ORDER BY sequence").map {
        try JSONDecoder().decode(Mutation.self, from: $0)
      }
    }
  }
  func accept(_ result: PushResult.Result) throws {
    try db.write { db in
      guard
        let data = try Data.fetchOne(
          db, sql: "SELECT payload FROM outbox WHERE operation=?", arguments: [result.operationID])
      else { return }
      let mutation = try JSONDecoder().decode(Mutation.self, from: data)
      if result.status == "conflict" {
        let local = try Data.fetchOne(
          db, sql: "SELECT payload FROM items WHERE id=?", arguments: [mutation.id])!
        try db.execute(
          sql: "INSERT OR REPLACE INTO conflicts VALUES(?,?,?)",
          arguments: [mutation.id, local, try result.server.map { try JSONEncoder().encode($0) }])
        // Keep local draft and block this record until explicitly resolved.
        try db.execute(sql: "DELETE FROM outbox WHERE id=?", arguments: [mutation.id])
      } else if let record = result.record {
        try db.execute(sql: "DELETE FROM outbox WHERE operation=?", arguments: [result.operationID])
        let later = try Row.fetchAll(
          db, sql: "SELECT sequence,payload FROM outbox WHERE id=? ORDER BY sequence",
          arguments: [record.id])
        if later.isEmpty {
          try Self.put(record, db: db)
        } else {
          if let payload = try Data.fetchOne(
            db, sql: "SELECT payload FROM items WHERE id=?", arguments: [record.id])
          {
            var local = try JSONDecoder().decode(Item.self, from: payload)
            local.revision = record.revision
            try Self.put(local, db: db)
          }
          var revision = record.revision
          for row in later {
            var m = try JSONDecoder().decode(Mutation.self, from: row["payload"] as Data)
            m.expectedRevision = revision
            revision += 1
            try db.execute(
              sql: "UPDATE outbox SET payload=? WHERE sequence=?",
              arguments: [try JSONEncoder().encode(m), row["sequence"] as Int])
          }
        }
      }
    }
  }
  func apply(_ page: PullResult) throws {
    try db.write { db in
      for item in page.changes {
        let dirty =
          try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE id=?", arguments: [item.id])!
          > 0
        let conflict =
          try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM conflicts WHERE id=?", arguments: [item.id])! > 0
        if !dirty && !conflict { try Self.put(item, db: db) }
      }
      try db.execute(
        sql: "INSERT OR REPLACE INTO settings VALUES('cursor',?)", arguments: [String(page.cursor)])
    }
  }
  func cursor() throws -> Int {
    try db.read { db in
      Int(try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key='cursor'") ?? "0") ?? 0
    }
  }
  func conflicts() throws -> [Conflict] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM conflicts").map { row in
        let server: Data? = row["server"]
        return Conflict(
          id: row["id"], local: try JSONDecoder().decode(Item.self, from: row["local"]),
          server: try server.map { try JSONDecoder().decode(Item.self, from: $0) })
      }
    }
  }
  func resolve(_ conflict: Conflict, keepLocal: Bool) throws {
    try db.write { db in
      try db.execute(sql: "DELETE FROM conflicts WHERE id=?", arguments: [conflict.id])
      var item = keepLocal ? conflict.local : (conflict.server ?? conflict.local)
      if item.kind == "tasks", let server = conflict.server {
        item = TaskAudit.merging(item, with: keepLocal ? server : conflict.local)
      }
      item.revision = conflict.server?.revision ?? 0
      if !keepLocal && conflict.server == nil { item.deleted = true }
      try Self.put(item, db: db)
      if keepLocal
        || (item.kind == "tasks" && item.body != conflict.server?.body && conflict.server != nil)
      {
        let m = Mutation(item)
        try db.execute(
          sql: "INSERT INTO outbox(id,operation,payload) VALUES(?,?,?)",
          arguments: [item.id, m.operationID, try JSONEncoder().encode(m)])
      }
    }
  }
  func globalSearch(_ query: String, limit: Int = 200) throws -> [WorkspaceSearchMatch] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    let limit = min(200, max(1, limit))
    let kinds = WorkspaceSearchIndex.kinds.map { "'" + $0 + "'" }.joined(separator: ",")
    return try db.read { db in
      var matches: [WorkspaceSearchMatch] = []
      if let expression = WorkspaceSearchIndex.expression(query) {
        matches = try Row.fetchAll(
          db,
          sql: """
            SELECT search.id, snippet(search,-1,'','',' … ',32) AS excerpt
            FROM search JOIN items ON items.id=search.id
            WHERE search MATCH ? AND items.kind IN (\(kinds))
            ORDER BY bm25(search,0,8,4,1) LIMIT ?
            """, arguments: [expression, limit]
        ).map {
          WorkspaceSearchMatch(id: $0["id"], excerpt: $0["excerpt"])
        }
      }
      guard matches.count < limit else { return matches }
      var seen = Set(matches.map(\.id))
      // Substring fallback covers phone suffixes and text inside words without decoding rich documents.
      let rows = try Row.fetchCursor(
        db,
        sql: """
          SELECT search.id, search.title, search.description, search.body
          FROM search JOIN items ON items.id=search.id WHERE items.kind IN (\(kinds))
          """)
      while let row = try rows.next(), matches.count < limit {
        let id: String = row["id"]
        guard !seen.contains(id) else { continue }
        let fields: [String] = [row["title"], row["description"], row["body"]]
        guard
          let field = fields.first(where: {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
          })
        else { continue }
        seen.insert(id)
        matches.append(
          WorkspaceSearchMatch(id: id, excerpt: WorkspaceSearchIndex.excerpt(field, query: query)))
      }
      return matches
    }
  }
  func search(_ query: String) throws -> Set<String> {
    let tokens = query.split(whereSeparator: { $0.isWhitespace }).map {
      "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }.joined(separator: " AND ")
    guard !tokens.isEmpty else { return [] }
    return try db.read { db in
      Set(
        try String.fetchAll(
          db, sql: "SELECT id FROM search WHERE search MATCH ?", arguments: [tokens]))
    }
  }
}
