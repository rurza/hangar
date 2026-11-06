# Worker setup

`hangar-worker` runs on each build Mac. It heartbeats to the server every 30 s, long-polls for jobs and runs each one in a **fresh macOS VM**: a clone of a prepared image, thrown away when the job ends. The VM sees none of the Mac's files, cannot reach its services, the LAN or the tailnet, and never gets the machine token. This is how every new Mac should build.

The worker itself runs as a separate, unprivileged macOS user named `hangar`, as a LaunchDaemon: from boot, with nobody logged in. A worker run by the Mac's owner as a launch agent works the same way with VM builds on. Building on the Mac itself, without VMs, is the older setup; it still works, and is described under [Building on the host (legacy)](#building-on-the-host-legacy).

## Add a new Mac

What it needs: Apple silicon, macOS at least as new as the VM image (26.6.2), Xcode, and about 105 GB free on one APFS volume (an external SSD works). Do this on the new Mac, as an administrator.

1. **Install Tailscale** and log in to the tailnet the server is on.
2. **Install Xcode** from the App Store (or with `xcodes`) and open it once. Nothing else: no simulator platforms, no Homebrew. Jobs install what they need inside their VM.
3. **In Hangar, open Machines and click Add Mac.** On the new Mac, open Terminal and run the command the sheet shows, then type the pairing code:
   ```sh
   curl -fsSL http://<tailnet-host>:8787/install | sh
   ```
   The script first checks the Mac (Apple silicon, macOS, Xcode and its license, free space, Tailscale, the server) and prints a ✓/✗ list. It then installs the worker as the `hangar` user (macOS asks for your password once), enrolls the Mac **with its builds paused**, so it never builds on the host, and asks **Set up VM builds now?** Answer yes: it runs `sudo /Users/hangar/.local/bin/hangar-worker vm setup` in the same Terminal, which takes about 15 minutes (most of it a 26 GB download).
4. **Watch the Mac's card on the Machines page.** It says **Not Taking Builds** (or **Builds Paused**) and lists what VM builds still need, with the command to run. When it shows its VM slot and Xcode image, click **Resume Builds**.
5. **Signing, once per server.** VM archives sign with Hangar's own Apple Development certificate: create it once in **Settings › Signing**. The card says whether there is one.

To use an external SSD for the VMs, or two VMs at once, answer no in step 3 and run the setup yourself, e.g. `sudo /Users/hangar/.local/bin/hangar-worker vm setup --storage /Volumes/<SSD>/hangar-vm --slots 2`. For a worker run as yourself (installed with `HANGAR_AS_CURRENT_USER=1`), the binary is `~/.local/bin/hangar-worker`; the card always shows the right path.

## `vm setup`

`sudo <path to hangar-worker> vm setup` does everything VM builds need, in one sudo session. It finds the worker: the `hangar` user's LaunchDaemon, or else your own launch agent. It checks the Mac first and stops, changing nothing, when something required is missing: Apple silicon, the virtualization entitlement, macOS against the image, Xcode, free space against the budget (the images still to make, a saved state per slot, one job's growth and the 40 GB floor). It reports the server and Tailscale too. Then:

1. keeps the Mac awake (`pmset -a sleep 0 disksleep 0`);
2. accepts the Xcode license;
3. on an external volume, turns its ownership on (`diskutil enableOwnership`) and creates the storage directory for the worker's user, mode 0700;
4. turns VM builds on in the worker's configuration (`vm enable`, as the worker's user) and restarts the worker at once, so it stops taking host builds;
5. installs the network filter (see [How VM builds work](#how-vm-builds-work));
6. imports the vanilla macOS image (as the worker's user; about 5 minutes, 26 GB);
7. builds the job image from this Mac's Xcode (as the worker's user; about 10 minutes): `/Applications/Xcode.app`, else the newest `/Applications/Xcode*.app`, or `--xcode <path>`;
8. restarts the worker, which saves each slot's state when it starts.

Steps that are done already are skipped, so running it again finishes an interrupted setup, and on a Mac that is set up it changes nothing and leaves the worker running. `--dry-run` prints the checks and the steps without sudo. Options: `--storage`, `--slots`, `--cpus`, `--memory-gb`, `--xcode`, `--config`.

The image itself holds only what a job needs: macOS, the Xcode, a standard user `builder` that owns an empty `/opt/homebrew`, and the `/Volumes/workspace` volume. `vm image build --homebrew`, `--metal-toolchain` and `--platform iOS` (a simulator runtime, for test jobs) add more, when a project needs them.

## When Xcode is updated

The App Store replaces `/Applications/Xcode.app` in place. Running VM jobs are unaffected: each image has its own copy. Builds keep using the image's Xcode, and the Mac's card says "Xcode 27.3 on this Mac has no VM image yet" with the command that builds one: the same `vm setup`, which now only builds the image and restarts the worker. **Pause Builds** first and let a running build finish, since the worker restarts at the end. A workflow pinned to an older `xcode:` keeps using its image until you remove it: `sudo -u hangar -H /Users/hangar/.local/bin/hangar-worker vm image remove xcode-27.2`.

## How VM builds work

With VM builds on, a Mac runs **every** job in a fresh macOS VM and none on the host: a clone of a prepared image, restored from a saved state in a few seconds, thrown away when the job ends. In the VM the job runs as a standard user `builder` that owns an empty `/opt/homebrew`, so a `ci_post_clone.sh` can unpack Homebrew there and `brew install` without sudo (`curl -fsSL https://github.com/Homebrew/brew/tarball/main | tar xz --strip-components 1 -C /opt/homebrew`). The VM sees none of your files, cannot reach this Mac's services, the LAN or the tailnet (a pf filter), and never gets the machine token: it talks to the server through the worker with a token that works only for its own job. Why, and what was measured: [the VM builds design](superpowers/specs/2026-11-05-vm-builds-design.md).

A Mac with VM builds on but not ready (no network filter, no image, a worker without the virtualization entitlement) takes **no** jobs, rather than building on the host; its card on the Machines page says what is missing. A Mac without VM builds builds on the host as before.

What it needs: Apple silicon, an up-to-date worker (the install scripts sign it with the `com.apple.security.virtualization` entitlement), and room on one APFS volume: about 26 GB for the vanilla macOS image, 6 GB more for an image with Xcode (plus 8 to 17 GB per simulator runtime, and 3 GB for the Metal toolchain if asked for), a few GB per slot's saved state, and up to `jobReserveGB` (25) per running job, above a floor of `floorGB` (40) that the worker never goes below. A Mac whose internal disk cannot hold that uses an external APFS SSD.

**What a job sees in its VM.** The same steps and `CI_*` variables as on the host, with the workspace in `/Volumes/workspace/hangar`, `HOMEBREW_NO_AUTO_UPDATE=1` set, and Xcode at `/Applications/Xcode.app`. The job log's first line says how the VM came up ("VM: restored slot 0's saved state in 4.5 s"). `tools:` in `.hangar.yml` is not checked on a VM Mac: a `ci_post_clone.sh` installs what it needs, as on Xcode Cloud. The workflow's `xcode:` is matched against the images.

**When things go wrong.** A job that runs longer than `vm.jobTimeoutMinutes` (default 120) is cancelled and its VM stopped. A cancelled job's VM gets a minute to report, then is stopped. A VM that stops or stops answering fails its job with the reason. The worker deletes every leftover clone when it starts, and a crashed worker's VMs end with it. When macOS on the Mac is updated, a saved state may no longer restore: the next job cold-boots (about 20 s more) and the slot is saved again afterwards.

**Other VM commands.** They run as the worker's user, which owns the storage; for the `hangar` user, as an administrator: `sudo -u hangar -H /Users/hangar/.local/bin/hangar-worker vm …` (for a worker run as yourself, just `~/.local/bin/hangar-worker vm …`). `vm status` prints the card's report as JSON, `vm image list` lists images and slot states, `vm smoke` boots a job's VM from slot 0, runs a command in it and deletes it, `vm slots prepare` saves the states again (stop the worker first), `vm disable` turns VM builds off (images and states stay), and `vm image remove <name>` deletes an image. `vm network install` and `vm network uninstall` need root (`sudo /Users/hangar/.local/bin/hangar-worker vm network …`; `--dry-run` prints the rules and commands). The network filter is the pf anchor `com.apple/250.HangarVM` (`/etc/pf.anchors/app.hangar.vm`) and a LaunchDaemon, `app.hangar.pf`, that loads it at every boot; `/etc/pf.conf` is not changed. It lets this Mac open connections into the VMs (SSH) and lets the VMs use DNS and the internet; everything from a VM to this Mac, private ranges (10/8, 172.16/12, 192.168/16), the tailnet (100.64/10), link-local, multicast and IPv6 is dropped.

**The signing identity.** VM archives sign with the Hangar server's one Apple Development identity, which each archive's assignment carries into its VM; a VM never creates certificates of its own. Create it once in Settings › Signing (or `hangar signing create`), or import a `.p12` (`hangar signing import <file.p12>`). VM archives wait until the server has one; tests do not need it. Only to make one worker use a different identity: `HANGAR_P12_PASSWORD=… hangar-worker vm identity import <file.p12>` as the worker's user; `vm identity remove` goes back to the server's.

**External storage by hand.** `vm setup --storage` does this; by hand: format the SSD as APFS, `sudo diskutil enableOwnership /Volumes/<SSD>`, then create the directory owned by the worker's user with mode 700. An external volume ignores ownership by default, which would let every user of the Mac read a running job's clone; the worker refuses such a volume. FileVault or an encrypted volume is recommended: a deleted clone is not scrubbed.

## Pause builds on a Mac

To keep a Mac free for your own work (the Mac that runs the server, say), turn builds off there: **Pause builds** on its card on the Machines page, or `hangar machines pause <name>`. The scheduler then gives it no new jobs; a build it is running finishes. Nothing is uninstalled and no administrator is needed: the worker keeps reporting, so the Mac stays online on the Machines page, and it still updates itself. Builds that only that Mac could run wait in the queue ("builds paused"), and the Deploy sheet says so before you deploy. **Resume builds** (or `hangar machines resume <name>`) turns it back on, and waiting builds start at once. A new Mac meant for VM builds is enrolled paused until they are ready (see [Add a new Mac](#add-a-new-mac)).

## Where builds happen

Checkouts, DerivedData, job folders and each job's `TMPDIR` go to the worker's work directory, which never has a space in its path: projects written for Xcode Cloud (`/Volumes/workspace/repository`) often use `$CI_PRIMARY_REPOSITORY_PATH` unquoted. For the `hangar` user it is `/Users/hangar/.hangar/worker` (mode 0700, inside the 0700 home), named in its `config.json`. For a worker installed as another user it is by default `~/.hangar/worker` for the usual configuration under `~/Library/Application Support/Hangar/worker` (the data directory itself when its path has no spaces). Set another with `hangar-worker setup --work-dir <path>` or `"workDirectory"` in `config.json`; for `hangar`, keep it inside `/Users/hangar`. The first time a worker starts with a new work directory it moves the cached workspaces there (a rename, instant on the same volume), so the next build fetches instead of cloning; Xcode rebuilds what it keyed to the old path once.

On SIGTERM (`launchctl bootout`, a restart, an update run by an administrator) the worker stops asking for jobs, cancels a running build with the reason ("hangar-worker on <Mac> was stopped (SIGTERM) during archive"), cleans up and exits. Check the Machines page for running jobs before restarting a worker by hand. As an administrator, the `hangar` user's worker is restarted with `sudo launchctl kill SIGTERM system/app.hangar.worker` (launchd starts it again) and stopped until the next boot with `sudo launchctl bootout system/app.hangar.worker`. Its log is `/Users/hangar/Library/Logs/Hangar/worker.log` (`sudo tail` it).

## Building on the host (legacy)

Before VM builds, a Mac built on the host as the `hangar` user (or as its owner). It still works: install with `HANGAR_VM=0` after the pipe (`curl … | HANGAR_VM=0 sh`), and the Mac is enrolled with builds on and never asked about VMs; an Intel Mac always builds this way. A build then runs the repository's scripts on the Mac itself, uses the Mac's Homebrew, and the first archive creates a signing identity in `hangar`'s CI keychain. Why the `hangar` user and not a VM was the first answer: [the worker isolation design](superpowers/specs/2026-11-05-worker-isolation-design.md).

### Host-build checklist

1. **Stop the Mac from sleeping** (sleep stops builds):
   ```sh
   sudo pmset -a sleep 0 disksleep 0
   ```
2. **Install Xcode**, then, as an administrator (once per Mac; the runtimes are system-wide and shared with `hangar`):
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
   and type the code when asked. The script checks the downloaded `hangar-worker` against the SHA-256 the server wrote into it and stops with "SHA-256 mismatch" if they differ, whichever user it installs for. Then it hands over to `hangar-worker isolate`, which does the rest (the same for a VM Mac):

   - asks for your password once (`sudo`; creating a user needs an administrator);
   - creates the `hangar` user: a standard account, not an administrator, shell `/bin/zsh`, home `/Users/hangar`, with a **generated** password. You never make one up. The password is shown once and saved in your login keychain as `app.hangar.worker-account`; to see it again:
     ```sh
     security find-generic-password -s app.hangar.worker-account -a hangar -w
     ```
     (or search Keychain Access for "Hangar build account"). Nobody logs in with it: it is there for emergencies. Neither Hangar nor the worker stores or needs it. It reaches macOS on standard input, never in a command line;
   - copies `hangar-worker` to `/Users/hangar/.local/bin`, installs the configuration (mode 0600, work directory `/Users/hangar/.hangar/worker`) and sets `/Users/hangar` to mode 0700;
   - checks that `hangar` cannot read the server's `master.key` when the server runs on this Mac;
   - creates `hangar`'s CI keychain, `/Users/hangar/Library/Keychains/hangar-ci.keychain-db`, with a generated password it keeps in `/Users/hangar/Library/Application Support/Hangar/worker/keychain-password` (mode 0600, owner `hangar`);
   - installs the worker as a LaunchDaemon, `/Library/LaunchDaemons/app.hangar.worker.plist` (owner root, mode 0644, `UserName` `hangar`), and starts it with `launchctl bootstrap system`;
   - confirms the daemon runs as `hangar` and that Hangar sees the Mac heartbeat from it.

   The sheet shows the Mac as connected once its worker sends its first heartbeat. After a reboot the worker starts again by itself, before anyone logs in. If you stop the script (Ctrl-C), run the command again: every step is safe to repeat and it picks up where it stopped. The same steps without the curl command: `hangar-worker isolate` (`--dry-run` prints them without doing anything; `--reset-password` gives an existing `hangar` user a new generated password).

   To build as yourself instead (a build can then read your files), add `HANGAR_AS_CURRENT_USER=1` after the pipe. Run as any standard (non-administrator) account, the script installs for that user and needs no `sudo`. Run as `hangar` while its LaunchDaemon is loaded, it stops: a launch agent beside the daemon would be a second worker with the same token.

   Use the server's own address and port, `http://<tailnet-host>:8787` (the one the server listens on), not an HTTPS name from `tailscale serve` or another proxy: the script downloads the worker and enrolls through the address it was fetched from, always over plain `http://`, and the worker keeps that address in its configuration.

   Installing for the current user, the script downloads `hangar-worker` from the server into `~/.local/bin` (no `sudo`), enrolls the Mac with the code, which gives it its machine token, runs `hangar-worker setup` (the configuration goes to `~/Library/Application Support/Hangar/worker/config.json` with mode 0600), writes `~/Library/LaunchAgents/app.hangar.worker.plist`, loads it with `launchctl bootstrap gui/$(id -u)` and runs the doctor. The token travels from the server's answer to `hangar-worker setup` in the environment: it is never in a command line, on screen or in a log.

   A code is good for one Mac and 15 minutes; **Get a New Code** in the sheet makes another. After 10 wrong codes from one Mac within 10 minutes the server refuses that Mac's codes for the rest of those 10 minutes.

   Options go in the environment of `sh`, after the pipe, e.g. `curl -fsSL http://<tailnet-host>:8787/install | HANGAR_MACHINE_NAME=mini-2 sh`:

   | Variable | Default | |
   | --- | --- | --- |
   | `HANGAR_MACHINE_NAME` | the Mac's local host name (`scutil --get LocalHostName`) | How the Mac appears in Hangar. If the name is taken, the script stops and says so; the code stays valid |
   | `HANGAR_PAIRING_CODE` | asked for on the terminal | For unattended installs |
   | `HANGAR_AS_CURRENT_USER=1` | | Install for the user running the script, not for `hangar` |
   | `HANGAR_VM=0` | `1` on Apple silicon | Build on the host: enroll with builds on and skip VM setup |
   | `HANGAR_VM_SETUP` | asked | `1` runs `vm setup` after a new install without asking, `0` skips it and prints the command |
   | `HANGAR_BIN_DIR` | `~/.local/bin` | Current-user installs only. Must be writable by you; the plist points at the binary there. The `hangar` user's is always `/Users/hangar/.local/bin`, which it owns, so the idle self-update can replace it |
   | `HANGAR_MAX_JOBS` | `1` | Builds this Mac runs at once |
   | `HANGAR_WORKER_CONFIG` | `hangar-worker`'s default | Another configuration file; the agent is then started with `--config` |
   | `HANGAR_NO_LAUNCHD=1` | | For testing: install for the current user; download, enroll and write the configuration only; no launchd agent, no doctor |

   The server must have `hangar-worker` next to `hangar-server` (install-server.sh puts it there); otherwise the sheet says so and the script stops with "the server has no hangar-worker to hand out". The command needs the server's tailnet address: if you opened Hangar on `localhost`, replace that in the command.

   **To update, run the command again** (the worker also updates itself when idle, never during a build). As an administrator, it updates the `hangar` user's worker and restarts its LaunchDaemon with SIGTERM, so a build in flight is cancelled with the reason (see [Where builds happen](#where-builds-happen)). As the current user, the script installs the new binary and then runs `hangar-worker check`, which asks the server whether this Mac's token is still valid. If it is (and the configuration points at the same server), it skips the code, restarts the agent, runs the doctor and prints "Updated <name>". If the machine was removed in Hangar, it asks for a new code and enrolls the Mac again. If the server cannot be reached, it stops without enrolling anything. A configuration for a different server is replaced after a warning.

   `hangar-worker check [--config <file>]` exits 0 when the token is accepted (it prints the machine's name), 3 when the server refuses it, 4 when the server cannot be reached and 2 when the configuration cannot be read.

   The worker the server hands out is universal (Apple silicon and Intel). Before enrolling, the script checks that it can write the configuration, so a permissions problem never leaves a machine in Hangar without a worker.
5. **Run the doctor** as `hangar`, from an administrator's Terminal:
   ```sh
   sudo -u hangar -H /Users/hangar/.local/bin/hangar-worker doctor
   ```
   Confirm `"canSignWithoutPrompt" : true` and `"headless" : true`. If it cannot sign, `keychainProblem` says why ("the CI keychain does not unlock with its stored password; run hangar-worker isolate again"), and the Machines page shows the same. Until then the scheduler gives this machine no jobs. For a worker installed as yourself (`HANGAR_AS_CURRENT_USER=1`), run `hangar-worker doctor`; if it cannot sign, open Keychain Access, find the Apple Development private key, and under Access Control allow `codesign`.
6. **Check from the server** that the machine is online:
   ```sh
   hangar machines list
   ```
   It should show its Xcode, `canSignWithoutPrompt: true`, and `tools` containing `xcodegen` and `brew`. The Machines page shows **Runs as** `hangar`; any other user gets a warning there and in the worker's log.

### Move an existing worker to the `hangar` user

A worker installed as your own user moves without a new pairing code: same machine in Hangar, same token, and its build cache (checkouts and DerivedData) moves too, so the next build fetches instead of cloning. Run the install command again as that administrator, or, with the worker already on your `PATH`:

```sh
hangar-worker isolate --dry-run   # what it would do
hangar-worker isolate
```

Run it when nothing important is building: it stops your user's agent, and a build in flight is cancelled with it ("stopped (SIGTERM)"). It creates `hangar` if needed (as above), copies the worker and its configuration into that user with the data directory rewritten to `/Users/hangar/Library/Application Support/Hangar/worker` and the work directory to `/Users/hangar/.hangar/worker`, and moves each app's workspace from your work directory (`~/.hangar/worker/workspaces`, and from the data directory's `workspaces/` if an older worker left one there) into `/Users/hangar/.hangar/worker/workspaces` (`mv` on one volume; a copy, then removal, across volumes). An app `hangar` already has keeps its copy. As when the work directory moves within one user, the parts of DerivedData that record the old path are dropped (`DerivedData/Build`, and `workspace-state.json`, `artifacts` and `checkouts` under `SourcePackages`); the package mirrors in `SourcePackages/repositories` are kept, and Xcode rebuilds the rest once. Everything moved is given to `hangar`. It removes leftover `jobs/` and `tmp/` and your emptied `~/.hangar/worker`, creates the CI keychain, starts the LaunchDaemon, and once Hangar sees the Mac heartbeat from it removes your user's launch agent and configuration. If that confirmation does not come, both stay, and the error says how to start the old agent again. It never copies your login keychain, `~/Library/Developer`, `~/Library/Caches` or `~/.gitconfig`: the first archive as `hangar` creates its own signing identity in the CI keychain. It never moves or deletes the `hangar-worker` next to `hangar-server` (the file other Macs download) or one in `/usr/local/bin`.

When the server runs on the same Mac, it stays your user's; the worker becomes `hangar`. If `hangar` can read the server's `master.key`, the command stops before moving anything and prints the `chmod 700` to run on the server's data directory. **Use This Mac for Builds** on the setup page shows this command instead of installing the worker as the server's user.

### The Apple Development identity

You do not create the signing identity by hand. The first archive with the App Store Connect team API key creates the Apple Development identity and its private key in the worker's default keychain: the CI keychain for `hangar`, the login keychain for a worker installed as yourself (where an individual key's Xcode account can create it too). A `hangar` worker whose CI keychain is ready counts as able to sign before that first archive, so it gets one. A worker installed as yourself reports `canSignWithoutPrompt` `false` until the identity exists; after the first archive, run the doctor again and, if needed, do the Access Control step above.

### Signing without a login

The `hangar` worker runs before anyone logs in, so no login keychain is unlocked for it, and there is nobody to click "Always Allow" when codesign asks for a key. It uses its own keychain instead:

- `isolate` creates `/Users/hangar/Library/Keychains/hangar-ci.keychain-db` as `hangar`, with a generated password in `/Users/hangar/Library/Application Support/Hangar/worker/keychain-password` (mode 0600, inside the 0700 home), and turns off its automatic locking. The password reaches `security` on standard input only: never a command line, a log or the server.
- Before every job, and on every heartbeat, the worker unlocks the keychain and keeps it the default keychain and first on `hangar`'s search list (where xcodebuild puts a new signing identity and where codesign looks for one). After a reboot the first heartbeat unlocks it.
- After the archive, the export and a test (each runs xcodebuild with `-allowProvisioningUpdates`, which can add a key), whether the step succeeded or not, the worker runs `security set-key-partition-list -S apple-tool:,apple:,codesign:` on the keychain, so codesign, productbuild and Xcode use every key in it without a prompt.
- The doctor reports `headless: true`, and instead of the Keychain Access check it checks that the keychain exists, unlocks with the stored password and is the default, and, once it holds an Apple Development identity, that codesign signs with it. A problem is reported as `keychainProblem`, shown on the Machines page; `hangar-worker isolate` again replaces a keychain that does not unlock (the next archive creates the identity again).

The keychain holds only Hangar's signing identity, never yours. Why keeping its password on disk is acceptable: [the worker isolation design](superpowers/specs/2026-11-05-worker-isolation-design.md#revised-launchdaemon-and-the-ci-keychain).

### Team and individual API keys

The App Store Connect key is a server setting (Settings › App Store Connect), never a job variable: the assignment carries it, and the worker writes its `.p8` only while the archive, test or export `xcodebuild` and each post-action run. With a team key (one with an issuer ID), archive, export and the TestFlight upload pass `-authenticationKeyPath`, `-authenticationKeyID` and `-authenticationKeyIssuerID` to xcodebuild. xcodebuild does not accept individual keys, so with an individual key those flags are left out and `-allowProvisioningUpdates` uses the Apple account signed in to Xcode on the Mac; the job log says "No team API key; xcodebuild signs with the Xcode account on this Mac." Build numbers and TestFlight processing, groups and review still go through the App Store Connect API with the individual key. An archive fails before checkout when the server has no key. Build phases and package plugins run as the worker's user while those steps run and can read the `.p8`: on a host Mac that exposure remains, and only VM builds keep the key away from the build.

**The `hangar` worker needs a team key to sign.** It has no Xcode account: an account's credentials live in a login keychain, and nothing logs in as `hangar`. So with an individual key, archives do not go to a `hangar` Mac: they wait with "needs a team App Store Connect key (with an issuer ID): this Mac's worker runs without an Xcode account", in the queue and in the Deploy sheet, and run on a Mac whose worker runs as a logged-in user with an Xcode account. Add the issuer ID in Settings to sign on `hangar` Macs. Test jobs need no key and run there either way.

## Secrets and xcodebuild

Variables marked secret are masked in every log line and are never passed to `xcodebuild archive` or `-exportArchive`, because xcodebuild records its environment in DerivedData logs and in the result bundle, which is uploaded as an artifact. The one exception is Swift package resolution: the separate `xcodebuild -resolvePackageDependencies` run before the archive gets `HANGAR_GITHUB_TOKEN` (and nothing else secret), so private packages on GitHub resolve. Hooks and post-actions still receive every variable. As-file variables are written under the job directory with mode 0600 and overwritten with zeros when the job ends.

## Crash recovery

When the worker starts it removes job directories left in `<work directory>/jobs/` (and an older `<data directory>/jobs/`) by a previous crash, wiping each one's secrets first, and the job `TMPDIR`s left in `<work directory>/tmp/`. The cached per-app checkouts are kept.
