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
5. **Install Homebrew**, then from a checkout of this repository:
   ```sh
   brew bundle --file scripts/worker/Brewfile
   ```
   This installs `xcodegen` and `rclone`.
6. **Create the machine on the server.** On any Mac on the tailnet:
   ```sh
   hangar machines add <name>
   ```
   It prints the machine's token once.
7. **Install the worker**, as `hangar`, from a checkout of this repository. Enter the token without echo, so it reaches neither shell history nor the process list:
   ```sh
   read -rs HANGAR_WORKER_TOKEN; export HANGAR_WORKER_TOKEN
   scripts/worker/install-worker.sh --server http://<tailnet-host>:8787
   ```
   (If the variable is unset and you are at a terminal, the script prompts for the token itself.) `--token <token>` also works, but the token is then visible in `ps` for the whole release build and stays in your shell history.
   The script builds in release mode, installs `hangar-worker` into `/usr/local/bin` (using `sudo` only if needed), runs `hangar-worker setup` (the configuration is written to `~/Library/Application Support/Hangar/worker/config.json` with mode 0600; the token is never printed), renders `~/Library/LaunchAgents/app.hangar.worker.plist` and loads it with `launchctl bootstrap gui/$(id -u)`. Run it again to upgrade. Logs go to `~/Library/Logs/Hangar/worker.log`.
8. **Run the doctor** as `hangar`:
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

You do not create the signing identity by hand. The first archive with the App Store Connect API key creates the Apple Development identity and its private key in the `hangar` user's login keychain. So `canSignWithoutPrompt` is `false` on a brand-new machine until that first archive has run; after it, run the doctor again and, if needed, do the Access Control step above.

## Secrets and xcodebuild

Variables marked secret are masked in every log line and are never passed to `xcodebuild` (ruling R19): xcodebuild records its environment in DerivedData logs and the result bundle, which is uploaded as an artifact. Hooks and post-actions still receive them. As-file variables are written under the job directory with mode 0600 and overwritten with zeros when the job ends.

## Crash recovery

When the worker starts it removes job directories left in `<data directory>/jobs/` by a previous crash, wiping each one's secrets first. The cached per-app checkouts are kept.
