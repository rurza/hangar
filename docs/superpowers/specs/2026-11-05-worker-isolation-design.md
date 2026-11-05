# Worker isolation

Date: 2026-11-05
Status: implemented on branch `worker-isolation` (from `workflow-editor` at `9615a07`); not yet verified on a
real Mac. Revised the same day: setup is automated (a generated password kept in the administrator's keychain,
`hangar-worker isolate` instead of a shell migration script). Where this text and the first draft differ, this
text is the decision. Revised again for 0.9.0 (branch `worker-daemon`): the worker is a LaunchDaemon with its own
CI keychain, and nobody logs in as `hangar`. Paragraphs marked *(revised: LaunchDaemon)*, and the section *Revised:
LaunchDaemon and the CI keychain*, replace what earlier paragraphs say about the graphical login and the login
keychain.

## Intent

A Hangar worker checks out the operator's repos and runs `xcodebuild`, `codesign`
and the TestFlight upload on a Mac the operator owns. Those repos are source the
worker compiles and runs. The worker must not do that as the person sitting at
the Mac, and it must not do it as the user that holds the server's data.

The boundary is a separate, unprivileged macOS user on each build Mac. The user
shares the Xcode and the simulator runtimes already installed on that Mac. It
does not get its own copy of macOS or of Xcode. Performance stays that of a
native run, and the extra disk is a home directory and a build cache, not
another toolchain.

This fills in the dedicated `hangar` user named in the 2026-11-04 design and in
`docs/worker-setup.md`. That earlier text says which user runs the builds. It
does not say what the user shares, what another user on the same Mac can read,
how the idle self-update keeps working, or how a worker already enrolled as the
console user moves over. Those are the decisions below.

## Goals

1. **A separate user, per machine.** Every job on a build Mac runs as an
   unprivileged user named `hangar` *(revised: LaunchDaemon: from a LaunchDaemon, not
   in a GUI session)*. The interactive
   user and, on a Mac that also runs the server, the server's user are different
   accounts.
2. **Performance of a native run.** `xcodebuild` and `codesign` run on the Mac,
   against the Xcode.app already in `/Applications`. DerivedData for an app stays
   warm between that app's jobs.
3. **Little disk.** One Xcode and one set of simulator runtimes per Mac, shared.
   No second macOS, no second Xcode, no copy per job.
4. **The worker can still build, sign and upload** iOS and macOS apps, including
   the keychain step `codesign` requires *(revised: LaunchDaemon: a CI keychain the
   worker unlocks, not the login keychain)*.
5. **Another user on the same Mac cannot read a job's files.** The home, the
   keychain, the worker token, git credentials, signing material, DerivedData
   and temp are private to `hangar`. Xcode stays readable because the build
   cannot run without it.
6. **The install and the idle self-update keep working** for that user. The
   server still hands out one `hangar-worker` binary, the file beside
   `hangar-server`. The update still replaces the worker's own copy and
   re-execs when the worker is idle.
7. **Setup is as automated as macOS allows.** The curl install, run by an
   administrator, creates the `hangar` account, generates its password (the
   operator never invents one), shows it once, keeps it in the administrator's
   login keychain, installs the worker there and guides the one step a script
   cannot do: a graphical login as `hangar`. It detects that login and
   finishes. *(revised: LaunchDaemon: there is no such step any more; the
   command finishes on its own and the worker survives a reboot without a
   login.)* A worker already enrolled as the console user moves the same way,
   without a new pairing and without throwing away its DerivedData.

## Non-goals

- Stopping a repo from compiling and running code on the build Mac. That is the
  job. See *What this does not stop*.
- Isolating one Hangar app from another app built by the same worker. They share
  the `hangar` user on purpose. Per-job users, per-job keychains and a cold
  DerivedData are not this work.
- A hard scheduler gate that refuses a machine until it runs as `hangar`.
  Existing workers keep taking jobs through the migration. The doctor warns.
- Hiding files from the operator. The operator is an administrator and can
  `sudo`. Isolation is against a build, not against the person who owns the Mac.
- Egress filtering, a process reaper for daemons a hook double-forks, or a
  private `/tmp` mount.
- Changing how secrets are encrypted on the server, how a job wipes its
  as-file secrets, or how git receives `HANGAR_GITHUB_TOKEN`.
- VM isolation. The 2026-11-04 design already defers clean VMs (Tart, Anka) to
  a later executor. This design does not bring that forward.

## Anti-goals

- A full macOS VM per worker or per job. It re-downloads or re-copies Xcode, and
  Xcode is tens of gigabytes. That fails both constraints even if the isolation
  is stronger.
- A container that cannot run `xcodebuild` and `codesign`.
- A second copy of Xcode or of the simulator runtimes per user, per worker or
  per job, for the same reason: Xcode is tens of gigabytes, and a single iOS
  simulator runtime is itself several gigabytes.
- Installing the worker binary somewhere the `hangar` user cannot replace, or
  pointing the agent at the server's copy of the binary. Either one breaks the
  idle self-update.
- Copying the console user's login keychain, Xcode account or `~/.gitconfig`
  into the `hangar` user. That would place the interactive user's signing keys
  and git credentials in the account that runs untrusted build scripts.
- Re-enrolling the machine, and so issuing a new token, when the only thing that
  changed is the macOS user.

## Current state

Conclusion: **not specified.**

What exists today is a convention, not an isolation boundary.

- The 2026-11-04 design says builds run as a dedicated `hangar` macOS user,
  logged in through fast user switching, because the Apple Development identity
  lives in that user's login keychain and `codesign` needs it unlocked. Clean
  VMs per build are a non-goal. "VM isolation is a later executor." It does not
  compare a container, it does not say per machine or per job, and it does not
  say what another account on the Mac can read.
- `docs/worker-setup.md` tells the operator to create that user and to run the
  install as that user. The install is `curl -fsSL http://<host>:8787/install | sh`
  (or `scripts/worker/install-worker.sh` from a checkout). The script downloads
  one binary into `~/.local/bin` (or, from the checkout script's default,
  `/usr/local/bin`), writes `~/Library/Application Support/Hangar/worker/config.json`
  at mode 0600, writes `~/Library/LaunchAgents/app.hangar.worker.plist`, and
  loads it with `launchctl bootstrap gui/$(id -u)`. The plist sets
  `LimitLoadToSessionType` to `Aqua`.
- Nothing in that path checks that the user is `hangar`, that the user is not
  an administrator, or that the home is private. "Use This Mac for Builds"
  (`POST /setup/local-worker`, documented in `docs/server-setup.md`) runs the
  same install as the server's user. On the Mac mini that is the console user,
  which is also the user whose home holds `master.key` and `hangar.sqlite`.
