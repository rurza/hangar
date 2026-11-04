# Worker setup

`hangar-worker` runs on each build Mac. It heartbeats to the server every 30 s, long-polls for jobs and runs them with Xcode. It runs as a launchd agent in the GUI session of a dedicated `hangar` user, because code signing needs that user's login keychain.

Do these steps on every build Mac.

## Checklist

1. **Create the `hangar` user.** Administrator rights are not required. Log in as it once so the home directory exists.
2. **Keep that user logged in.** Enable fast user switching (System Settings > Control Center) and leave `hangar` logged in at the login window or on a switched-out session. The agent is limited to the Aqua (GUI) session, so it only runs while `hangar` is logged in.
3. **Stop the Mac from sleeping:**
   ```sh
   sudo pmset -a sleep 0 disksleep 0
   ```
4. **Install Xcode 27.2**, then, as `hangar`:
   ```sh
   xcodebuild -runFirstLaunch
   sudo xcodebuild -license accept
   xcodebuild -downloadPlatform iOS
   ```
   If the App Store Connect key is an individual key (no issuer ID), also sign in to your Apple account in Xcode > Settings > Accounts as `hangar`: without a team key, xcodebuild signs and uploads with that account.
5. **Install Homebrew**, then:
   ```sh
   brew install xcodegen rclone
   ```
   (From a checkout of this repository, `brew bundle --file scripts/worker/Brewfile` does the same.)
6. **Install the worker with one command.** In Hangar, open Machines and click **Add Mac**. The sheet shows a command and a pairing code. On the build Mac, as `hangar`, open Terminal and run the command:
   ```sh
   curl -fsSL http://<tailnet-host>:8787/install | sh
   ```
   and type the code when asked. The sheet shows the Mac as connected once its worker sends its first heartbeat.

   The script downloads `hangar-worker` from the server into `~/.local/bin` (no `sudo`), enrolls the Mac with the code, which gives it its machine token, runs `hangar-worker setup` (the configuration goes to `~/Library/Application Support/Hangar/worker/config.json` with mode 0600), writes `~/Library/LaunchAgents/app.hangar.worker.plist`, loads it with `launchctl bootstrap gui/$(id -u)` and runs the doctor. The token travels from the server's answer to `hangar-worker setup` in the environment: it is never in a command line, on screen or in a log.

   A code is good for one Mac and 15 minutes; **Get a New Code** in the sheet makes another. After 10 wrong codes within 10 minutes the server refuses every code for the rest of those 10 minutes.

   Options go in the environment of `sh`, after the pipe, e.g. `curl -fsSL http://<tailnet-host>:8787/install | HANGAR_MACHINE_NAME=mini-2 sh`:

   | Variable | Default | |
   | --- | --- | --- |
   | `HANGAR_MACHINE_NAME` | the Mac's local host name (`scutil --get LocalHostName`) | How the Mac appears in Hangar. If the name is taken, the script stops and says so; the code stays valid |
   | `HANGAR_PAIRING_CODE` | asked for on the terminal | For unattended installs |
   | `HANGAR_BIN_DIR` | `~/.local/bin` | Must be writable by you; the plist points at the binary there |
   | `HANGAR_MAX_JOBS` | `1` | Builds this Mac runs at once |
   | `HANGAR_WORKER_CONFIG` | `hangar-worker`'s default | Another configuration file; the agent is then started with `--config` |
   | `HANGAR_NO_LAUNCHD=1` | | For testing: download, enroll and write the configuration only; no launchd agent, no doctor |

   The server must have `hangar-worker` next to `hangar-server` (install-server.sh puts it there); otherwise the sheet says so and the script stops with "the server has no hangar-worker to hand out". The command needs the server's tailnet address: if you opened Hangar on `localhost`, replace that in the command.

   To upgrade a worker later, remove the machine in Hangar and run the command again, or install from source (below).
