const std = @import("std");

const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

const LogStore = @This();

db: *sqlite.sqlite3,

pub const Entry = struct {
    created_at_unix_ms: i64,
    text: []u8,
};

pub fn init(allocator: std.mem.Allocator, models_dir: []const u8) !LogStore {
    std.debug.assert(models_dir.len > 0);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/transcript-log.sqlite3", .{models_dir});
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    var db: ?*sqlite.sqlite3 = null;
    const open_result = sqlite.sqlite3_open_v2(
        db_path_z.ptr,
        &db,
        sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_FULLMUTEX,
        null,
    );
    if (open_result != sqlite.SQLITE_OK) {
        if (db) |maybe_db| {
            _ = sqlite.sqlite3_close(maybe_db);
        }
        return error.SqliteOpenFailed;
    }
    std.debug.assert(db != null);

    const store = LogStore{ .db = db.? };
    try store.exec(
        \\CREATE TABLE IF NOT EXISTS transcript_log (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    created_at_unix_ms INTEGER NOT NULL,
        \\    text TEXT NOT NULL CHECK(length(text) > 0)
        \\);
    );
    try store.exec("CREATE INDEX IF NOT EXISTS idx_transcript_log_id_desc ON transcript_log(id DESC);");
    return store;
}

pub fn deinit(self: *LogStore) void {
    _ = sqlite.sqlite3_close(self.db);
}

pub fn appendTranscript(self: *LogStore, allocator: std.mem.Allocator, transcript: []const u8) !void {
    const normalized = std.mem.trim(u8, transcript, " \n\r\t");
    if (normalized.len == 0) {
        return;
    }

    const sql = "INSERT INTO transcript_log(created_at_unix_ms, text) VALUES(?, ?);";
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try self.prepare(sql, &stmt);
    defer _ = sqlite.sqlite3_finalize(stmt);
    std.debug.assert(stmt != null);

    const bind_time = sqlite.sqlite3_bind_int64(stmt, 1, std.time.milliTimestamp());
    if (bind_time != sqlite.SQLITE_OK) {
        return error.SqliteBindFailed;
    }

    const owned_text = try allocator.dupeZ(u8, normalized);
    defer allocator.free(owned_text);

    const bind_text = sqlite.sqlite3_bind_text(stmt, 2, owned_text.ptr, @intCast(normalized.len), null);
    if (bind_text != sqlite.SQLITE_OK) {
        return error.SqliteBindFailed;
    }

    const step_result = sqlite.sqlite3_step(stmt);
    if (step_result != sqlite.SQLITE_DONE) {
        return error.SqliteStepFailed;
    }
}

pub fn clear(self: *LogStore) !void {
    try self.exec("DELETE FROM transcript_log;");
}

pub fn readRecent(self: *LogStore, allocator: std.mem.Allocator, limit: usize) ![]Entry {
    const sql = "SELECT created_at_unix_ms, text FROM transcript_log ORDER BY id DESC LIMIT ?;";
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try self.prepare(sql, &stmt);
    defer _ = sqlite.sqlite3_finalize(stmt);
    std.debug.assert(stmt != null);

    const normalized_limit = @min(limit, 1_000);
    const bind_limit = sqlite.sqlite3_bind_int64(stmt, 1, @intCast(normalized_limit));
    if (bind_limit != sqlite.SQLITE_OK) {
        return error.SqliteBindFailed;
    }

    var rows: std.ArrayListUnmanaged(Entry) = .{};
    errdefer {
        for (rows.items) |entry| {
            allocator.free(entry.text);
        }
        rows.deinit(allocator);
    }

    while (true) {
        const step_result = sqlite.sqlite3_step(stmt);
        if (step_result == sqlite.SQLITE_DONE) break;
        if (step_result != sqlite.SQLITE_ROW) {
            return error.SqliteStepFailed;
        }

        const created_at = sqlite.sqlite3_column_int64(stmt, 0);
        const text_ptr = sqlite.sqlite3_column_text(stmt, 1);
        const text_len = sqlite.sqlite3_column_bytes(stmt, 1);
        if (text_ptr == null or text_len <= 0) {
            continue;
        }

        const text_slice = @as([*]const u8, @ptrCast(text_ptr.?))[0..@intCast(text_len)];
        const owned_text = try allocator.dupe(u8, text_slice);
        try rows.append(allocator, .{
            .created_at_unix_ms = created_at,
            .text = owned_text,
        });
    }

    return rows.toOwnedSlice(allocator);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| {
        allocator.free(entry.text);
    }
    allocator.free(entries);
}

fn exec(self: LogStore, sql: []const u8) !void {
    const result = sqlite.sqlite3_exec(self.db, sql.ptr, null, null, null);
    if (result != sqlite.SQLITE_OK) {
        return error.SqliteExecFailed;
    }
}

fn prepare(self: LogStore, sql: []const u8, stmt: *?*sqlite.sqlite3_stmt) !void {
    const result = sqlite.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), stmt, null);
    if (result != sqlite.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
}
