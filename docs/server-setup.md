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

The script builds in release mode, copies `hangar-server`, `hangar-worker` (and `hangar`, when the build produces it) to `/usr/local/bin` (using `sudo` only if that directory is not writable), writes `~/Library/LaunchAgents/app.hangar.server.plist` and loads it with `launchctl bootstrap gui/$(id -u)`. The agent starts at login and is restarted if it exits. Run the script again to upgrade; it replaces the old instance. On SIGTERM or SIGINT (a launchd restart, the script's reload) the server stops at once: open event streams (the web UI's live updates) end, and anything still running is cancelled after 5 seconds.

To install without `sudo`, pick a directory you own: `scripts/server/install-server.sh --bin-dir ~/.local/bin`. The directory is created if missing, the launchd plist points at the binary there, and the web UI bundle goes beside it. (`--render-only <file>` just writes the plist, for testing.) The scripts no longer read an `INSTALL_DIR` environment variable; pass `--bin-dir` instead.

The web UI ships in `Hangar_HangarServer.bundle`, which the script copies next to `hangar-server` (replacing an older copy). If you copy the binary by hand, copy the bundle beside it too; without it the server still runs and the API works, but the UI pages answer `503` "Web UI not installed".

The `hangar-worker` next to `hangar-server` is what the server hands out to new build Macs (`curl -fsSL http://<server>:8787/install | sh`, see [worker setup](worker-setup.md)), so build Macs get the same version as the server. It is built universal (Apple silicon and Intel), so the server can hand it to either. Without it the one-command install answers `503` `worker_binary_missing` and the Add Mac sheet says to reinstall the server; the start-up log says whether it was found.

Open the web UI once the server runs: a new server shows **Set Up Hangar**, which finds what is already on this Mac — App Store Connect API keys (`AuthKey_<KEYID>.p8` in Apple's key folders and `~/Downloads`), the GitHub CLI's login (`gh`) — tests them before saving, and offers to build on the server's own Mac. Builds run in a fresh macOS VM per job, and the worker runs as a separate, unprivileged macOS user named `hangar` (see [worker-setup.md](worker-setup.md)), never as the user that runs the server and holds its `master.key`; the server does not `sudo`, so unless the server itself runs as `hangar`, the page shows the install command to run in Terminal as an administrator instead of a button (`POST /setup/local-worker` answers `409` `dedicated_user_required`). When the server does run as `hangar`, **Use This Mac for Builds** installs and enrolls the worker for that user, the way the install script does. It stays reachable from Settings (**Run Setup Again**). The one-click parts only work in a browser on the server's Mac (opening its tailnet name there counts); from another device the page offers the manual ways instead (choose the .p8, paste a token, Add Mac). Under launchd, macOS may ask once whether `hangar-server` may read your Downloads folder; until it is answered there, keys in Downloads are not found. A worker already set up on the Mac is never replaced: update it by running the install command again.

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

The CLI defaults to `http://localhost:8787`, so set this on every Mac, the server's included: the server binds its tailnet address, and only requests that arrive over the tailnet can be the owner's.

## Who can use it

The server answers its owner and API tokens, nobody else ([details](api.md#who-may-call-the-api)):

- **Your devices.** A browser or the CLI on a device signed in to Tailscale as the login that owns the server Mac's tailnet node needs nothing else; the server asks Tailscale who each device belongs to (`tailscale whois`). This covers the server Mac itself when it uses its tailnet address, for processes of the user the server runs as; other users there (a build running as `hangar`) need a token. Allow other logins in **Settings › Access**, or on the server Mac with `hangar-server access allow <login>…` (`hangar-server access show` prints the list, `reset` goes back to the node's login). A tagged server node has no owner of its own: set the logins.
- **Everything else needs an API token**: scripts on loopback, agents, and every caller while Tailscale is down. Agents get scoped tokens ([MCP access](mcp.md)). For your own CLI where Tailscale cannot vouch for it, make an owner token on the server Mac, as the user the server runs as:

  ```sh
  (umask 077; mkdir -p ~/.config/hangar; hangar-server token create my-cli --scope owner > ~/.config/hangar/token)
  ```

  The CLI reads `~/.config/hangar/token` (or `HANGAR_API_TOKEN_FILE`, or `HANGAR_API_TOKEN`). This works without the API, whether the server runs or not, and is the way back in if the owner logins are ever wrong.
- **New Macs** enroll with a pairing code from **Machines › Add Mac** (`curl … | sh`); enrolling needs no other credential. A Mac set up for VM builds gets VM jobs and the signing certificate only after you allow them on its card (**Allow VM Builds**, or `hangar machines allow-vm <name>`).

## Options

```sh
hangar-server run [--host <addr>] [--port 8787] [--data-dir <path>] [--retention-days 30] [--min-free-disk-gb 20] [--allowed-host <name> ...]
```

Each of host, port and data directory is taken from the flag first, then from the environment (`HANGAR_HOST`, `HANGAR_PORT`, `HANGAR_DATA_DIR`), then the default.

- Host default: the first IPv4 printed by `tailscale ip -4`. At login Tailscale may not be up yet, so the server retries for up to 60 seconds (every 2 s). If no address shows up, it exits with status 1 and prints `Tailscale address not found; start Tailscale or pass --host <address>` to stderr; launchd then restarts it. It never falls back to loopback silently. Pass `--host 127.0.0.1` explicitly for a local-only server.
- Port default: 8787.
- Data directory default: `~/Library/Application Support/Hangar/server`.
- Allowed host names: the server answers only requests whose `Host` names this server, so a web page that rebinds its own DNS name to your server's address gets `421 host_not_allowed` instead of the API or the UI. Always allowed: the bound address (any port); `localhost`, `127.0.0.1` and `[::1]` when bound to loopback or to `0.0.0.0`; this Mac's short host name (from `gethostname` and `scutil --get LocalHostName`); its MagicDNS name (`Self.DNSName` from `tailscale status --json`, read at start-up, or later from the owner check when Tailscale came up after the server) and that name's first label. Other `.ts.net` names, other devices' and other tailnets', are refused. To reach the server under another name (a DNS alias, a LAN address when bound to `0.0.0.0`), add it with `--allowed-host <name>` (repeatable) or `HANGAR_ALLOWED_HOSTS=name1,name2`; the two are combined. The server logs the full list at start-up (`allowed host names: ...`).

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
rm ~/Library/LaunchAgents/app.hangar.server.plist /usr/local/bin/hangar-server   # or the binary in your --bin-dir
```
