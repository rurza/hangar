import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE apps (
                    id TEXT PRIMARY KEY,
                    slug TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    repo_url TEXT NOT NULL,
                    app_store_connect_app_id TEXT NOT NULL,
                    icon_url TEXT,
                    created_at DOUBLE NOT NULL
                );

                -- scope is 'global' or 'app'; app_id is '' for global (NULL would defeat the UNIQUE constraint).
                CREATE TABLE variables (
                    scope TEXT NOT NULL,
                    app_id TEXT NOT NULL DEFAULT '',
                    name TEXT NOT NULL,
                    ciphertext BLOB NOT NULL,
                    is_secret BOOLEAN NOT NULL,
                    as_file BOOLEAN NOT NULL,
                    updated_at DOUBLE NOT NULL,
                    UNIQUE (scope, app_id, name)
                );

                CREATE TABLE machines (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    token_hash TEXT NOT NULL UNIQUE,
                    max_concurrent_jobs INTEGER NOT NULL,
                    last_seen_at DOUBLE,
                    report_json TEXT,
                    created_at DOUBLE NOT NULL
                );

                CREATE TABLE builds (
                    id TEXT PRIMARY KEY,
                    app_id TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
                    workflow TEXT NOT NULL,
                    ref TEXT NOT NULL,
                    "commit" TEXT NOT NULL,
                    build_number INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    pinned_machine_id TEXT,
                    created_at DOUBLE NOT NULL,
                    finished_at DOUBLE
                );
                CREATE INDEX builds_app_created ON builds(app_id, created_at);

                CREATE TABLE jobs (
                    id TEXT PRIMARY KEY,
                    build_id TEXT NOT NULL REFERENCES builds(id) ON DELETE CASCADE,
                    action_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    machine_id TEXT,
                    queue_note TEXT,
                    failure_reason TEXT,
                    steps_json TEXT NOT NULL DEFAULT '[]',
                    outputs_json TEXT NOT NULL DEFAULT '{}',
                    created_at DOUBLE NOT NULL,
                    assigned_at DOUBLE,
                    started_at DOUBLE,
                    finished_at DOUBLE
                );
                CREATE INDEX jobs_status ON jobs(status);
                CREATE INDEX jobs_build ON jobs(build_id);

                -- No foreign key on build_id: numbers are reserved before the build row exists,
                -- and a failed build keeps (burns) its number.
                CREATE TABLE build_numbers (
                    app_id TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
                    number INTEGER NOT NULL,
                    build_id TEXT NOT NULL,
                    UNIQUE (app_id, number)
                );

                CREATE TABLE app_counters (
                    app_id TEXT PRIMARY KEY REFERENCES apps(id) ON DELETE CASCADE,
                    highest_assigned INTEGER NOT NULL
                );
                """)
        }
        // The workflow a build runs, as resolved at deploy time: the scheduler needs its Xcode and tools.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE builds ADD COLUMN workflow_json TEXT")
        }
        // An app's workflow can be defined in Hangar instead of a committed `.hangar.yml`.
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE app_workflows (
                    app_id TEXT PRIMARY KEY REFERENCES apps(id) ON DELETE CASCADE,
                    yaml TEXT NOT NULL,
                    updated_at DOUBLE NOT NULL
                );
                """)
        }
        // Small server-wide settings that are not variables (no job sees them), e.g. where the GitHub token came from.
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
                CREATE TABLE server_settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        }
        // Bearer tokens for agents (the MCP server): only the SHA-256 of each secret is stored.
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                CREATE TABLE api_tokens (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    scope TEXT NOT NULL,
                    prefix TEXT NOT NULL,
                    token_hash TEXT NOT NULL UNIQUE,
                    created_at DOUBLE NOT NULL,
                    last_used_at DOUBLE
                );
                """)
        }
        return migrator
    }
}
