# Worker setup

`hangar-worker` runs on each build Mac. It heartbeats to the server every 30 s, long-polls for jobs and runs them with Xcode. It runs as a launchd agent in the GUI session of a dedicated, unprivileged `hangar` user, for two reasons: code signing needs that user's login keychain, unlocked by a real login, and a build (which runs the repository's own scripts) must not be able to read your files or the server's data. The `hangar` user shares the Mac's Xcode and simulator runtimes; it gets no copy of either. The install command sets the user up for you. Why it is a user and not a VM or a container: [the worker isolation design](superpowers/specs/2026-11-05-worker-isolation-design.md).

Do these steps on every build Mac, as an administrator, in Terminal.

## Checklist

1. **Stop the Mac from sleeping** (sleep suspends the `hangar` session too):
   ```sh
   sudo pmset -a sleep 0 disksleep 0
   ```
2. **Install Xcode 27.2**, then, as an administrator (once per Mac; the runtimes are system-wide and shared with `hangar`):
   ```sh
   sudo xcodebuild -license accept
   xcodebuild -downloadPlatform iOS
   ```
   The install command runs `sudo xcodebuild -runFirstLaunch` when it is still needed.
3. **Install Homebrew**, then:
   ```sh
   brew install xcodegen rclone
   ```
   (From a checkout of this repository, `brew bundle --file scripts/worker/Brewfile` does the same.) `hangar` uses the Mac's Homebrew prefix in place; do not install a second Homebrew for it.
