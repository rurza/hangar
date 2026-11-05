# Worker isolation

Date: 2026-11-05
Status: design, not yet implemented
Tree: branch `workflow-editor`, HEAD `9615a07761637280fb0c64e9efa7a4a7e8fadb3d`

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
   unprivileged user named `hangar`, in that user's GUI session. The interactive
   user and, on a Mac that also runs the server, the server's user are different
   accounts.
2. **Performance of a native run.** `xcodebuild` and `codesign` run on the Mac,
   against the Xcode.app already in `/Applications`. DerivedData for an app stays
   warm between that app's jobs.
3. **Little disk.** One Xcode and one set of simulator runtimes per Mac, shared.
   No second macOS, no second Xcode, no copy per job.
4. **The worker can still build, sign and upload** iOS and macOS apps, including
   the login-keychain step `codesign` already requires.
5. **Another user on the same Mac cannot read a job's files.** The home, the
   keychain, the worker token, git credentials, signing material, DerivedData
   and temp are private to `hangar`. Xcode stays readable because the build
   cannot run without it.
6. **The install and the idle self-update keep working** for that user. The
   server still hands out one `hangar-worker` binary, the file beside
   `hangar-server`. The update still replaces the worker's own copy and
   re-execs when the worker is idle.
7. **A worker already enrolled as the console user can move** without a new
   pairing and without throwing away its DerivedData. One terminal command
   during worker setup asks for the new account's password and does the
   rest. It waits if the graphical session is not logged in yet.

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

The worker setup command creates the account. It runs in the administrator's
terminal. `sudo` asks for the administrator's password, because creating a
user needs it. The command then asks for a separate password for `hangar`.
An empty password is not acceptable. Do not pass `-admin`. Hangar does not
write either password to disk, to the worker config, to argv, or to a log.
The `hangar` password is fed to the tool on stdin:

```sh
sudo sysadminctl -addUser hangar -fullName "Hangar" -shell /bin/zsh -password -
```

A password typed at the terminal does not open this user's graphical session.
loginwindow creates the `gui/<uid>` domain, the login keychain, and the unlock
that survives a reboot, and it does that only when the user actually logs in.
A keychain created and unlocked with `security` during setup locks again at
the next boot. Keeping the password on disk so a script can unlock it after
every boot would store the signing key's password next to the builds. Automatic
login as `hangar` is not a substitute: it takes the console, and on a FileVault
Mac the preboot password still comes first.

The same command therefore waits until `launchctl print gui/<hangar uid>`
succeeds. While it waits it tells the operator to switch to `hangar` once,
through fast user switching, and switch back. The `hangar` session stays
logged in. The console session stays the interactive user. The Mac still must
not sleep (`pmset`, already in the worker setup): sleep suspends both sessions.

If FileVault would stop that first login, the same command grants a secure
token before it waits, with the password it already read:

```sh
sudo sysadminctl -secureTokenOn hangar -password -
```

That grant is part of this command, not a second task.

`xcodebuild -runFirstLaunch` and `sudo xcodebuild -license accept` stay as in
`docs/worker-setup.md`. First launch runs once per Mac, as `hangar`. It is not
a copy of Xcode. The license is the system license.

The agent does not move to a LaunchDaemon, and the plist does not gain a
`UserName` key in the system domain. A daemon has no Aqua session. The login
keychain stays locked, `codesign` does not return, `canSignWithoutPrompt` stays
false, and the scheduler then assigns the machine nothing. The plist keeps
`LimitLoadToSessionType` = `Aqua`, `RunAtLoad` and `KeepAlive`, and it keeps
being bootstrapped into `gui/<hangar uid>`.

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
| Login keychain and Apple Development identity | `~/Library/Keychains` | Created by the GUI login. Persistent across jobs, as the 2026-11-04 design requires. Not copied from the console user. |
| Xcode account, provisioning profiles, per-user simulator devices | `~/Library/Developer` | Devices are small. Runtimes are the shared ones above, not a copy of this tree. An individual App Store Connect key still means signing in to Xcode once as `hangar`. |
| Worker token | `~/Library/Application Support/Hangar/worker/config.json` | Mode 0600, directory 0700, as `WorkerConfiguration.write` already does. |
| Checkouts and DerivedData | `…/worker/workspaces/<appSlug>/repository` and `…/DerivedData` | One warm cache per app per machine. Not the console user's DerivedData, and not a world-readable directory under `/Library`. |
| This user's package and Xcode caches | `~/Library/Caches` (including `org.swift.swiftpm`) | Warm across jobs. Not shared with the console user: that cache can hold their source and credentials, and a shared cache would be readable both ways. The disk cost is one cache, not an Xcode. |
| Job secrets, archive, export, result bundle | `…/worker/jobs/<jobID>/` | Secrets stay 0600 in a 0700 directory. The job directory is removed at cleanup, as today. |
| Temp | `<job directory>/tmp` | Already `TMPDIR` for the job (`CIEnvironment.temporaryDirectory`). Not `/tmp`. |
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