- A job's files live under the data directory in the configuration, by default
  `~/Library/Application Support/Hangar/worker/`: `workspaces/<appSlug>/repository`,
  `workspaces/<appSlug>/DerivedData`, and `jobs/<jobID>/{secrets,archive,export,upload,tmp,…}`.
  As-file secrets are mode 0600 in a 0700 directory. The data directory itself
  is created with no mode, so a custom path outside `~/Library` is world-traversable
  under a normal umask. `~/Library` on a normal macOS account is mode 0700, which
  is why the default path happens to be private. The home directory is mode 0755
  and group `staff`, so files a job writes directly under the home are readable
  by every other account.
- *(revised for 0.6.0)* Since 0.6.0 the job's files live in a separate work
  directory without spaces, `WorkerConfiguration.resolvedWorkDirectory`: by
  default `~/.hangar/worker` for the usual data directory. It holds
  `workspaces/`, `jobs/` and `tmp/<job>` (each job's `TMPDIR`); the data
  directory keeps only `config.json`. On the first start with a new work
  directory, `WorkDirectoryMigration` moves `workspaces/` there and drops the
  parts of DerivedData that record the old absolute path (`DerivedData/Build`,
  `SourcePackages/workspace-state.json`, `artifacts`, `checkouts`; the git
  mirrors in `SourcePackages/repositories` stay). SIGTERM stops the worker
  cleanly: no new jobs, a running job is cancelled with the reason and cleans
  up, and a self-update never restarts while a job poll is in flight. The curl
  install checks the downloaded binary against the SHA-256 the server put in
  the script.
- The worker process's umask is launchd's, normally 022. A hook that writes
  `/tmp` leaves a world-readable file owned by whoever the worker is.
- Git does not store the GitHub token. `Checkout` sets an in-environment
  credential helper for `github.com` and clears other helpers so `osxkeychain`
  does not keep the token. That helper is in the environment of git and of the
  one `xcodebuild -resolvePackageDependencies` run. xcodebuild records its
  environment in DerivedData. The token can therefore sit in the per-app
  DerivedData after the job ends. DerivedData is kept on purpose, as a cache.
- Idle self-update is `WorkerSelfUpdate`. The heartbeat sends the SHA-256 of the
  running binary. The server compares it with the one `hangar-worker` beside its
  own executable (`WorkerBinary.locate`) and, when they differ, names the hash.
  When no job is running the worker downloads `GET /install/hangar-worker`,
  stages `.hangar-worker.update` next to its own executable, renames it over
  that executable, and re-execs. The stage fails with `unwritable` when the
  directory is not writable by the worker's user. A root-owned `/usr/local/bin`
  install cannot self-update. The server's file is not per-user and must not
  become per-user.
- Signing, the doctor and the scheduler are unchanged by this design and stay
  as they are. `canSignWithoutPrompt` is a real `codesign` of a throwaway file
  with the Apple Development identity in the worker user's login keychain. The
  scheduler treats `cannotSign` as ineligibility for every job, not only for
  archive jobs (`Scheduler.ineligibility`). A worker with a locked keychain is
  given nothing. That is why the agent has to stay in the logged-in Aqua
  session.

## Options

Compared on isolation, performance and disk. One is chosen.

**Separate unprivileged macOS user, one per machine. Chosen.**

The build runs natively. It uses the Xcode in `/Applications` and the simulator
runtimes in `/Library/Developer/CoreSimulator`. Disk added is the `hangar` home:
a keychain, the worker configuration, per-app checkouts and DerivedData, and
that user's package cache. A native run as the console user would have spent
the cache anyway. There is no second Xcode. Isolation from the interactive user
and from the server's user is the normal Unix boundary: different uid, home
mode 0700, login keychain in that home. `xcodebuild` and `codesign` work,
because this is the arrangement the worker already documents for the keychain.
What it does not stop is spelled out below.

**Container. Rejected.**

A Linux container (Docker, or Apple's containerization of Linux) cannot run
`xcodebuild` or `codesign`. It is not a solution, however small its disk is.
There is no macOS container runtime that runs those tools against the host's
Xcode without a VM. A container whose filesystem is a full macOS is a VM and
falls under the next option.

**macOS VM (Tart, Anka, Virtualization.framework). Rejected.**

A VM can isolate more, including the kernel the build sees. It fails the
constraints. Each VM needs an operating system, and a build needs Xcode. Xcode
is tens of gigabytes before simulator runtimes, which add several gigabytes
more. Copying that per worker, or per job, or letting the VM download its own,
is the disk failure. Booting the VM, copying the toolchain and building against
a cold DerivedData is the performance failure. Mounting the host's `Xcode.app`
into a guest is still a second macOS (itself many gigabytes) and is not how
Xcode is installed: first launch, the license and the simulator service expect
a real Mac. The 2026-11-04 design already deferred this. It stays deferred.

**Seatbelt (`sandbox-exec`) or App Sandbox, instead of a user. Rejected.**

Performance and disk would be fine: it is the same process and the same files.
It does not replace the user. `xcodebuild` needs the keychain, the simulator
service, provisioning profiles, DerivedData and the network. A profile loose
enough to allow that does not hide the interactive user's home any more reliably
than a different uid, and a profile tight enough to hide it breaks signing.
`sandbox-exec` is a legacy interface. The separate user is the boundary that
already matches how `codesign` works.

**Per job rather than per machine. Rejected**, as a stronger shape of the same
user idea.

A fresh user, home or DerivedData per job would stop one repo from reading
another app's cache and would keep a crashed job's files away from the next
repo. It is a cold DerivedData every time, which is the performance failure,
and it multiplies checkouts, which is needless disk. It also fights the
keychain. The Apple Development identity is per worker and persistent, the
agent is one LaunchAgent in one Aqua session, and `codesign` needs that
session's unlocked login keychain. A new user per job cannot have its own
logged-in GUI session for the length of a build. A temporary keychain per job
is the existing Phase 2 idea for a Developer ID `.p12`, not a substitute for
the persistent development identity, and it does not by itself stop the job
from reading the `hangar` login keychain.

## Decision

**One unprivileged macOS user named `hangar` per build Mac. Not a container,
not a VM, not a sandbox profile, not a new user per job.** *(this design's call)*

Jobs on that Mac share the user, the login keychain and the warm per-app
DerivedData. They do not share a uid with the interactive user or with the
server. Xcode and the simulator runtimes are the Mac's, used in place.

## How it works

### The user

Short name `hangar`, full name `Hangar`, shell `/bin/zsh`, home `/Users/hangar`.
Not a member of `admin`. No `sudoers` entry.

`hangar-worker isolate` creates the account. It runs in the administrator's
terminal, without sudo; it runs `sudo` for each privileged step, and `sudo`
asks for the administrator's password, because creating a user needs it. The
curl install runs it for an administrator.

*(revised: automated)* The operator does not choose the `hangar` password.
`isolate` generates one from the system's cryptographic generator: five groups
of four lowercase letters and digits without look-alikes (about 100 bits, easy
to type once at the login window). It saves it first in the administrator's
own login keychain, as a generic password with service
`app.hangar.worker-account` and account `hangar`, written with
Security.framework (no `security -w` on argv), then shows it once in the
terminal with the command that prints it again:

```sh
security find-generic-password -s app.hangar.worker-account -a hangar -w
```

Neither the server nor the worker stores, reads or needs it. It is not in the
worker configuration, not on a command line, not in a log. Do not pass
`-admin`. The account is created and the password set without putting it on
argv:

```sh
sudo sysadminctl -addUser hangar -fullName Hangar -shell /bin/zsh -home /Users/hangar -password <throwaway>
printf 'passwd /Users/hangar <password>\nquit\n' | sudo dscl .     # the real one, on stdin
sudo createhomedir -c -u hangar
```

`sysadminctl` only sees a random throwaway, replaced at once. Whether
`sysadminctl -password -` reads stdin or the terminal is not documented, and
`sysadminctl` often exits 0 on failure, so `isolate` checks `id -u hangar`
after it and verifies the real password in process through Open Directory
(`ODRecord.verifyPassword`). A password that did not take stops the run, with
`--reset-password` as the way out. Keeping it in the administrator's keychain
is the trade-off the author chose: anything running as the administrator can
ask for that item, and Keychain Access asks before it gives it to a different
program. That account is the operator, not a build.

A password typed at the terminal does not open this user's graphical session.
loginwindow creates the `gui/<uid>` domain, the login keychain, and the unlock
that survives a reboot, and it does that only when the user actually logs in.
A keychain created and unlocked with `security` during setup locks again at
the next boot. Keeping the password on disk so a script can unlock it after
every boot would store the signing key's password next to the builds. Automatic
login as `hangar` is not a substitute: it takes the console, and on a FileVault
Mac the preboot password still comes first. *(revised: LaunchDaemon: the
password of a dedicated CI keychain is now kept on disk, and the login is gone;
see *Revised: LaunchDaemon and the CI keychain*. The account password itself is
still never on disk, and is only for emergencies.)*

The same command therefore installs everything first (the worker, its
configuration and its launch agent are in the `hangar` home before the login,
so the login itself starts the agent through `RunAtLoad`), then shows the
password and tells the operator to switch to `hangar` once, through fast user
switching, and switch back. It detects the session without sudo: a session
exists when `hangar` owns a `loginwindow` or `Dock` process (`ps -axo
uid=,comm=`), which every Aqua session has. The `hangar` session stays logged
in. The console session stays the interactive user. The Mac still must not
sleep (`pmset`, already in the worker setup): sleep suspends both sessions.

After the login it waits for `launchctl print gui/<uid>/app.hangar.worker` to
say `state = running`, and bootstraps the agent itself if the login did not
load it. When the session already existed (a rerun or an update), it restarts
a loaded agent onto the new binary the way launchd stops it: `launchctl kill
SIGTERM`, which the worker handles by cancelling a running build with the
reason and cleaning up; once the pid in `launchctl print` has changed, KeepAlive
has started the new binary (`launchctl kickstart` only if it is not running
yet). Only a worker still running after the wait gets `kickstart -k`. An
unloaded agent is bootstrapped. It reports whether `~/Library/Keychains/login.keychain-db` exists: the
login creates and unlocks it.

*(revised)* No FileVault secure token is granted. A user without one cannot
unlock the disk at boot, but logs in normally through fast user switching once
the administrator has unlocked it, which is the only way `hangar` is ever
logged in. Granting one would need both passwords on `sysadminctl`'s command
line. This is a claim to verify on a FileVault Mac before merge.

`sudo xcodebuild -license accept` stays as in `docs/worker-setup.md`. First
launch is system-wide: `isolate` runs `sudo xcodebuild -runFirstLaunch` when
`xcodebuild -checkFirstLaunchStatus` says it is still needed. It is not a copy
of Xcode. The license is the system license.

The agent does not move to a LaunchDaemon, and the plist does not gain a
`UserName` key in the system domain. A daemon has no Aqua session. The login
keychain stays locked, `codesign` does not return, `canSignWithoutPrompt` stays
false, and the scheduler then assigns the machine nothing. The plist keeps
`LimitLoadToSessionType` = `Aqua`, `RunAtLoad` and `KeepAlive`, and it keeps
being bootstrapped into `gui/<hangar uid>`. *(revised: LaunchDaemon: reversed.
The owner rejected a login after every reboot. The worker is now a LaunchDaemon
with `UserName` `hangar`, and signs with a keychain that is not the login
keychain, so the locked login keychain no longer matters.)*

### Revised: LaunchDaemon and the CI keychain

*(revised: LaunchDaemon, 0.9.0)* The graphical login had one job: unlock a
keychain `codesign` can use. It had to be repeated after every reboot, by a
person, through fast user switching, and codesign could still stop at an
"Always Allow" prompt in a session nobody watches. Both are gone:

- **The worker is a LaunchDaemon.** `/Library/LaunchDaemons/app.hangar.worker.plist`,
  root:wheel 0644, bootstrapped into `system`: `UserName` `hangar`, `GroupName`
  `staff`, `InitGroups`, `RunAtLoad`, `KeepAlive` (a crash, and the idle
  self-update's exit path, rely on launchd starting it again; the update itself
  re-execs in place, as before), `SessionCreate` (a security session of its own
  for the keychain), and `EnvironmentVariables` with `HOME`, `USER`, `LOGNAME`
  and the `PATH` a launch agent gets, since a daemon gets no login environment.
  Logs stay in `~/Library/Logs/Hangar/worker.log`. It starts at boot, before
  anyone logs in, FileVault unlock aside.
- **A dedicated CI keychain.** `isolate` creates
  `/Users/hangar/Library/Keychains/hangar-ci.keychain-db` as `hangar` (`sudo -u
  hangar security`), with a generated password (the generator of the account
  password) in `~/Library/Application Support/Hangar/worker/keychain-password`,
  mode 0600, owner `hangar`, and no automatic locking (`set-keychain-settings`
  without `-t` or `-l`). The password reaches `security` only on standard
  input (`security -i`, one command per run so its exit status is that
  command's); it is not on a command line, in a log, in the configuration or
  on the server. A keychain that unlocks with its stored password survives a
  rerun; any other is replaced, and the next archive creates the identity
  again.
- **The worker manages the keychain.** Its password file is what makes a
  worker headless (`CIKeychain.installed`); a worker without one, in anyone's
  login session, is unchanged. Before each job, and in the doctor on every
  heartbeat, it unlocks the keychain and keeps it the default and first on
  `hangar`'s user search list, where xcodebuild puts a new identity and
  codesign looks for one. After the archive, the export and a test (each runs
  `-allowProvisioningUpdates`), whether the step succeeded or not, it runs
  `security set-key-partition-list -S apple-tool:,apple:,codesign:`, so no key
  in the keychain ever needs the prompt. These settings are made by the daemon,
  in its own context, not by `isolate` through `sudo -u`.
- **The doctor checks that keychain instead of the login keychain.** It
  exists, unlocks with the stored password and is the default; once it holds
  an Apple Development identity, codesign signs with it (when it does not, the
  partition list is set again and codesign tried once more). The report gains
  `headless` and `keychainProblem`. A ready keychain without an identity counts
  as able to sign: the first archive creates the identity, and a machine that
  "cannot sign" would never get that archive.
- **A team App Store Connect key is required to sign.** The headless worker
  has no Xcode account: an account's credentials live in a login keychain. It
  reports `xcodeAccountSignedIn: false` and `headless: true`, and the
  scheduler keeps an archive whose key has no issuer ID off it with "needs a
  team App Store Connect key (with an issuer ID): this Mac's worker runs
  without an Xcode account" (`Ineligibility.needsTeamKey`, in queue notes and
  the deploy check), instead of letting xcodebuild fail deep in the archive.
  The worker checks the same before checkout, for an older server.

*Why the password may now sit on disk.* The earlier text rejected it as storing
the signing key's password next to the builds. That is still true, and it adds
little: during every job the keychain is unlocked, and the build's own code
runs as `hangar`, so a build that wants the key can already use it without the
file. The file is readable only by `hangar` and root, like the keychain. The
keychain holds only Hangar's signing identity, created for `hangar`; never the
operator's keys, which stay in the operator's login keychain. In exchange, no
person has to log in after every reboot, and codesign never waits for a click.

*What was tried before deciding* (as the author, not as `hangar`, without sudo:
a launchd job in the Background session of `user/<uid>`, with `SessionCreate`):
creating, unlocking and setting the partition list of a keychain over
`security -i` worked; with a scratch `HOME`, the keychain became the default
and the search list; codesign with a key whose ACL lists codesign failed at
once with `errSecInternalComponent` before the partition list and signed after
it, and failed at once (no hang) on a locked keychain. Keys Xcode creates list
Xcode, codesign and productbuild and partition `apple:`. `xcrun simctl`, a
simulator boot and an app-hosted XCTest in `xcodebuild test` on an iOS 27.2
simulator passed in that session. Not tried, because it needs root: the same
from the `system` domain with `UserName`. See *Manual verification*.

### What is shared, what is private

Shared, one copy on the Mac, readable by `hangar`, not duplicated:

| Path | Why it is shared |
|---|---|
| `/Applications/Xcode*.app` | The toolchain. Tens of gigabytes. World-readable, owned by root. `hangar` executes it and must not need to write it. `XcodeLocator` already scans this directory. |
| `/Library/Developer/CoreSimulator` (runtimes and volumes) | Simulator runtimes, several gigabytes each. Installed once, system-wide, by `xcodebuild -downloadPlatform` as an administrator. |
| `/Library/Developer/CommandLineTools` | Only if the operator installed the command-line tools. Not a second Xcode. |
| The selected developer directory | `xcode-select` is system-wide. A job still sets `DEVELOPER_DIR` to the Xcode the workflow asked for. |
| Homebrew's prefix, when it is `/opt/homebrew` or `/usr/local` | `xcodegen`, `rclone` and `brew` are already installed there. `hangar` needs to execute them, not to own the cellar. Do not install a second Homebrew under the `hangar` home. |

Private to `hangar`. Another account must not be able to traverse to these.
Mode 0700 on the home is what makes the files inside private even when a file
itself is 0644:

| What | Where | Notes |
|---|---|---|
| Home | `/Users/hangar` | Mode 0700, owner `hangar`, group `staff`. No ACL that grants another user read or execute. |
| Login keychain and Apple Development identity | `~/Library/Keychains` | Created by the GUI login. Persistent across jobs, as the 2026-11-04 design requires. Not copied from the console user. *(revised: LaunchDaemon: the CI keychain `hangar-ci.keychain-db` holds the identity; no login creates a login keychain.)* |
| CI keychain password *(revised: LaunchDaemon)* | `~/Library/Application Support/Hangar/worker/keychain-password` | Mode 0600, owner `hangar`. Read by the worker, given to `security` on stdin. |
| Xcode account, provisioning profiles, per-user simulator devices | `~/Library/Developer` | Devices are small. Runtimes are the shared ones above, not a copy of this tree. An individual App Store Connect key still means signing in to Xcode once as `hangar`. *(revised: LaunchDaemon: no Xcode account; a team key is required to sign.)* |
| Worker token | `~/Library/Application Support/Hangar/worker/config.json` | Mode 0600, directory 0700, as `WorkerConfiguration.write` already does. The configuration names the work directory explicitly. |
| Checkouts and DerivedData | `~/.hangar/worker/workspaces/<appSlug>/repository` and `…/DerivedData` | *(revised)* The work directory, no spaces in the path, mode 0700 like `~/.hangar`. One warm cache per app per machine. Not the console user's DerivedData, and not a world-readable directory under `/Library`. |
| This user's package and Xcode caches | `~/Library/Caches` (including `org.swift.swiftpm`) | Warm across jobs. Not shared with the console user: that cache can hold their source and credentials, and a shared cache would be readable both ways. The disk cost is one cache, not an Xcode. |
| Job secrets, archive, export, result bundle | `~/.hangar/worker/jobs/<jobID>/` | Secrets stay 0600 in a 0700 directory. The job directory is removed at cleanup, as today. |
| Temp | `~/.hangar/worker/tmp/<job>` | `TMPDIR` for the job, outside the job directory since 0.6.0. Not `/tmp`. Swept at start. |
| Git credentials | nowhere on disk | Unchanged: in-environment helper, helpers from gitconfig cleared for `github.com`, no `osxkeychain`. The private home means a credential file a hook writes anyway is not readable by the console user. |
| Worker binary the agent runs | `/Users/hangar/.local/bin/hangar-worker` | Mode 0755, directory writable by `hangar`. This is a copy of the one binary the server hands out, not a second build and not the server's file. |
| Logs | `~/Library/Logs/Hangar/worker.log` | The plist's `StandardOutPath` and `StandardErrorPath`. |
| Server data | the server user's home, never the `hangar` home | `~/Library/Application Support/Hangar/server/` (`hangar.sqlite`, `master.key`, artifacts) stays with the user that runs `hangar-server`. |

`hangar` is not given write access to `/Applications` or to the simulator
runtimes. A job that tries to modify Xcode fails. That is correct.

If `xcrun simctl list` as `hangar` shows no runtimes while the console user has
simulators, the runtimes were installed into a home rather than into
`/Library/Developer/CoreSimulator`. The fix is to download them once as an
administrator, not to copy the console user's `CoreSimulator` directory. That
directory is large and holds the other user's devices.

### Permissions the worker enforces

The home being 0700 is the boundary. Two things in the worker keep it that way
after install, without a recursive walk of DerivedData (a recursive chmod on
every start is slow and races a build):

1. `hangar-worker run` sets `umask(0o022)` before the loop starts (*revised*:
   it first set 077, which made every file in a built app owner-only, so the
   macOS installer package was rejected by App Store Connect with "files that
   are only readable by the root user"). Each job's TMPDIR lives in the 0700
   work directory, so what a job writes there stays private; a file a hook
   writes straight into `/tmp` is world-readable, as on any Mac. The sticky bit on `/tmp` already stops
   other accounts deleting them. `WorkerSelfUpdate` sets the staged binary to
   0755 by `chmod`, which is not subject to umask, so the replaced binary stays
   executable. `setup` and the secret writer already set 0600 and 0700
   themselves. Doctor and `setup` do not change umask: they do not run repo
   code. The umask is applied in the `run` command, not in `WorkerLoop`, so
   unit tests do not change the umask of the test process.
2. `prepareDataDirectory` creates the data directory and the work directory
   and then `chmod`s each to 0700. Passing `posixPermissions` to
   `createDirectory` is not enough: an existing directory keeps its mode, and
   the attribute is subject to umask. It does not walk the cache.
3. Only when `NSUserName()` is `hangar` and the home is `/Users/hangar`, `run`
   sets that home to mode 0700 and strips ACLs (`chmod -N`, then `chmod 700`).
   A worker running as any other user does not touch that user's home. Tests
   must not call this against the real home: the check is the path and the
   name, and the function that applies it takes the home path so a test can
   pass a temporary directory. If the chmod fails, log it and keep running.
   Refusing to start would brick a machine over a mode bit; `hangar-worker
   isolate` is the strict check.

On start, if the user is not `hangar`, log one warning: the worker is running
as that user, so a build can read that user's files. Do not exit.

### What a job sees

Unchanged pipeline, unchanged paths, with the uid and the umask above.

- The process user is `hangar`. `HOME`, `USER` and `LOGNAME` are that user's,
  because the agent runs in that session and `CIEnvironment` already passes
  them through from the worker.
- `DEVELOPER_DIR` is the shared Xcode the workflow selected. `PATH` is
  unchanged (`/usr/bin:/bin:/usr/sbin:/sbin` plus Homebrew's prefixes).
- The checkout and DerivedData are that user's warm per-app cache.
- `TMPDIR` is `~/.hangar/worker/tmp/<job>`, mode 0700, removed with the job.
- The GitHub token exists only in the environment of git and of
  `xcodebuild -resolvePackageDependencies`, as today.
- The App Store Connect key is an as-file secret under the job directory, wiped
  at cleanup, as today.
- `codesign` uses the `hangar` login keychain. The first archive on a new
  `hangar` user creates the Apple Development identity there. The operator
  allows `codesign` in Keychain Access as that user if the doctor says
  `canSignWithoutPrompt` is false. That is the existing worker-setup step, done
  once, not per job. *(revised: LaunchDaemon: the CI keychain, unlocked by the
  worker before the job; the partition list replaces the Keychain Access step.)*
- A job does not see the console user's home, that user's keychain, that user's
  git credentials, or the server's `master.key`, provided the homes are 0700
  and the users differ. The migration checks the server directory explicitly.

### Install, launchd and update

No change to the protocol, to `WorkerSelfUpdate`, to `GET /install`, or to
where the server finds the binary.

The server keeps a single `hangar-worker` next to `hangar-server`
(`WorkerBinary.locate`: the executable in the same directory as the running
server, symlinks resolved). `install-server.sh` installs both into one bin
directory. Heartbeats compare hashes against that file. Workers download it
from `GET /install/hangar-worker`. There is still no per-user binary on the
server.

*(revised)* On the build Mac the administrator runs the curl install in
Terminal:

```sh
curl -fsSL http://<tailnet-host>:8787/install | sh
```

For an administrator (not `hangar`, no `HANGAR_AS_CURRENT_USER=1`) the script
downloads the worker into a private temporary directory, enrolls into a
configuration there when this Mac is not enrolled yet (the token never leaves
that directory except through `isolate`, which installs it mode 0600 into the
`hangar` home), checks the download against the SHA-256 the server wrote into
the script (`download_worker`, the same check as a current-user install, so a
binary that is not the announced one never reaches `isolate` or `hangar`), and
runs `hangar-worker isolate --binary <download> [--config
<enrolled>]` on the terminal. When the administrator's own worker is enrolled
with this server, `isolate` moves it instead (no pairing). When `hangar`
already has a configuration for this server (`sudo test -f`, `sudo plutil
-extract serverURL`), it is an update. The temporary directory is removed on
exit. `HANGAR_AS_CURRENT_USER=1` keeps the old behaviour: install for the user
running the script. The `hangar` user itself, and any standard account, also
install for themselves, with no sudo; a standard account is already not the
administrator.

The `hangar` agent's binary is `/Users/hangar/.local/bin/hangar-worker`
(`HANGAR_BIN_DIR` applies only to current-user installs). The plist's program is that binary. Idle
self-update can replace it, because `hangar` owns the directory, and then
re-execs. The running process keeps the old inode until the exec, as it does
today. Jobs are not interrupted: the update waits until `runningIDs` is empty
and no job poll is in flight. The re-exec keeps the uid, the umask and the
ignored SIGTERM disposition until `run` installs its handlers again, so a
stop during the update window is not lost as an unclean kill. An update run by
the administrator (`isolate` again) restarts the agent with SIGTERM, as in
*The user*.

Do not point this plist at `/usr/local/bin/hangar-worker` when that file is
root-owned. Self-update then fails with `unwritable` and the machine stays on
the old binary. Do not point it at the server's copy either, even on the Mac
that runs both. On that Mac the server's `hangar-worker` is the file the server
hands out. Replacing it in place from a build, or deleting it during a
migration, removes the binary other Macs download. The `hangar` user's agent
gets its own copy under `/Users/hangar/.local/bin`.

`scripts/worker/install-worker.sh` remains the checkout install. Run it as
`hangar` with `--bin-dir ~/.local/bin`. Its default of `/usr/local/bin` is a
bad fit for this user: it needs `sudo`, and the resulting binary is often not
replaceable by the idle update. The script's default does not have to change
in this work. The worker-setup doc tells the operator which flag to pass.

`HANGAR_WORKER_CONFIG`, if set, must be a path under `/Users/hangar`. A path
on a shared volume undoes the home mode.

### The server on the same Mac

The Mac mini may run the server and a worker, as the 2026-11-04 design allows.
The server stays the user it already runs as. The worker becomes `hangar`.
Two LaunchAgents, two gui domains, two homes. The server's agent is
`app.hangar.server` in the console user's domain. The worker's agent is
`app.hangar.worker` in `gui/<hangar uid>`. *(revised: LaunchDaemon: the worker
is `system/app.hangar.worker`.)*

`master.key` is mode 0600. That only helps if the `hangar` user cannot traverse
to it. The server user's `~/Library` is mode 0700 on a normal account. The
migration does not assume that: it checks, as `hangar`, that the server data
directory's `master.key` is not readable, and stops if it is. The operator then
sets the server data directory to 0700. The script does not chmod the console
user's home on its own.

### Use This Mac for Builds

`POST /setup/local-worker` runs the install script as the server's user and
writes that user's `~/.local/bin` and LaunchAgents. That is the layout this
design exists to stop: the build uid and the `master.key` uid are the same, so
a repo can read the server's data.

*(this design's call)* The endpoint allows the install only when the server
process itself is already user `hangar` (the server and the worker are then the
same dedicated account, which is isolated from any other interactive user, and
there is no second home to protect). Otherwise it returns `409` with code
`dedicated_user_required` and a message that says to run the install command
in Terminal as an administrator. That command creates the user with a
generated password and waits for one switch to the `hangar` user *(revised:
LaunchDaemon: no switch; it starts the daemon)*. The setup
page (`Sources/HangarServer/Web/assets/pages/setup.js`) stops offering the
button in that case and shows the install command (`curl -fsSL
<origin>/install | sh`), which creates the user. An old page that still
posts is refused by the endpoint. No `sudo` from `hangar-server`: the server
is not root and must not write another user's home.

*(revised)* The curl install run by hand as the console user now sets up
`hangar` when that user is an administrator; with `HANGAR_AS_CURRENT_USER=1`,
or as a standard account, it still enrolls as that user. This design
does not make the worker refuse to start in that case. The warning in *Permissions*
and `runningUser` on the machine report are how the operator sees it. A hard
refusal would stop the fleet on the day this ships, before the migration.

## Migration

For a worker that is already enrolled and running as the console user. The
machine token stays. Hangar does not gain a second machine, and the operator
does not pair again. DerivedData moves, so the next build is not cold.

**One command.** *(revised: `hangar-worker isolate`, not a shell script)* The
curl install runs it for an administrator; it can also be run by hand. It is
Swift so the command sequence is testable: every account, file and launchd
change goes through one injectable runner, tests assert the exact sequence, and
`--dry-run` runs only the read-only probes and prints every change (nothing
with sudo runs). The same command creates a fresh Mac's account, moves an
enrolled worker, updates an isolated one and resumes an interrupted run.

`hangar-worker isolate` takes:

- `--config FILE`: the configuration to move. Default: the `--config` in the
  invoker's `~/Library/LaunchAgents/app.hangar.worker.plist`, else the
  invoker's default configuration. The install script passes the one it just
  enrolled.
- `--binary FILE`: the `hangar-worker` to copy. Default: the running
  executable, else the old agent's program.
- `--server-data DIR`: default `<home>/Library/Application Support/Hangar/server`,
  checked only when it exists. Empty skips the check.
- `--dry-run`, `--reset-password` (a new generated password for an existing
  `hangar`). *(revised: LaunchDaemon: `--no-wait` is gone; there is no login to
  wait for.)*

It refuses to run as root, as `hangar`, or as a standard account (creating a
user needs an administrator; the message names `HANGAR_AS_CURRENT_USER=1`).
In order:

1. Read the old plist and configuration, as the invoker. Ask the server, in
   process, whether it accepts that token (`GET /api/v1/worker/me`). A refusal
   stops the run before anything changes.
2. `sudo -v`, after saying why.
3. Create the account and its password as in *The user* when `id -u hangar`
   fails; `createhomedir -c -u hangar` either way.
4. If the server data directory exists, `sudo -u hangar test -r
   <server-data>/master.key` must fail. If it does not, stop before anything
   moves and print the `chmod 700` for the server data directory. The script
   does not chmod it.
5. `sudo xcodebuild -runFirstLaunch` when still needed.
6. `launchctl bootout gui/<old uid>/app.hangar.worker`, then wait until no
   `hangar-worker run` is left for the old uid; stop if one is. Bootout sends
   SIGTERM: an in-flight build is cancelled with "stopped (SIGTERM)", reports
   it and cleans up. The operator runs this when nothing important is
   building; the command says so.
7. `install -d -o hangar -g staff` the directories (0700 for Application
   Support, the data directory, `~/.hangar`, the work directory
   `~/.hangar/worker` and its `workspaces`, and the logs; 0755 for
   `.local/bin` and `LaunchAgents`). `install -m 755` the binary into
   `/Users/hangar/.local/bin`. A copy: the server's `hangar-worker` is never
   moved, deleted, or used as the new plist's program.
8. The configuration: the same `serverURL`, `token` and `maxConcurrentJobs`,
   `dataDirectory` rewritten to the `hangar` data directory and
   `workDirectory` set to `/Users/hangar/.hangar/worker`, staged mode 0600
   in the invoker's private temp directory and installed with `install -o
   hangar -m 600`. The token is never on a command line or printed. A custom
   `dataDirectory` or `workDirectory` outside the home is not preserved. With no configuration
   to move, `hangar` must already have one (update), or the run stops.
9. *(revised for 0.6.0)* Move the build cache into
   `/Users/hangar/.hangar/worker/workspaces`, app by app, the way
   `WorkDirectoryMigration` does within one user: from the old work directory
   (the configured `workDirectory`, else the default for the old data
   directory under the invoker's home, `~/.hangar/worker`), then from
   `<old dataDirectory>/workspaces` for a worker that never ran 0.6.0. `mv` on
   one volume, or `ditto` then `rm -rf` across volumes (it says the app
   temporarily takes twice its size). An app `hangar` already has keeps its
   copy, and the old one is named and left. Then, for every app that moved,
   `sudo rm -rf` the parts of DerivedData that record the old absolute path
   (`WorkDirectoryMigration.pathBoundCaches`: `DerivedData/Build`,
   `SourcePackages/workspace-state.json`, `SourcePackages/artifacts`,
   `SourcePackages/checkouts`; the git mirrors in
   `SourcePackages/repositories` stay), and `chown -R hangar:staff` the
   workspaces. Remove the old `jobs/` and `tmp/` (both directories' `jobs/`),
   and the old work directory and `workspaces/` when they are empty. Never copy
   Xcode, `~/Library/Keychains`, `~/Library/Developer`, `~/Library/Caches` or
   `~/.gitconfig`.
10. `chmod -N` and `chmod 700` the `hangar` home, then confirm the invoker can
    no longer traverse it (`access(X_OK)` must fail).
11. Install the launch agent (the keys of `scripts/worker/app.hangar.worker.plist`,
    program the new binary, logs under the `hangar` home, `Aqua`), owner
    `hangar`, mode 0644.
12. The login and the agent, as in *The user*.

    *(revised: LaunchDaemon)* Steps 11 and 12 are now: before step 7, a
    `hangar` set up by an older version loses its agent (`sudo launchctl
    bootout gui/<hangar uid>/app.hangar.worker` when loaded, then `sudo rm` of
    `~/Library/LaunchAgents/app.hangar.worker.plist`), so a later login cannot
    start a second worker with the same token. After step 10, create the CI
    keychain; install the daemon plist (root:wheel 0644) and `sudo launchctl
    bootstrap system` it; a daemon already loaded is restarted with SIGTERM as
    in *The user*, or booted out and bootstrapped again when its plist
    changed; then wait for `launchctl print system/app.hangar.worker` to say
    `state = running`. In step 13 only a heartbeat that reports `headless`
    counts (from an older server, one after the old workers stopped): the old
    agent in the account also reported `hangar`. A `keychainProblem` in it is
    printed as a warning.
13. Poll the server, in process with the token, until it reports the machine
    with `runningUser == "hangar"` (or, from a server that does not keep that
    field, a heartbeat after the old agent stopped). In update mode, where
    `isolate` has no token, `sudo -u hangar hangar-worker check` must exit 0.
    On success remove the old plist (so the console user's next login does not
    start a second worker with the same token) and the old configuration (it
    holds the token); a configuration passed with `--config` is the install
    script's to remove. On failure both stay, and the message says how to
    start the old agent again. Do not remove `/usr/local/bin/hangar-worker`.
14. Print the follow-ups it cannot do: the first archive creates the identity
    and Keychain Access may need the existing `codesign` click; with an
    individual App Store Connect key, sign in to Xcode as `hangar` once; a
    missing Homebrew tool means fixing the prefix's permissions, not a second
    Homebrew. *(revised: LaunchDaemon: the follow-ups are that signing needs a
    team key, and the Homebrew note.)*

After this, idle self-update targets `/Users/hangar/.local/bin/hangar-worker`.
The server's binary is untouched. The first build uses the moved checkout,
package mirrors and module caches; Xcode rebuilds the dropped path-bound parts
once.

A Mac that was installed as `hangar` from the start does not run the script.

## What this does not stop

A repo Hangar builds can already compile and run code on that Mac. Hooks,
build phases and post-actions are that code. Isolation does not turn the build
into a sandbox where the compiler cannot run, and it does not stop the build
reaching the network. That is accepted.

On the per-machine user, a malicious or simply buggy repo running as `hangar`
can still:

- Read and write everything that uid can. That includes the `hangar` login
  keychain (the Apple Development private key and any Xcode account stored
  there) *(revised: LaunchDaemon: the CI keychain and its password file)*, the worker token in `config.json`, every app's cached checkout and
  DerivedData on this Mac, and this user's package cache. DerivedData may
  contain `HANGAR_GITHUB_TOKEN`, because the resolve step puts that variable
  in xcodebuild's environment and xcodebuild records the environment. The warm
  cache is why that leak between apps on the same worker is accepted.
- Read another job's secrets and environment when two jobs overlap, including
  through `ps` of the same user's processes. The default `maxConcurrentJobs` is
  1, which narrows the window. It is not a boundary. This design does not
  change the cap.
- Leave a process behind by double-forking. It lingers as `hangar`, not as the
  interactive user. A reaper is out of scope.
- Fill the disk, use the CPU, and talk to the network.
- Try to escalate past macOS. The account is not an administrator and has no
  sudoers entry, so a bug that needs admin does not apply. A kernel exploit is
  out of scope.

It cannot, by this boundary alone:

- Read the interactive user's home, login keychain, git credentials or SSH
  keys, when `/Users/hangar` is the build's home and the other home is not
  traversable.
- Read the server's `master.key`, database or artifacts, when those live in a
  different user's home and the migration's readability check passed.
- Keep running as the interactive user. The worker's uid is `hangar` for the
  life of the process, including after self-update's re-exec.
- See another Mac's worker. Nothing here changes the tailnet or the per-machine
  token.

The operator, as an administrator, can still read the `hangar` home. That is
not a hole in this design.

## Key Decisions

1. **The boundary is one unprivileged macOS user named `hangar` per machine,
   sharing the installed Xcode and the system simulator runtimes.** A container
   cannot run `xcodebuild` and `codesign`. A VM copies macOS and Xcode, and
   Xcode is tens of gigabytes, so it fails performance and disk. A sandbox
   profile does not hide another user's home as reliably as a uid and breaks
   signing if it is tight enough to try. A new user per job would cold-start
   DerivedData and cannot have its own unlocked login keychain for the length
   of a build.
2. **Per machine, not per job.** Warm per-app DerivedData and one Aqua session
   are the performance and the signing model the worker already has. The cost,
   accepted, is that every repo built on that Mac runs as the same uid and can
   read that uid's keychain, token and caches.
3. **Shared means the toolchain, not the caches that contain source or
   credentials.** `/Applications/Xcode*.app` and
   `/Library/Developer/CoreSimulator` are shared. DerivedData, the Swift package
   cache, the keychain, git credentials, signing material, the worker token and
   temp are private to `/Users/hangar`. Sharing the console user's DerivedData
   or package cache would let the build read that user's files.
4. **The home is mode 0700 and the data and work directories are mode 0700.**
   That is what stops another account reading job files. The umask stays 022,
   since build products must stay readable inside the package. The worker does not recursively chmod the
   cache. It only chmods `/Users/hangar` when it is actually that user, so a
   developer running the worker as themselves does not have their home locked
   down by a test or by a not-yet-migrated agent.
5. **The server keeps one `hangar-worker` beside `hangar-server`. The agent
   runs a copy under `/Users/hangar/.local/bin`.** Idle self-update replaces
   that copy and re-execs. It is not pointed at a root-owned path and not at
   the server's file, both of which either fail the update or destroy the
   binary other Macs download. No change to `WorkerSelfUpdate`.
6. **The agent stays a LaunchAgent in the `hangar` Aqua session.** A system
   daemon leaves the keychain locked, and the scheduler then assigns no jobs.
   *(revised: LaunchDaemon: reversed. The worker is a LaunchDaemon running as
   `hangar` and signs with a CI keychain it unlocks itself; its password is in
   a 0600 file in the `hangar` home. No login after a reboot, no codesign
   prompt. A team App Store Connect key is required to sign there.)*
7. **Migration keeps the machine token and moves `workspaces/`. It does not
   copy the login keychain or re-pair.** The token is the enrollment.
   `dataDirectory` and `workDirectory` inside the copied configuration are
   rewritten into the `hangar` home, or the new process would keep writing the
   console user's tree. The cache moves as `WorkDirectoryMigration` moves it,
   so DerivedData that names the old path is dropped rather than left to fail
   the next build. The development identity is created again by the first archive.
   Copying the old keychain would import the interactive user's keys.
8. **Use This Mac for Builds no longer installs as the server user**, unless
   the server already runs as `hangar`. The server process must not `sudo`.
   Hand install as the console user still works with `HANGAR_AS_CURRENT_USER=1`;
   the doctor reports `runningUser` and the Machines page warns. The
   scheduler does not grow a new ineligibility, so the fleet keeps building
   through the move.
9. **The account is not an administrator.** A compromised build must not have
   admin or a sudoers entry. Homebrew is the machine's prefix, used in place,
   not a second install under the home.
10. **Setup is one terminal command, and the operator never invents a
    password.** *(revised)* The curl install, for an administrator, runs
    `hangar-worker isolate`: it creates the user with a generated password,
    keeps that password in the administrator's login keychain and shows it
    once, moves or installs the worker, installs the agent, then waits for the
    one graphical login and confirms the result. Hangar's server and worker
    never store or need the password. The graphical login stays a real login:
    that is what keeps the keychain unlocked after a reboot. A keychain
    unlocked only for this run, the password on the build account's disk, and
    automatic login are rejected. No FileVault secure token is granted.
    `HANGAR_AS_CURRENT_USER=1` keeps installing as the current user.
    *(revised: LaunchDaemon: there is no graphical login. The password on the
    build account's disk is now accepted for the CI keychain only, for the
    reasons in *Revised: LaunchDaemon and the CI keychain*; the account
    password is still kept only in the administrator's keychain.)*

## Open Questions

None. The choices that change what gets built are the calls above. In
particular: the account name stays `hangar`; the scheduler does not refuse a
machine for running as the wrong user; DerivedData is moved rather than left
cold; the one-click local install is refused rather than retargeted at the
other home through `sudo`.

## PR Plan

*(revised)* As built on `worker-isolation`, one commit each:

1. **Keep the worker's files private.** `run` sets umask 022 (077 broke macOS packages), `prepareDataDirectory`
   chmods the data directory to 0700, the `hangar` user's own home is locked to
   0700 with its ACL stripped, and any other user gets a warning at start.
2. **Report which macOS user runs the worker.** Optional `runningUser` in
   `MachineReport`, set by the doctor; the Machines page shows it and warns when
   it is not `hangar`.
3. **`hangar-worker isolate`**, as in *Migration*, replacing the planned
   `scripts/worker/migrate-to-hangar-user.sh`.
4. **The curl install hands an administrator's run to `isolate`**, with
   `HANGAR_AS_CURRENT_USER=1` as the opt-out.
5. **Refuse Use This Mac for Builds unless the server runs as `hangar`**
   (`409` `dedicated_user_required`; the setup page shows the command).
6. **`docs/worker-setup.md`** describes the automated setup and the move.
7. **Merge 0.6.0** *(revised)*: `isolate` moves the cache into the `hangar`
   work directory `~/.hangar/worker` and drops path-bound DerivedData as
   `WorkDirectoryMigration` does; the configuration names that work
   directory; the install script's SHA-256 check covers the hand-off to
   `isolate`; `prepareDataDirectory` makes both directories 0700; an update
   restarts `hangar`'s agent with SIGTERM.

8. **The worker becomes a LaunchDaemon with a CI keychain** *(revised: 0.9.0, branch
   `worker-daemon`)*: `isolate` installs the daemon and the keychain, drops the
   login wait and `--no-wait`, and moves an older `hangar` agent; the worker
   unlocks the keychain and sets its partition list; the doctor reports
   `headless` and `keychainProblem`; the scheduler requires a team key to sign
   on a headless Mac; the setup page and the install script know the daemon.

None of it is verified on a real Mac yet; the list below is to be done before
merging.

## Manual verification

On a spare Mac (or after a backup), not on the live build Mac, with a Hangar
0.6.0 worker enrolled as an administrator and a warm Legilo build in
`~/.hangar/worker`:

1. `hangar-worker isolate --dry-run`: only probes run; it prints the account
   creation, the per-app `mv` into `/Users/hangar/.hangar/worker/workspaces`,
   the `rm -rf` of the path-bound DerivedData parts and the `chown`.
2. The curl install as that administrator: password shown once and found with
   `security find-generic-password -s app.hangar.worker-account -a hangar -w`;
   a server whose binary changed after the script was fetched stops with
   "SHA-256 mismatch" before anything runs.
3. *(revised: LaunchDaemon)* Without logging in as `hangar`: `isolate` reports
   the daemon running and the heartbeat as `hangar`; `sudo launchctl print
   system/app.hangar.worker` shows `state = running`; the Machines page shows
   **Runs as** `hangar`, **Xcode account** "None (no login)", "Can sign with
   its CI keychain", same machine, no new pairing. `sudo -u hangar -H
   /Users/hangar/.local/bin/hangar-worker doctor` shows `headless: true` and no
   `keychainProblem`.
4. As root: `/Users/hangar` is 0700 with no ACL; `~/.hangar` and
   `~/.hangar/worker` are 0700 and owned by `hangar`; `config.json` is 0600 and
   names `"workDirectory" : "/Users/hangar/.hangar/worker"`; the moved apps
   have no `DerivedData/Build`, `workspace-state.json`, `artifacts` or
   `checkouts`, but keep `SourcePackages/repositories`; nothing is left in the
   administrator's `~/.hangar/worker`, and the old plist and configuration are
   gone.
5. Run a Legilo build: it fetches (no clone), resolves packages from the kept
   mirrors, archives and signs (allow `codesign` once if the doctor asks).
   The log says nothing about "artifact bundle info.json not found".
   *(revised: LaunchDaemon)* With the team key: the first archive creates the
   Apple Development identity in `hangar-ci.keychain-db`, signs, exports and
   uploads with no prompt. If that very first archive fails in codesign
   (`errSecInternalComponent`), run it again: the worker set the partition
   list after the failure. With the issuer ID removed, the archive waits with
   "needs a team App Store Connect key". Run a test workflow on an iOS
   simulator: this is the one thing not tried before (a simulator from the
   `system` domain); if it fails, record how.
6. A hook that writes `/tmp/x` leaves a 0600 file owned by `hangar`; as the
   administrator, `cat /Users/hangar/.hangar/worker/...` is refused.
7. Self-update: install a newer server, wait for an idle heartbeat; the agent
   re-execs from `/Users/hangar/.local/bin/hangar-worker` and the Machines
   page shows the new build. Start a build, then install again: the update
   waits for the build.
8. SIGTERM: during a build, run the curl install again as the administrator.
   The build ends as cancelled with "hangar-worker on <Mac> was stopped
   (SIGTERM)", its job and tmp folders are gone, and the agent comes back on
   the new binary without `kickstart -k` (the log shows a clean stop).
9. Reboot: after the administrator unlocks FileVault and switches to `hangar`
   once, the worker heartbeats and signs again. *(revised: LaunchDaemon: with
   nobody logged in at all, the Machines page shows the Mac online and able to
   sign within a minute of boot, FileVault unlock aside.)*
10. Server on the same Mac: `isolate` stops when `hangar` can read
    `master.key`, and **Use This Mac for Builds** shows the command instead of
    installing.
11. *(revised: LaunchDaemon)* On a Mac set up by 0.8 (an agent and a logged-in
    `hangar`): `isolate` boots the agent out, removes its plist and starts the
    daemon; logging `hangar` out afterwards changes nothing.
