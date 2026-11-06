# Worker setup

`hangar-worker` runs on each build Mac, as the Mac's owner: a launch agent in their login session (`~/Library/LaunchAgents/app.hangar.worker.plist`), installed by the command in **Machines › Add Mac**. It heartbeats to the server every 30 s, long-polls for jobs and builds them in one of two ways:

- **VM builds** (the default on Apple silicon): each job runs in a **fresh macOS VM**, a clone of a prepared image thrown away when the job ends. The VM sees none of the Mac's files, cannot reach its services, the LAN or the tailnet, and never gets the machine token. This is how every new Mac should build.
- **Local builds**: each job runs directly on the Mac, as the owner, signing with the owner's login keychain. A build can read the owner's files. An Intel Mac always builds this way. See [Local builds](#local-builds).

## Add a new Mac

What VM builds need: Apple silicon, macOS at least as new as the VM image (26.6.2), Xcode, and about 105 GB free on one APFS volume (an external SSD works). Do this on the new Mac, logged in as the user the worker should run as (setting up VM builds needs an administrator's password).

1. **Install Tailscale** and log in to the tailnet the server is on.
2. **Install Xcode** from the App Store (or with `xcodes`) and open it once. Nothing else: no simulator platforms, no Homebrew. Jobs install what they need inside their VM.
3. **In Hangar, open Machines and click Add Mac.** On the new Mac, open Terminal and run the command the sheet shows, then type the pairing code:
   ```sh
   curl -fsSL http://<tailnet-host>:8787/install | sh
   ```
   The script first checks the Mac (Apple silicon, macOS, Xcode and its license, free space, Tailscale, the server) and prints a ✓/✗ list. It installs the worker into `~/.local/bin` and asks **How should <Mac> build?**: **1** in a fresh macOS VM per build (the default), **2** directly on this Mac, as you. For VM builds it enrolls the Mac **with its builds paused**, so it never builds on the host, starts the worker and runs `sudo ~/.local/bin/hangar-worker vm setup` in the same Terminal, which takes about 15 minutes (most of it a 26 GB download). For local builds it enrolls the Mac with builds on, and that is all.
4. **Watch the Mac's card on the Machines page.** It says **Not Taking Builds** (or **Builds Paused**) and lists what VM builds still need, with the command to run. When it shows its VM slot and Xcode image, click **Resume Builds**.
5. **Signing, once per server.** VM archives sign with Hangar's own Apple Development certificate: create it once in **Settings › Signing**. The card says whether there is one.

To use an external SSD for the VMs, or two VMs at once, install with `HANGAR_VM_SETUP=0` after the pipe and run the setup yourself, e.g. `sudo ~/.local/bin/hangar-worker vm setup --storage /Volumes/<SSD>/hangar-vm --slots 2`. The card always shows the right path.

**Use This Mac for Builds** on the setup page does the same for the Mac the server runs on, for the server's own user, without Terminal. There is no terminal to ask on, so on Apple silicon it picks VM builds: the Mac is enrolled paused, and the page shows the `sudo … vm setup` command to run in Terminal (the server never runs sudo). Resuming builds on its card instead makes it build locally, as the server's user, where a build can also read the server's data.

## `vm setup`

`sudo <path to hangar-worker> vm setup` does everything VM builds need, in one sudo session. It finds the worker through your own launch agent, the one the install command wrote. It checks the Mac first and stops, changing nothing, when something required is missing: Apple silicon, the virtualization entitlement, macOS against the image, Xcode, free space against the budget (the images still to make, a saved state per slot, one job's growth and the 40 GB floor). It reports the server and Tailscale too. Then:

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

The App Store replaces `/Applications/Xcode.app` in place. Running VM jobs are unaffected: each image has its own copy. Builds keep using the image's Xcode, and the Mac's card says "Xcode 27.3 on this Mac has no VM image yet" with the command that builds one: the same `vm setup`, which now only builds the image and restarts the worker. **Pause Builds** first and let a running build finish, since the worker restarts at the end. A workflow pinned to an older `xcode:` keeps using its image until you remove it: `~/.local/bin/hangar-worker vm image remove xcode-27.2`.

## How VM builds work

With VM builds on, a Mac runs **every** job in a fresh macOS VM and none on the host: a clone of a prepared image, restored from a saved state in a few seconds, thrown away when the job ends. In the VM the job runs as a standard user `builder` that owns an empty `/opt/homebrew`, so a `ci_post_clone.sh` can unpack Homebrew there and `brew install` without sudo (`curl -fsSL https://github.com/Homebrew/brew/tarball/main | tar xz --strip-components 1 -C /opt/homebrew`). The VM sees none of your files, cannot reach this Mac's services, the LAN or the tailnet (a pf filter), and never gets the machine token: it talks to the server through the worker with a token that works only for its own job. Why, and what was measured: [the VM builds design](superpowers/specs/2026-11-05-vm-builds-design.md).

A Mac with VM builds on but not ready (no network filter, no image, a worker without the virtualization entitlement) takes **no** jobs, rather than building on the host; its card on the Machines page says what is missing. A Mac without VM builds builds locally.

What it needs: Apple silicon, an up-to-date worker (the install scripts sign it with the `com.apple.security.virtualization` entitlement), and room on one APFS volume: about 26 GB for the vanilla macOS image, 6 GB more for an image with Xcode (plus 8 to 17 GB per simulator runtime, and 3 GB for the Metal toolchain if asked for), a few GB per slot's saved state, and up to `jobReserveGB` (25) per running job, above a floor of `floorGB` (40) that the worker never goes below. A Mac whose internal disk cannot hold that uses an external APFS SSD.

**What a job sees in its VM.** The same steps and `CI_*` variables as on the host, with the workspace in `/Volumes/workspace/hangar`, `HOMEBREW_NO_AUTO_UPDATE=1` set, and Xcode at `/Applications/Xcode.app`. The job log's first line says how the VM came up ("VM: restored slot 0's saved state in 4.5 s"). `tools:` in `.hangar.yml` is not checked on a VM Mac: a `ci_post_clone.sh` installs what it needs, as on Xcode Cloud. The workflow's `xcode:` is matched against the images.

**When things go wrong.** A job that runs longer than `vm.jobTimeoutMinutes` (default 120) is cancelled and its VM stopped. A cancelled job's VM gets a minute to report, then is stopped. A VM that stops or stops answering fails its job with the reason. The worker deletes every leftover clone when it starts, and a crashed worker's VMs end with it. When macOS on the Mac is updated, a saved state may no longer restore: the next job cold-boots (about 20 s more) and the slot is saved again afterwards.

**Other VM commands.** They run as the worker's user, which owns the storage: `~/.local/bin/hangar-worker vm …`. `vm status` prints the card's report as JSON, `vm image list` lists images and slot states, `vm smoke` boots a job's VM from slot 0, runs a command in it and deletes it, `vm slots prepare` saves the states again (stop the worker first), `vm disable` turns VM builds off (images and states stay), and `vm image remove <name>` deletes an image. `vm network install` and `vm network uninstall` need root (`sudo ~/.local/bin/hangar-worker vm network …`; `--dry-run` prints the rules and commands). The network filter is the pf anchor `com.apple/250.HangarVM` (`/etc/pf.anchors/app.hangar.vm`) and a LaunchDaemon, `app.hangar.pf`, that loads it at every boot; `/etc/pf.conf` is not changed. It lets this Mac open connections into the VMs (SSH) and lets the VMs use DNS and the internet; everything from a VM to this Mac, private ranges (10/8, 172.16/12, 192.168/16), the tailnet (100.64/10), link-local, multicast and IPv6 is dropped.

**The signing identity.** VM archives sign with the Hangar server's one Apple Development identity, which each archive's assignment carries into its VM; a VM never creates certificates of its own. In the VM it goes into a keychain made for that job, with a random password that stays in the guest worker's memory; the key is imported so it cannot be exported again, and the keychain goes with the clone. Create it once in Settings › Signing (or `hangar signing create`), or import a `.p12` (`hangar signing import <file.p12>`). VM archives wait until the server has one; tests do not need it. Only to make one worker use a different identity: `HANGAR_P12_PASSWORD=… hangar-worker vm identity import <file.p12>` as the worker's user; `vm identity remove` goes back to the server's.

**External storage by hand.** `vm setup --storage` does this; by hand: format the SSD as APFS, `sudo diskutil enableOwnership /Volumes/<SSD>`, then create the directory owned by the worker's user with mode 700. An external volume ignores ownership by default, which would let every user of the Mac read a running job's clone; the worker refuses such a volume. FileVault or an encrypted volume is recommended: a deleted clone is not scrubbed.

## Pause builds on a Mac

To keep a Mac free for your own work (the Mac that runs the server, say), turn builds off there: **Pause builds** on its card on the Machines page, or `hangar machines pause <name>`. The scheduler then gives it no new jobs; a build it is running finishes. Nothing is uninstalled and no administrator is needed: the worker keeps reporting, so the Mac stays online on the Machines page, and it still updates itself. Builds that only that Mac could run wait in the queue ("builds paused"), and the Deploy sheet says so before you deploy. **Resume builds** (or `hangar machines resume <name>`) turns it back on, and waiting builds start at once. A new Mac meant for VM builds is enrolled paused until they are ready (see [Add a new Mac](#add-a-new-mac)).

## Where builds happen

Checkouts, DerivedData, job folders and each job's `TMPDIR` go to the worker's work directory (mode 0700), which never has a space in its path: projects written for Xcode Cloud (`/Volumes/workspace/repository`) often use `$CI_PRIMARY_REPOSITORY_PATH` unquoted. By default it is `~/.hangar/worker` for the usual configuration under `~/Library/Application Support/Hangar/worker` (the data directory itself when its path has no spaces). Set another with `hangar-worker setup --work-dir <path>` or `"workDirectory"` in `config.json`. The first time a worker starts with a new work directory it moves the cached workspaces there (a rename, instant on the same volume), so the next build fetches instead of cloning; Xcode rebuilds what it keyed to the old path once.

On SIGTERM (`launchctl bootout`, a restart, an update) the worker stops asking for jobs, cancels a running build with the reason ("hangar-worker on <Mac> was stopped (SIGTERM) during archive"), cleans up and exits. Check the Machines page for running jobs before restarting a worker by hand: `launchctl kill SIGTERM gui/$(id -u)/app.hangar.worker` restarts it (launchd starts it again), `launchctl bootout gui/$(id -u)/app.hangar.worker` stops it until the next login. Its log is `~/Library/Logs/Hangar/worker.log`. The worker runs while you are logged in: after a reboot, log in (or turn on automatic login) for it to start.

## Local builds

A local Mac runs the repository's scripts on the Mac itself, as the owner, uses the Mac's Homebrew, and signs with the owner's login keychain, so a build can read the owner's files: the Machines page and the worker's log say so. Install with `HANGAR_VM=0` after the pipe (`curl … | HANGAR_VM=0 sh`), or answer **2** when the script asks; the Mac is enrolled with builds on and never asked about VMs. An Intel Mac always builds this way. To move a local Mac to VM builds later, run `sudo ~/.local/bin/hangar-worker vm setup` on it.

### Local-build checklist

1. **Stop the Mac from sleeping** (sleep stops builds):
   ```sh
   sudo pmset -a sleep 0 disksleep 0
   ```
2. **Install Xcode**, then:
   ```sh
   sudo xcodebuild -license accept
   xcodebuild -downloadPlatform iOS
   ```
   The install command runs `sudo xcodebuild -runFirstLaunch` when it is still needed.
3. **Install Homebrew**, then:
   ```sh
   brew install xcodegen rclone
   ```
   (From a checkout of this repository, `brew bundle --file scripts/worker/Brewfile` does the same.)
4. **Install the worker** with the command from **Add Mac**, as in [Add a new Mac](#add-a-new-mac), choosing local builds.
5. **Run the doctor**: `~/.local/bin/hangar-worker doctor`. Confirm `"canSignWithoutPrompt" : true`. If it cannot sign, open Keychain Access, find the Apple Development private key, and under Access Control allow `codesign`. Until then the scheduler gives this Mac no signing jobs.
6. **Check from the server** that the machine is online: `hangar machines list` shows its Xcode, `canSignWithoutPrompt: true`, and `tools` containing `xcodegen` and `brew`.

You do not create the signing identity by hand. The first archive with the App Store Connect team API key (or, with an individual key, the Xcode account) creates the Apple Development identity and its private key in the login keychain. The worker reports `canSignWithoutPrompt` `false` until it exists; after the first archive, run the doctor again and, if needed, do the Access Control step above.

## The install command

The script checks the downloaded `hangar-worker` against the SHA-256 the server wrote into it and stops with "SHA-256 mismatch" if they differ. It downloads it into `~/.local/bin` (no `sudo`), enrolls the Mac with the code, which gives it its machine token, runs `hangar-worker setup` (the configuration goes to `~/Library/Application Support/Hangar/worker/config.json` with mode 0600), writes `~/Library/LaunchAgents/app.hangar.worker.plist`, loads it with `launchctl bootstrap gui/$(id -u)` and runs the doctor. The token travels from the server's answer to `hangar-worker setup` in the environment: it is never in a command line, on screen or in a log. The sheet shows the Mac as connected once its worker sends its first heartbeat.

Use the server's own address and port, `http://<tailnet-host>:8787` (the one the server listens on), not an HTTPS name from `tailscale serve` or another proxy: the script downloads the worker and enrolls through the address it was fetched from, always over plain `http://`, and the worker keeps that address in its configuration.

A code is good for one Mac and 15 minutes; **Get a New Code** in the sheet makes another. After 10 wrong codes from one Mac within 10 minutes the server refuses that Mac's codes for the rest of those 10 minutes.

Options go in the environment of `sh`, after the pipe, e.g. `curl -fsSL http://<tailnet-host>:8787/install | HANGAR_MACHINE_NAME=mini-2 sh`:

| Variable | Default | |
| --- | --- | --- |
| `HANGAR_MACHINE_NAME` | the Mac's local host name (`scutil --get LocalHostName`) | How the Mac appears in Hangar. If the name is taken, the script stops and says so; the code stays valid |
| `HANGAR_PAIRING_CODE` | asked for on the terminal | For unattended installs |
| `HANGAR_VM` | asked on Apple silicon; `1` without a terminal | `1` builds in VMs, `0` builds locally (enrolled with builds on, no VM setup) |
| `HANGAR_VM_SETUP` | asked (yes when VM builds were picked at the question) | `1` runs `vm setup` after a new install without asking, `0` skips it and prints the command |
| `HANGAR_BIN_DIR` | `~/.local/bin` | Must be writable by you; the plist points at the binary there, so the idle self-update can replace it |
| `HANGAR_MAX_JOBS` | `1` | Builds this Mac runs at once |
| `HANGAR_WORKER_CONFIG` | `hangar-worker`'s default | Another configuration file; the agent is then started with `--config` |
| `HANGAR_NO_LAUNCHD=1` | | For testing: download, enroll and write the configuration only; no launchd agent, no doctor |

The server must have `hangar-worker` next to `hangar-server` (install-server.sh puts it there); otherwise the sheet says so and the script stops with "the server has no hangar-worker to hand out". The command needs the server's tailnet address: if you opened Hangar on `localhost`, replace that in the command.

**To update, run the command again** (the worker also updates itself when idle, never during a build). The script installs the new binary and runs `hangar-worker check`, which asks the server whether this Mac's token is still valid. If it is (and the configuration points at the same server), it skips the code and the build-mode question, restarts the agent (a build in flight is cancelled with the reason, see [Where builds happen](#where-builds-happen)), runs the doctor and prints "Updated <name>". If the machine was removed in Hangar, it asks for a new code and enrolls the Mac again. If the server cannot be reached, it stops without enrolling anything. A configuration for a different server is replaced after a warning.

`hangar-worker check [--config <file>]` exits 0 when the token is accepted (it prints the machine's name), 3 when the server refuses it, 4 when the server cannot be reached and 2 when the configuration cannot be read.

The worker the server hands out is universal (Apple silicon and Intel). Before enrolling, the script checks that it can write the configuration, so a permissions problem never leaves a machine in Hangar without a worker.

## Team and individual API keys

The App Store Connect key is a server setting (Settings › App Store Connect), never a job variable: the assignment carries it, and the worker writes its `.p8` only while the archive, test or export `xcodebuild` and each post-action run. With a team key (one with an issuer ID), archive, export and the TestFlight upload pass `-authenticationKeyPath`, `-authenticationKeyID` and `-authenticationKeyIssuerID` to xcodebuild. xcodebuild does not accept individual keys, so with an individual key those flags are left out and `-allowProvisioningUpdates` uses the Apple account signed in to Xcode on the Mac; the job log says "No team API key; xcodebuild signs with the Xcode account on this Mac." Build numbers and TestFlight processing, groups and review still go through the App Store Connect API with the individual key. An archive fails before checkout when the server has no key. Build phases and package plugins run as the worker's user while those steps run and can read the `.p8`: on a local Mac that exposure remains, and only VM builds keep the key away from the build.

**A VM has no Xcode account.** So with an individual key, archives do not go to a VM Mac: they wait with "needs a team App Store Connect key (with an issuer ID): a VM has no Xcode account", in the queue and in the Deploy sheet, and run on a local Mac whose owner is signed in to Xcode. Add the issuer ID in Settings to archive on VM Macs. Test jobs need no key and run there either way.

## Secrets and xcodebuild

Variables marked secret are masked in every log line and are never passed to `xcodebuild archive` or `-exportArchive`, because xcodebuild records its environment in DerivedData logs and in the result bundle, which is uploaded as an artifact. The one exception is Swift package resolution: the separate `xcodebuild -resolvePackageDependencies` run before the archive gets `HANGAR_GITHUB_TOKEN` (and nothing else secret), so private packages on GitHub resolve. Hooks and post-actions still receive every variable. As-file variables are written under the job directory with mode 0600 and overwritten with zeros when the job ends.

## Crash recovery

When the worker starts it removes job directories left in `<work directory>/jobs/` (and an older `<data directory>/jobs/`) by a previous crash, wiping each one's secrets first, and the job `TMPDIR`s left in `<work directory>/tmp/`. The cached per-app checkouts are kept.