1. `hangar-worker run` sets `umask(0o077)` before the loop starts. Children,
   including `xcodebuild`, hooks and post-actions, inherit it. Files a job
   creates in `/tmp` or `/var/tmp` are then mode 0600, owner `hangar`, so
   another account cannot read them. The sticky bit on `/tmp` already stops
   other accounts deleting them. `WorkerSelfUpdate` sets the staged binary to
   0755 by `chmod`, which is not subject to umask, so the replaced binary stays
   executable. `setup` and the secret writer already set 0600 and 0700
   themselves. Doctor and `setup` do not change umask: they do not run repo
   code. The umask is applied in the `run` command, not in `WorkerLoop`, so
   unit tests do not change the umask of the test process.
2. `prepareDataDirectory` creates the data directory and then `chmod`s it to
   0700. Passing `posixPermissions` to `createDirectory` is not enough: an
   existing directory keeps its mode, and the attribute is subject to umask.
   The same `chmod` covers `workspaces` and `jobs` only for the directories
   `prepareDataDirectory` itself creates. It does not walk the cache.
3. Only when `NSUserName()` is `hangar` and the home is `/Users/hangar`, `run`
   sets that home to mode 0700 and strips ACLs (`chmod -N`, then `chmod 700`).
   A worker running as any other user does not touch that user's home. Tests
   must not call this against the real home: the check is the path and the
   name, and the function that applies it takes the home path so a test can
   pass a temporary directory. If the chmod fails, log it and keep running.
   Refusing to start would brick a machine over a mode bit; the migration
   script is the strict check.

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
- `TMPDIR` is the job directory's `tmp`, mode 0700, removed with the job.
- The GitHub token exists only in the environment of git and of
  `xcodebuild -resolvePackageDependencies`, as today.
- The App Store Connect key is an as-file secret under the job directory, wiped
  at cleanup, as today.
- `codesign` uses the `hangar` login keychain. The first archive on a new
  `hangar` user creates the Apple Development identity there. The operator
  allows `codesign` in Keychain Access as that user if the doctor says
  `canSignWithoutPrompt` is false. That is the existing worker-setup step, done
  once, not per job.
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

On the build Mac the `hangar` user runs the same curl install, from a Terminal
window in the `hangar` session:

```sh
curl -fsSL http://<tailnet-host>:8787/install | sh
```

The default `HANGAR_BIN_DIR` is `~/.local/bin`, which is
`/Users/hangar/.local/bin`. The script already refuses a directory it cannot
write, enrolls with the pairing code, writes the configuration as mode 0600,
and bootstraps `gui/<hangar uid>`. The plist's program is that binary. Idle
self-update can replace it, because `hangar` owns the directory, and then
re-execs. The running process keeps the old inode until the exec, as it does
today. Jobs are not interrupted: the update waits until `runningIDs` is empty.

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
`app.hangar.worker` in `gui/<hangar uid>`.

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
`dedicated_user_required` and a message that says to run the worker setup
command in a Terminal. That command asks for the password and, if needed,
waits for one switch to the `hangar` user. The setup
page (`Sources/HangarServer/Web/assets/pages/setup.js`) stops offering the
button in that case and shows the same instruction. An old page that still
posts is refused by the endpoint. No `sudo` from `hangar-server`: the server
is not root and must not write another user's home.

The curl install run by hand as the console user still enrolls. This design
does not make the worker refuse to start in that case. The warning in *Permissions*
and `runningUser` on the machine report are how the operator sees it. A hard
refusal would stop the fleet on the day this ships, before the migration.

## Migration

For a worker that is already enrolled and running as the console user. The
machine token stays. Hangar does not gain a second machine, and the operator
does not pair again. DerivedData moves, so the next build is not cold.