4. **Install the worker with one command.** In Hangar, open Machines and click **Add Mac**. The sheet shows a command and a pairing code. On the build Mac, as an administrator, open Terminal and run the command:
   ```sh
   curl -fsSL http://<tailnet-host>:8787/install | sh
   ```
   and type the code when asked. Then the script hands over to `hangar-worker isolate`, which does the rest:

   - asks for your password once (`sudo`; creating a user needs an administrator);
   - creates the `hangar` user: a standard account, not an administrator, shell `/bin/zsh`, home `/Users/hangar`, with a **generated** password. You never make one up. The password is shown once and saved in your login keychain as `app.hangar.worker-account`; to see it again:
     ```sh
     security find-generic-password -s app.hangar.worker-account -a hangar -w
     ```
     (or search Keychain Access for "Hangar build account"). Neither Hangar nor the worker stores or needs it. It reaches macOS on standard input, never in a command line;
   - copies `hangar-worker` to `/Users/hangar/.local/bin`, installs the configuration (mode 0600) and the launch agent for `hangar`, and sets `/Users/hangar` to mode 0700;
   - checks that `hangar` cannot read the server's `master.key` when the server runs on this Mac;
   - prints the one step macOS keeps for a person: **log in as `hangar` once** with fast user switching (the user menu in the menu bar, or Apple menu › Lock Screen › Switch User), click through the welcome screens, and switch back. Do not log out of `hangar`: builds run in that session, and the login is what unlocks its keychain after every reboot;
   - waits for that login, then confirms the agent runs as `hangar`, that the login keychain exists, and that Hangar sees the Mac heartbeat as `hangar`.

   The sheet shows the Mac as connected once its worker sends its first heartbeat. If you stop the script while it waits (Ctrl-C), log in as `hangar` and run the command again: every step is safe to repeat and it picks up where it stopped. The same steps without the curl command: `hangar-worker isolate` (`--dry-run` prints them without doing anything; `--reset-password` gives an existing `hangar` user a new generated password; `--no-wait` stops before the login).

   To build as yourself instead (a build can then read your files), add `HANGAR_AS_CURRENT_USER=1` after the pipe. Run as `hangar` itself, or as any standard (non-administrator) account, the script installs for that user and needs no `sudo`.

   Use the server's own address and port, `http://<tailnet-host>:8787` (the one the server listens on), not an HTTPS name from `tailscale serve` or another proxy: the script downloads the worker and enrolls through the address it was fetched from, always over plain `http://`, and the worker keeps that address in its configuration.

   Installing for the current user, the script downloads `hangar-worker` from the server into `~/.local/bin` (no `sudo`), enrolls the Mac with the code, which gives it its machine token, runs `hangar-worker setup` (the configuration goes to `~/Library/Application Support/Hangar/worker/config.json` with mode 0600), writes `~/Library/LaunchAgents/app.hangar.worker.plist`, loads it with `launchctl bootstrap gui/$(id -u)` and runs the doctor. The token travels from the server's answer to `hangar-worker setup` in the environment: it is never in a command line, on screen or in a log.

   A code is good for one Mac and 15 minutes; **Get a New Code** in the sheet makes another. After 10 wrong codes from one Mac within 10 minutes the server refuses that Mac's codes for the rest of those 10 minutes.

   Options go in the environment of `sh`, after the pipe, e.g. `curl -fsSL http://<tailnet-host>:8787/install | HANGAR_MACHINE_NAME=mini-2 sh`:

   | Variable | Default | |
   | --- | --- | --- |
   | `HANGAR_MACHINE_NAME` | the Mac's local host name (`scutil --get LocalHostName`) | How the Mac appears in Hangar. If the name is taken, the script stops and says so; the code stays valid |
   | `HANGAR_PAIRING_CODE` | asked for on the terminal | For unattended installs |
   | `HANGAR_AS_CURRENT_USER=1` | | Install for the user running the script, not for `hangar` |
   | `HANGAR_BIN_DIR` | `~/.local/bin` | Current-user installs only. Must be writable by you; the plist points at the binary there. The `hangar` user's is always `/Users/hangar/.local/bin`, which it owns, so the idle self-update can replace it |
   | `HANGAR_MAX_JOBS` | `1` | Builds this Mac runs at once |
   | `HANGAR_WORKER_CONFIG` | `hangar-worker`'s default | Another configuration file; the agent is then started with `--config` |
   | `HANGAR_NO_LAUNCHD=1` | | For testing: install for the current user; download, enroll and write the configuration only; no launchd agent, no doctor |

   The server must have `hangar-worker` next to `hangar-server` (install-server.sh puts it there); otherwise the sheet says so and the script stops with "the server has no hangar-worker to hand out". The command needs the server's tailnet address: if you opened Hangar on `localhost`, replace that in the command.

   **To update, run the command again** (the worker also updates itself when idle). As an administrator, it updates the `hangar` user's worker and restarts its agent. As the current user, the script installs the new binary and then runs `hangar-worker check`, which asks the server whether this Mac's token is still valid. If it is (and the configuration points at the same server), it skips the code, restarts the agent, runs the doctor and prints "Updated <name>". If the machine was removed in Hangar, it asks for a new code and enrolls the Mac again. If the server cannot be reached, it stops without enrolling anything. A configuration for a different server is replaced after a warning.

   `hangar-worker check [--config <file>]` exits 0 when the token is accepted (it prints the machine's name), 3 when the server refuses it, 4 when the server cannot be reached and 2 when the configuration cannot be read.

   The worker the server hands out is universal (Apple silicon and Intel). Before enrolling, the script checks that it can write the configuration, so a permissions problem never leaves a machine in Hangar without a worker.
5. **Install from source instead** (the old way, which also works without the server handing out a binary). Create the machine on the server, on any Mac on the tailnet (or with **Add Manually…** in the Add Mac sheet):
   ```sh
   hangar machines add <name>
   ```
   It prints the machine's token once. Then, logged in as `hangar` (create it in System Settings › Users & Groups, a standard account), from a checkout of this repository, enter the token without echo, so it reaches neither shell history nor the process list:
   ```sh
   read -rs HANGAR_WORKER_TOKEN; export HANGAR_WORKER_TOKEN
   scripts/worker/install-worker.sh --server http://<tailnet-host>:8787
   ```
   (If the variable is unset and you are at a terminal, the script prompts for the token itself.) `--token <token>` also works, but the token is then visible in `ps` for the whole release build and stays in your shell history.
   Pass `--bin-dir ~/.local/bin`: the default, `/usr/local/bin`, needs `sudo` and leaves a binary the idle self-update cannot replace. The script builds in release mode, installs `hangar-worker` into `/usr/local/bin` unless told otherwise (using `sudo` only if needed), runs `hangar-worker setup` (the configuration is written to `~/Library/Application Support/Hangar/worker/config.json` with mode 0600; the token is never printed), renders `~/Library/LaunchAgents/app.hangar.worker.plist` and loads it with `launchctl bootstrap gui/$(id -u)`. Run it again to upgrade. Logs go to `~/Library/Logs/Hangar/worker.log`.
   To install without `sudo`, add `--bin-dir ~/.local/bin` (any directory you own; it is created if missing and the launchd plist points at the binary there). `--render-only <file>` just writes the plist, for testing. The `INSTALL_DIR` environment variable is no longer read; use `--bin-dir`.
6. **Run the doctor** as `hangar` (the one-command install already printed a summary of it; its binary is in `~/.local/bin`):
   ```sh
   hangar-worker doctor
   ```
   Confirm `"canSignWithoutPrompt" : true`. If it is `false`: open Keychain Access as `hangar`, find the Apple Development private key, and under Access Control allow `codesign`. Until then the scheduler will not give this machine signing jobs.
7. **Check from the server** that the machine is online:
   ```sh
   hangar machines list
   ```
   It should show Xcode 27.2, `canSignWithoutPrompt: true`, and `tools` containing `xcodegen` and `brew`. The Machines page shows **Runs as** `hangar`; any other user gets a warning there and in the worker's log.

## Move an existing worker to the `hangar` user

A worker installed as your own user moves without a new pairing code: same machine in Hangar, same token, and its build cache (checkouts and DerivedData) moves too, so the next build is warm. Run the install command again as that administrator, or, with the worker already on your `PATH`:

```sh
hangar-worker isolate --dry-run   # what it would do
hangar-worker isolate
```

Run it when nothing important is building: it stops your user's agent, and a build in flight stops with it. It creates `hangar` if needed (as above), copies the worker and its configuration into that user with the data directory rewritten to `/Users/hangar/Library/Application Support/Hangar/worker`, moves `workspaces/` there (`mv` on one volume; a copy, then removal, across volumes), removes leftover `jobs/`, waits for the `hangar` login, and once Hangar sees the Mac heartbeat as `hangar` removes your user's launch agent and configuration. If that confirmation does not come, both stay, and the error says how to start the old agent again. It never copies your login keychain, `~/Library/Developer`, `~/Library/Caches` or `~/.gitconfig`: the first archive as `hangar` creates its own signing identity, so allow `codesign` once in Keychain Access as `hangar` if the doctor asks. It never moves or deletes the `hangar-worker` next to `hangar-server` (the file other Macs download) or one in `/usr/local/bin`.

When the server runs on the same Mac, it stays your user's; the worker becomes `hangar`. If `hangar` can read the server's `master.key`, the command stops before moving anything and prints the `chmod 700` to run on the server's data directory. **Use This Mac for Builds** on the setup page shows this command instead of installing the worker as the server's user.

## The Apple Development identity

You do not create the signing identity by hand. The first archive with the App Store Connect team API key (or, with an individual key, the Apple account signed in to Xcode) creates the Apple Development identity and its private key in the `hangar` user's login keychain. So `canSignWithoutPrompt` is `false` on a brand-new machine until that first archive has run; after it, run the doctor again and, if needed, do the Access Control step above.

## Team and individual API keys

With a team key (`HANGAR_ASC_ISSUER_ID` set), archive, export and the TestFlight upload pass `-authenticationKeyPath`, `-authenticationKeyID` and `-authenticationKeyIssuerID` to xcodebuild. xcodebuild does not accept individual keys, so with an individual key those flags are left out and `-allowProvisioningUpdates` uses the Apple account signed in to Xcode on the Mac; the job log says "No team API key; xcodebuild signs with the Xcode account on this Mac." Build numbers and TestFlight processing, groups and review still go through the App Store Connect API with the individual key. A job fails before checkout only when `HANGAR_ASC_KEY_ID` or `HANGAR_ASC_KEY_PATH` is missing.

## Secrets and xcodebuild

Variables marked secret are masked in every log line and are never passed to `xcodebuild archive` or `-exportArchive`, because xcodebuild records its environment in DerivedData logs and in the result bundle, which is uploaded as an artifact. The one exception is Swift package resolution: the separate `xcodebuild -resolvePackageDependencies` run before the archive gets `HANGAR_GITHUB_TOKEN` (and nothing else secret), so private packages on GitHub resolve. Hooks and post-actions still receive every variable. As-file variables are written under the job directory with mode 0600 and overwritten with zeros when the job ends.

## Crash recovery

When the worker starts it removes job directories left in `<data directory>/jobs/` by a previous crash, wiping each one's secrets first. The cached per-app checkouts are kept.
