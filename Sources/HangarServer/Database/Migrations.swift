import Foundation
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
        // Who ran a job (machine name, worker build, Xcode), as JSON; NULL until a machine starts it.
        migrator.registerMigration("v6") { db in
            try db.execute(sql: "ALTER TABLE jobs ADD COLUMN run_info_json TEXT")
        }
        // A paused machine takes no new jobs (its owner turned builds off on that Mac); 0 for every existing one.
        migrator.registerMigration("v7") { db in
            try db.execute(sql: "ALTER TABLE machines ADD COLUMN paused INTEGER NOT NULL DEFAULT 0")
        }
        // One-job tokens a VM uses instead of its machine's token (VM builds design): only the SHA-256 of each is
        // stored. They go with their job, and with the machine they were issued to.
        migrator.registerMigration("v8") { db in
            try db.execute(sql: """
                CREATE TABLE job_tokens (
                    token_hash TEXT PRIMARY KEY,
                    job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
                    machine_id TEXT NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
                    created_at DOUBLE NOT NULL
                );
                CREATE INDEX job_tokens_job ON job_tokens(job_id);
                """)
        }
        // Variable scopes (variable scopes design): groups of variables that apps link, and app variables limited
        // to some workflows. `variables` is rebuilt because its UNIQUE constraint changes: one name may now exist
        // once per set of workflows. `owner_id` replaces `app_id` ('' global, else the app's or the group's id);
        // `workflows` is '' for all workflows, else a sorted JSON array of names. Existing rows get '': the same
        // behaviour as before.
        migrator.registerMigration("v9") { db in
            try db.execute(sql: """
                CREATE TABLE variable_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    created_at DOUBLE NOT NULL
                );

                CREATE TABLE app_variable_groups (
                    app_id TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
                    group_id TEXT NOT NULL REFERENCES variable_groups(id) ON DELETE CASCADE,
                    workflows TEXT NOT NULL DEFAULT '',
                    position INTEGER NOT NULL,
                    PRIMARY KEY (app_id, group_id)
                );

                CREATE TABLE variables_v9 (
                    id TEXT PRIMARY KEY,
                    scope TEXT NOT NULL,
                    owner_id TEXT NOT NULL DEFAULT '',
                    name TEXT NOT NULL,
                    workflows TEXT NOT NULL DEFAULT '',
                    ciphertext BLOB NOT NULL,
                    is_secret BOOLEAN NOT NULL,
                    as_file BOOLEAN NOT NULL,
                    updated_at DOUBLE NOT NULL,
                    UNIQUE (scope, owner_id, name, workflows)
                );
                """)
            let rows = try Row.fetchAll(
                db, sql: "SELECT scope, app_id, name, ciphertext, is_secret, as_file, updated_at FROM variables")
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO variables_v9 (id, scope, owner_id, name, workflows, ciphertext, is_secret, as_file, updated_at)
                        VALUES (?, ?, ?, ?, '', ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString, row["scope"], row["app_id"], row["name"], row["ciphertext"] as Data,
                        row["is_secret"], row["as_file"], row["updated_at"],
                    ])
            }
            try db.execute(sql: """
                DROP TABLE variables;
                ALTER TABLE variables_v9 RENAME TO variables;
                CREATE INDEX variables_owner ON variables(scope, owner_id);
                """)
        }
        // The server's one Apple Development identity for VM archives (VM builds design, *Signing*): the `.p12` and its
        // password sealed with the master key, as variables are, and what the certificate says about itself.
        // `signing_certificate_creations` records every certificate Hangar asked App Store Connect for, for the
        // 24-hour guard; it outlives the identity.
        migrator.registerMigration("v10") { db in
            try db.execute(sql: """
                CREATE TABLE signing_identity (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    sealed_p12 BLOB NOT NULL,
                    sealed_password BLOB NOT NULL,
                    name TEXT NOT NULL,
                    team_id TEXT,
                    serial_number TEXT NOT NULL,
                    expires_at DOUBLE NOT NULL,
                    created_at DOUBLE NOT NULL,
                    origin TEXT NOT NULL,
                    asc_certificate_id TEXT
                );

                CREATE TABLE signing_certificate_creations (
                    id TEXT PRIMARY KEY,
                    started_at DOUBLE NOT NULL,
                    asc_certificate_id TEXT
                );
                """)
        }
        // VM builds become the owner's decision per machine (security review H1): a heartbeat's `vm` section no longer
        // grants VM jobs or the signing identity. Machines whose latest report has `vm` keep building in VMs.
        migrator.registerMigration("v11-machine-vm-builds") { db in
            try db.execute(sql: """
                ALTER TABLE machines ADD COLUMN vm_builds BOOLEAN NOT NULL DEFAULT 0;
                UPDATE machines SET vm_builds = 1 WHERE json_extract(report_json, '$.vm') IS NOT NULL;
                """)
        }
        return migrator
    }
}