**One command.** `scripts/worker/migrate-to-hangar-user.sh` is what runs
during worker setup. It asks for the `hangar` password, creates the account
when it is missing, moves the token and the cache, and installs the agent.
If the graphical session is not up, it waits, as in *The user*, instead of
making the operator do those steps by hand. When the session is up and Xcode
has never been launched as that user, it runs `xcodebuild -runFirstLaunch`
there. A Mac with no checkout of this repo gets the same command from
`docs/worker-setup.md`.

`scripts/worker/migrate-to-hangar-user.sh` takes:

- `--from-home DIR`, default the invoking user's home, or `SUDO_USER`'s home
  when run under sudo. This is the account the worker runs as today.
- `--hangar-home DIR`, default `/Users/hangar`.
- `--server-data DIR`, default `<from-home>/Library/Application Support/Hangar/server`.
  Passed empty, the server check is skipped (this Mac is not the server).
- `--apply`. Without it, the script prints the plan and exits 0. With it, it
  does the work. When `id hangar` fails, it creates the user from the password
  read at the terminal. When `launchctl print gui/<hangar uid>` fails, it
  waits for that login. It does not log in by itself, and it does not enable
  automatic login.

With `--apply`, in order:

1. Read the old plist's program (`~/Library/LaunchAgents/app.hangar.worker.plist`
   under `--from-home`) and the old configuration. The configuration is the
   `--config` argument in that plist, or else
   `<from-home>/Library/Application Support/Hangar/worker/config.json`.
   Refuse if a `hangar-worker` process is still running for the old uid after
   a `launchctl bootout gui/<old uid>/app.hangar.worker`. An in-flight build
   dies with that bootout. The operator runs this when nothing important is
   building. The script says so in its plan.
2. Copy the old binary to `<hangar-home>/.local/bin/hangar-worker` with
   `install -o hangar -g staff -m 755`. If the old program path is the server's
   binary (the same path as `hangar-server`, or the file `--server-data`'s
   sibling install), copy it. Never move or delete it. Never write the new
   plist so that its program is that server path.
3. Copy the configuration to
   `<hangar-home>/Library/Application Support/Hangar/worker/config.json`,
   owner `hangar`, mode 0600, parent directories 0700. Then set the
   `dataDirectory` key to `<hangar-home>/Library/Application Support/Hangar/worker`.
   Keep `serverURL`, `token` and `maxConcurrentJobs`. Do this with `plutil` on
   the file. Do not pass the token on a command line and do not print the file.
   A custom `dataDirectory` outside the home is not preserved. That path is how
   the old files stayed readable.
4. Move `<old dataDirectory>/workspaces` to `<new dataDirectory>/workspaces`
   and `chown -R hangar:staff` it. Same-volume `mv` keeps the cache without a
   second copy. If the two homes are on different devices, copy and then
   remove, and print that DerivedData will temporarily use twice its size.
   Do not copy Xcode. Do not copy `jobs/`: after bootout those directories are
   leftovers, and the new process's startup sweep only sees the new data
   directory. Remove the old `jobs/` directory as root. Do not copy
   `~/Library/Keychains`, `~/Library/Developer`, `~/Library/Caches` or
   `~/.gitconfig` from the console user. The development identity is recreated
   by the first archive as `hangar`. Copying the login keychain would bring
   the interactive user's other keys into the build account.
5. `chmod -N` and `chmod 700` the `hangar` home. Confirm the console user
   cannot traverse it (`sudo -u <from-user> test -x <hangar-home>` must fail).
6. Write `app.hangar.worker.plist` into the `hangar` user's `LaunchAgents`
   with the same keys as `scripts/worker/app.hangar.worker.plist`: program is
   the new binary, logs are under the `hangar` home, `LimitLoadToSessionType`
   is `Aqua`. Owner `hangar`. `launchctl bootstrap gui/<hangar uid>` that plist.
7. As `hangar`, run `hangar-worker check` against the new configuration. Exit 0
   is the same machine, accepted. The token was not rotated. On any other
   exit, stop and leave the old plist in place so the operator can boot the
   old agent again. On exit 0, remove the old plist (so the console user's next
   login does not start a second worker with the same token) and remove the
   old configuration file (it holds the token). Do not remove
   `/usr/local/bin/hangar-worker`.
8. If `--server-data` is set, `sudo -u hangar test -r <server-data>/master.key`
   must fail. If it does not, print the `chmod 700` the operator should run on
   the server data directory and exit non-zero. Do not chmod it inside the
   script.