7. **Install from source instead** (the old way, which also works without the server handing out a binary). Create the machine on the server, on any Mac on the tailnet (or with **Add Manually…** in the Add Mac sheet):
   ```sh
   hangar machines add <name>
   ```
   It prints the machine's token once. Then, as `hangar`, from a checkout of this repository, enter the token without echo, so it reaches neither shell history nor the process list:
   ```sh
   read -rs HANGAR_WORKER_TOKEN; export HANGAR_WORKER_TOKEN
   scripts/worker/install-worker.sh --server http://<tailnet-host>:8787
   ```
   (If the variable is unset and you are at a terminal, the script prompts for the token itself.) `--token <token>` also works, but the token is then visible in `ps` for the whole release build and stays in your shell history.
   The script builds in release mode, installs `hangar-worker` into `/usr/local/bin` (using `sudo` only if needed), runs `hangar-worker setup` (the configuration is written to `~/Library/Application Support/Hangar/worker/config.json` with mode 0600; the token is never printed), renders `~/Library/LaunchAgents/app.hangar.worker.plist` and loads it with `launchctl bootstrap gui/$(id -u)`. Run it again to upgrade. Logs go to `~/Library/Logs/Hangar/worker.log`.
   To install without `sudo`, add `--bin-dir ~/.local/bin` (any directory you own; it is created if missing and the launchd plist points at the binary there). `--render-only <file>` just writes the plist, for testing. The `INSTALL_DIR` environment variable is no longer read; use `--bin-dir`.
8. **Run the doctor** as `hangar` (the one-command install already printed a summary of it; its binary is in `~/.local/bin`):
   ```sh
   hangar-worker doctor
   ```
   Confirm `"canSignWithoutPrompt" : true`. If it is `false`: open Keychain Access as `hangar`, find the Apple Development private key, and under Access Control allow `codesign`. Until then the scheduler will not give this machine signing jobs.
9. **Check from the server** that the machine is online:
   ```sh
   hangar machines list
   ```
   It should show Xcode 27.2, `canSignWithoutPrompt: true`, and `tools` containing `xcodegen` and `brew`.

## The Apple Development identity

You do not create the signing identity by hand. The first archive with the App Store Connect team API key (or, with an individual key, the Apple account signed in to Xcode) creates the Apple Development identity and its private key in the `hangar` user's login keychain. So `canSignWithoutPrompt` is `false` on a brand-new machine until that first archive has run; after it, run the doctor again and, if needed, do the Access Control step above.

## Team and individual API keys

With a team key (`HANGAR_ASC_ISSUER_ID` set), archive, export and the TestFlight upload pass `-authenticationKeyPath`, `-authenticationKeyID` and `-authenticationKeyIssuerID` to xcodebuild. xcodebuild does not accept individual keys, so with an individual key those flags are left out and `-allowProvisioningUpdates` uses the Apple account signed in to Xcode on the Mac; the job log says "No team API key; xcodebuild signs with the Xcode account on this Mac." Build numbers and TestFlight processing, groups and review still go through the App Store Connect API with the individual key. A job fails before checkout only when `HANGAR_ASC_KEY_ID` or `HANGAR_ASC_KEY_PATH` is missing.

## Secrets and xcodebuild

Variables marked secret are masked in every log line and are never passed to `xcodebuild archive` or `-exportArchive`, because xcodebuild records its environment in DerivedData logs and in the result bundle, which is uploaded as an artifact. The one exception is Swift package resolution: the separate `xcodebuild -resolvePackageDependencies` run before the archive gets `HANGAR_GITHUB_TOKEN` (and nothing else secret), so private packages on GitHub resolve. Hooks and post-actions still receive every variable. As-file variables are written under the job directory with mode 0600 and overwritten with zeros when the job ends.

## Crash recovery

When the worker starts it removes job directories left in `<data directory>/jobs/` by a previous crash, wiping each one's secrets first. The cached per-app checkouts are kept.
