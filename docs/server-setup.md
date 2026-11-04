# Server setup

`hangar-server` is the control plane: it stores apps, builds and secrets, hands jobs to workers and serves the API the `hangar` CLI talks to. It runs on one always-on Mac and binds the Tailscale interface, so only devices on your tailnet can reach it.

## Requirements

- macOS 15 or later with the Swift toolchain (Xcode) installed.
- [Tailscale](https://tailscale.com) installed and logged in on the server Mac.
- A GitHub token with read access to your repositories, stored later as the `HANGAR_GITHUB_TOKEN` global variable.

## Install

From a checkout of this repository on the server Mac:

```sh
scripts/server/install-server.sh
```

The script builds in release mode, copies `hangar-server` (and `hangar`, when the build produces it) to `/usr/local/bin` (using `sudo` only if that directory is not writable), writes `~/Library/LaunchAgents/app.hangar.server.plist` and loads it with `launchctl bootstrap gui/$(id -u)`. The agent starts at login and is restarted if it exits. Run the script again to upgrade; it replaces the old instance.

The web UI ships in `Hangar_HangarServer.bundle`, which the script copies next to `hangar-server` (replacing an older copy). If you copy the binary by hand, copy the bundle beside it too; without it the server still runs and the API works, but the UI pages answer `503` "Web UI not installed".

Logs go to `~/Library/Logs/Hangar/server.log`.

Check that it is up, from any device on the tailnet:

```sh
curl http://<tailnet-host>:8787/api/v1/health
```

It answers `{"ok":true,...}`. The server is not reachable from outside the tailnet.

Point the CLI at it:

```sh
export HANGAR_SERVER=http://<tailnet-host>:8787
```

The CLI defaults to `http://localhost:8787`, so set this on every machine other than the server.

## Options

```sh
hangar-server run [--host <addr>] [--port 8787] [--data-dir <path>] [--retention-days 30] [--min-free-disk-gb 20]
```

Each of host, port and data directory is taken from the flag first, then from the environment (`HANGAR_HOST`, `HANGAR_PORT`, `HANGAR_DATA_DIR`), then the default.

- Host default: the first IPv4 printed by `tailscale ip -4`. At login Tailscale may not be up yet, so the server retries for up to 60 seconds (every 2 s). If no address shows up, it exits with status 1 and prints `Tailscale address not found; start Tailscale or pass --host <address>` to stderr; launchd then restarts it. It never falls back to loopback silently. Pass `--host 127.0.0.1` explicitly for a local-only server.
- Port default: 8787.
- Data directory default: `~/Library/Application Support/Hangar/server`.

To change options for the launchd agent, edit `ProgramArguments` or add an `EnvironmentVariables` dictionary in `~/Library/LaunchAgents/app.hangar.server.plist`, then reload it:

```sh
launchctl bootout gui/$(id -u)/app.hangar.server
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/app.hangar.server.plist
```

The installer overwrites the plist, so keep such changes in mind when upgrading.

## Data directory

```
hangar.sqlite          apps, builds, jobs, machines, encrypted variables
master.key             the key that encrypts variables in hangar.sqlite
jobs/<jobID>/          log.jsonl and artifacts/ of each job
```

Logs and artifacts of builds finished more than 30 days ago (`--retention-days`) are deleted hourly. Build history in the database is kept.

## Backups

Back up `hangar.sqlite` and `master.key` together. The database is useless without the key: secrets cannot be decrypted. The database runs in WAL mode, so copy it with `sqlite3 hangar.sqlite ".backup <target>"` while the server runs, or stop the agent first. `jobs/` is disposable.

## Master key rotation

Rotation is not supported in Phase 1. If you need a new key, stop the server, move `master.key` away, start the server (it creates a new key) and enter every secret again. Stored secrets encrypted with the old key cannot be read with the new one. Losing `master.key` has the same effect.

## Stopping and removing

```sh
launchctl bootout gui/$(id -u)/app.hangar.server
rm ~/Library/LaunchAgents/app.hangar.server.plist /usr/local/bin/hangar-server
```