9. Print the follow-ups the script cannot do: run `hangar-worker doctor` as
   `hangar`; if `canSignWithoutPrompt` is false, the next archive creates the
   identity and Keychain Access may need the existing `codesign` click; if the
   App Store Connect key is an individual key, sign in to Xcode as `hangar`
   once; if `command -v xcodegen` (and the other tools the workflows need)
   fails as `hangar`, the Homebrew prefix is not executable by that user, and
   the operator fixes the prefix's permissions rather than installing a second
   copy.

After this, idle self-update targets `/Users/hangar/.local/bin/hangar-worker`.
The server's binary is untouched. The first build uses the moved DerivedData.

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
  there), the worker token in `config.json`, every app's cached checkout and
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
4. **The home is mode 0700, the data directory is mode 0700, and `run` sets
   umask 077.** That is what stops another account reading job files, including
   files a hook drops in `/tmp`. The worker does not recursively chmod the
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
7. **Migration keeps the machine token and moves `workspaces/`. It does not
   copy the login keychain or re-pair.** The token is the enrollment.
   `dataDirectory` inside the copied configuration is rewritten into the
   `hangar` home, or the new process would keep writing the console user's
   tree. The development identity is created again by the first archive.
   Copying the old keychain would import the interactive user's keys.
8. **Use This Mac for Builds no longer installs as the server user**, unless
   the server already runs as `hangar`. The server process must not `sudo`.
   Hand install as the console user still works; the doctor warns. The
   scheduler does not grow a new ineligibility, so the fleet keeps building
   through the move.
9. **The account is not an administrator.** A compromised build must not have
   admin or a sudoers entry. Homebrew is the machine's prefix, used in place,
   not a second install under the home.
10. **Setup is one terminal command. It takes the new account's password and
    does not store it.** The command creates the user, grants a FileVault
    secure token when the first login would otherwise stop, moves an enrolled
    worker, and installs the agent. The graphical login stays a real login:
    that is what keeps the keychain unlocked after a reboot. The command waits
    for it. A keychain unlocked only for this run, a password saved on disk,
    and automatic login are rejected.

## Open Questions

None. The choices that change what gets built are the calls above. In
particular: the account name stays `hangar`; the scheduler does not refuse a
machine for running as the wrong user; DerivedData is moved rather than left
cold; the one-click local install is refused rather than retargeted at the
other home through `sudo`.

## PR Plan

Each of these can be reviewed on its own. None of them is this document.

1. **`worker: keep the hangar user's files private`**
   - What: in `hangar-worker run`, set umask `0077` before the loop. `chmod 0700`
     the data directory in `prepareDataDirectory` (a real `chmod`, not only
     create attributes). When the process user is `hangar` and the home is
     `/Users/hangar`, set that home to 0700 and strip its ACLs. Log a warning
     when the process user is anyone else. Tests cover the chmod helper with a
     temporary directory and cover that a non-`hangar` user is not a candidate.
   - Depends on: nothing.
   - Does not change the install script, the plist, the API or self-update.

2. **`worker: report which macOS user is running the agent`**
   - What: add optional `runningUser` to `MachineReport` (`decodeIfPresent`, so
     an older worker still decodes). The doctor sets it from `NSUserName()`.
     The Machines page shows it, and shows when it is not `hangar`. An older
     server ignores the extra field (Codable's default).
   - Depends on: nothing. Lands beside PR 1, not on top of it.

3. **`worker: migrate an enrolled worker onto the hangar user`**
   - What: `scripts/worker/migrate-to-hangar-user.sh` as specified under
     *Migration*, including a no-`--apply` plan, and a "Move an existing
     worker" section in `docs/worker-setup.md` that gives the same steps for a
     Mac with no checkout. The script's `--from-home` and `--hangar-home` flags
     are what a reviewer runs against temporary directories.
   - Depends on: nothing. It performs its own `chmod`. PR 1 keeps the modes
     after the new process starts; the script is correct without it.
   - Does not delete or replace the `hangar-worker` that sits beside
     `hangar-server`.

4. **`setup: refuse to install the local worker as the server user`**
   - What: `POST /setup/local-worker` returns `409` `dedicated_user_required`
     unless the server process's user is `hangar`. The setup page does not
     offer "Use This Mac for Builds" in that case and tells the operator to
     run the worker setup command. Tests in `SetupAPITests`. Update the
     `POST /setup/local-worker` row in `docs/api.md` and the sentence in
     `docs/server-setup.md`.
   - Depends on: PR 3, so the message can point at the migration section. The
     endpoint change is otherwise independent of the worker's chmod.
