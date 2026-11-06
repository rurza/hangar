# VM builds

Date: 2026-11-05
Status: design, with a feasibility spike run on the Mac mini the same day (see *Spike results*). The first
slice is built on branch `vm-slice-1` (see *First slice as built*), proven on the mini as far as its disk allows,
and waits for the MacBook run in *Manual verification*. Design branch `vm-builds`. This supersedes the anti-goal "a full macOS VM per worker or per job" in the
worker isolation design (2026-11-05-worker-isolation-design.md) and the "VM isolation is a later executor"
deferral in the 2026-11-04 design. The `hangar` user, its LaunchDaemon and its CI keychain stay: they become
the host side of the VM executor.

**Current state (2026-11-06).** Slice 1 shipped in 0.11 and VM builds are the recommended setup
(docs/worker-setup.md); a worker run as the Mac's owner can host them too. Where the shipped code differs from
the text below:
- `sudo hangar-worker vm setup` does the host setup in one go, including `diskutil enableOwnership` for an
  external volume and the network filter (`vm network install`, see *First slice as built*); `isolate` does
  neither.
- The image build is `hangar-worker vm image build`, from the command line only; there is no Machines-page
  build and no `executor` switch: VM builds are on when the worker's configuration has a `vm` section
  (decision 1 of *First slice as built*), and the owner allows them per machine on the server.
- Partial images are `images/.partial-<name>`, not `.building-<name>`.
- The guest's work directory is `/Volumes/workspace/hangar` (the image's workspace volume), else
  `/Users/builder/hangar`.
- VM archives sign with the server's one Apple Development identity, not one per worker (the revision under
  *Signing* replaces key decision 7).

## Intent

Every build starts from scratch. The build machine is assumed to have macOS and Xcode and nothing else, the
way Xcode Cloud runs each build in a fresh macOS VM with Homebrew preinstalled and writable by the build user.
Scripts written for Xcode Cloud (`ci_scripts/ci_post_clone.sh` and friends) do
`export PATH=/opt/homebrew/bin:$PATH; brew install …`. Under the `hangar` user that fails: `/opt/homebrew`
belongs to the interactive user. Legilo build 99 failed exactly there on both Macs.

macOS has no namespaces and no containers for macOS userlands. Apple's Containerization framework runs Linux
guests only. The only way to give a build its own writable `/opt/homebrew`, its own users and its own
`/Applications` without touching the host is a macOS VM. So each job runs in a fresh macOS VM on
Virtualization.framework, cloned from a prepared image and thrown away afterwards.

The same Macs are the owner's workstations: coding agents, feature work, T3 Code. A build must not see or
change that environment. The target is a balance of speed (a job's VM is ready in seconds, not minutes),
security (the guest cannot reach the host's files, the server's master key, the owner's tools or the LAN) and
stability (a hung or crashed VM never leaves the Mac in a state that needs a person).

## Goals

1. **Fresh per job.** Each job gets a VM whose disk is an APFS clone of a prepared image and whose memory
   is restored from a saved state. Nothing a job writes reaches the next job. The clone is deleted when the
   job ends, however it ends.
2. **Xcode Cloud compatibility.** In the guest, a non-administrator build user owns `/opt/homebrew`, and
   `brew` is on hand and works without sudo. `ci_post_clone.sh`, `ci_pre_xcodebuild.sh` and
   `ci_post_xcodebuild.sh` run unchanged. The `CI_*` variables are the ones the worker already sets.
3. **Ready in seconds.** From the job being claimed to a shell in the guest: under 10 s with a saved state,
   under 30 s on a cold boot fallback. The spike measured 2.3 to 5.9 s and 13.5 to 19.3 s.
4. **The host is off limits.** The guest has no share of the host's home, no route to the host's listening
   sockets, the LAN or the tailnet, and never holds the worker's machine token or the server's master key.
5. **Secrets only for the job.** The git token, the App Store Connect key and the signing identity enter the
   guest when the job starts and disappear with the VM. Nothing secret is in an image or a saved state.
6. **Self-healing.** A hung guest is stopped by the job timeout, a crashed worker takes its VMs with it, and
   a worker restart sweeps leftover clones. A host macOS update that invalidates saved states falls back to
   a cold boot and saves new states without help.
7. **Machines advertise what they can run.** VM slots, free slots and the Xcode versions (with simulator
   runtimes) their images contain. The scheduler matches a workflow's `xcode:` against images, not against
   `/Applications`.

## Non-goals

- Warm DerivedData. The owner accepted cold builds. Package caching is a later, read-only addition (see
  *Caching*).
- Linux guests, x86 guests, or building for anything but Apple platforms.
- A cluster scheduler (Orchard, Anka Controller). The Hangar server already schedules jobs to machines.
  This only changes what a machine does with one.
- Removing the host executor in the first slice. It stays, behind a per-machine setting, until VM jobs have
  proven themselves (see *Migration*).
- Hiding anything from the operator. The operator is an administrator of the host.

## Anti-goals

- Shipping images with Xcode in them to a public registry. Xcode's license allows installing it on Apple
  hardware the operator owns, and the macOS license allows macOS guests there. Redistributing an image with
  Xcode in it is a different matter. Images are built on, or copied between, the operator's own Macs.
- A guest that shares the host's `/Applications/Xcode.app`, simulator runtimes or Homebrew at run time. That
  is the coupling this design removes. The image *copies* them once, at image build time.
- Copying anything from a finished guest back into the host or into an image (DerivedData, package caches,
  Homebrew bottles). That lets one build poison every later one. Caches flow host → guest, read-only, never
  back.
- Creating a signing certificate per VM or per job. Apple limits development certificates per team. See
  *Signing*.
- A guest that can reach the Hangar server's API with anything but a token scoped to its own job.

## Current state

- The worker is a LaunchDaemon running as the unprivileged `hangar` user (0.9.0). It polls the server with
  its machine token, runs one job at a time through `JobPipeline` (checkout, the `ci_*` hooks, `xcodebuild`
  archive/test/export, the TestFlight post-action), streams logs and uploads artifacts. Steps run commands
  through the `ProcessRunner` protocol. Secrets arrive in `JobAssignment.environment` and are written to
  files by `SecretsMaterializer`.
- Signing uses a CI keychain in `/Users/hangar` and needs a team App Store Connect key with an issuer ID
  (headless: no Xcode account). With `-allowProvisioningUpdates`, the first archive creates an Apple
  Development identity in that keychain.
- `MachineReport` carries Xcode versions, tools, simulator runtimes, free disk, capabilities and signing
  readiness. The scheduler's `Ineligibility` explains why a machine cannot take a job.
- A workflow names `xcode:` and `tools:` in `.hangar.yml`. `tools:` is checked against the machine.
- The mini (rurzomac-mini): M4, 10 cores, 16 GB, macOS 26.7.2, about 77 GB free of 228 GB, internal disk
  only. The MacBook Pro (rurzobuk-max): M3 Max, 48 GB, macOS 27.2. Both run Xcode 27.2. Xcode 27.2 needs
  macOS 26.6 or later.

## Spike results

Run on the mini on 2026-11-05 as the interactive user, in a scratch directory, with a watchdog that stopped
anything big when free space fell to 40 GiB. Every number here was measured. Nothing was kept: free space
was 77 GiB before and after.

**Entitlement.** A command-line tool built with `swiftc` and signed ad hoc
(`codesign -s - --entitlements` with `com.apple.security.virtualization`) creates and runs macOS VMs. The
same binary without the entitlement fails `validate()` with "The process doesn't have the
'com.apple.security.virtualization' entitlement". No paid certificate, no provisioning profile. The
entitlement is not restricted.

**Restore image.** `VZMacOSRestoreImage.fetchLatestSupported` on the mini returns macOS 26.6.2 (25G83), a
19.77 GB IPSW. That is older than the host (26.7.2): the "latest supported" image lags point releases.
Minimum 2 CPUs and 4 GB. Download: 230 s, about 86 MB/s.

**Install from IPSW: started, not finished.** Loading the IPSW took 0.4 s. `VZMacOSInstaller` went from 0
to 75 % in 80 s, and by then the sparse disk image held 17 GiB. The watchdog stopped it at the 40 GiB
floor: the IPSW (18.4 GiB) plus the installed disk (an estimated 20 to 22 GiB) does not fit on the mini
next to the floor. A killed install also left 1 GiB of extracted IPSW under
`$TMPDIR/com.apple.Virtualization.Installation.*`, which nothing cleans up.

**Prebuilt image instead.** `ghcr.io/cirruslabs/macos-tahoe-vanilla:26.6.2`, pulled with Tart 2.41.1 into
a scratch `TART_HOME`: 24.0 GB compressed, 265 s, 26 GiB on disk (50 GB nominal). macOS with Setup
Assistant done, user `admin`, SSH on, passwordless sudo. Cirrus also publishes
`macos-tahoe-xcode:27.2`. It is 70.8 GB compressed, 140 GB nominal, and does not fit on the mini at all.

| Step (4 vCPU, 4 GB guest) | Measured |
|---|---|
| APFS clone (`cp -c`) of the 47 GB disk image | 0.013 to 0.015 s |
| Cold boot: `start()` returns | 0.15 to 0.33 s |
| Cold boot: DHCP lease | 6.1 to 6.3 s |
| Cold boot: SSH command succeeds | 19.3 s first boot, 13.5 to 23.0 s later (13.5 s from a Background launchd session) |
| Cold boot while another VM runs | 27.0 to 36.7 s |
| Save state (paused) | 2.05 to 2.17 s, 1.3 to 1.4 GB file |
| Restore state onto a fresh clone | 1.5 to 4.9 s |
| Clone + restore to an SSH command succeeding | 2.3 to 5.9 s (typically 4.5 s) |
| Two restored VMs at once, each to SSH | 4.6 s and 5.0 s |

**Save and restore constraints found:**

- A saved state restores onto an APFS clone of the disk it was saved with. Every restore onto a fresh clone
  (about a dozen) worked.
- The configuration must match the saved one exactly. A different MAC address, a different memory size,
  or an added virtio-fs device each fail with `VZErrorDomain` 12, "invalid argument".
- A virtio-fs device present at save time can point at a *different host directory* on restore (same tag).
  The guest saw the new directory's files. The share was read-only in the guest ("Operation not permitted").
- The auxiliary storage (NVRAM) file is locked while a VM runs. A second VM using the same file fails with
  "Failed to lock auxiliary storage". Each VM needs its own clone of it.
- Two VMs restored from states that share a machine identifier cannot run together. The second restore
  fails with "invalid argument". A cold boot with the same identifier next to a running restored VM worked.
  With a different machine identifier and MAC per state, two restored VMs ran side by side.
- A third VM fails with `VZErrorDomain` 6, "The maximum supported number of active virtual machines has been
  reached". Apple's limit of two is enforced. Whether the count spans macOS users was not tested.
- After a restore, the guest's wall clock matched the host's to the second. Its uptime and load average are
  those of the moment of the save.
- A state saved from the interactive GUI session restored from a launchd job in the Background session with
  `SessionCreate`, the context closest to the `hangar` LaunchDaemon that does not need root.
- `kill -9` of the process that owns the VM ends the VM's XPC process (`com.apple.Virtualization.VirtualMachine`)
  within seconds. A crashed worker leaves clones on disk, but no running VM.

**Network (NAT attachment, the default).** The guest got 192.168.64.x with DNS at 192.168.64.1, and
`https://github.com` answered in 0.5 s. From the guest, these were *reachable*: the host's T3 Code (port 3773)
through both 192.168.64.1 and the host's LAN address, the host's sshd and AirPlay receiver, the Hangar
server through the host's Tailscale address (100.71.242.42:8787), and the LAN router's admin page. A NAT
guest sees everything the host listens on and everything the host can route to. This is not acceptable for
untrusted builds, and it is why *Network* below is not optional.

**Xcode Cloud layout in a guest.** In a restored clone: a non-administrator user `builder`, `/opt/homebrew`
owned by it, Homebrew fetched as a tarball, then `brew install xcodegen` as `builder` without sudo: 43 s from
nothing to `xcodegen --version`, 237 MB for Homebrew with the formula.

**Copying Xcode into a guest.** The host's Xcode 27.2 is 3.7 GB on disk and 8.9 GB uncompressed (its files
are transparently compressed). `ditto` from a read-only virtio-fs share of `/Applications/Xcode.app` failed on
hundreds of entries with "Too many levels of symbolic links", and wrote uncompressed. The watchdog stopped
it. Relative, `../` and absolute symlinks in a small test share resolved fine, so the cause is still open. A
`tar` stream over SSH, extracted with `--hfsCompression`, kept the compression (2.7 GB of the toolchain
became 1.1 GB on the guest's disk) at about 55 MB/s. All of Xcode would take about 3 minutes. `xcodebuild` in
a guest with a copied Xcode was not run: the disk floor did not allow the full copy.

**Tart's license.** Tart moved to `github.com/openai/tart` after Cirrus Labs joined OpenAI (April 2026).
The LICENSE file is now the Functional Source License 1.1 with an Apache 2.0 future license (FSL-1.1-ALv2):
any purpose except a "Competing Use" (offering Tart, or something substantially similar, commercially to
others), with each release becoming Apache 2.0 after two years. Internal use, Hangar's case, is permitted.
The older tart.run licensing page (a free tier of 100 CPU cores, paid tiers above) describes the
pre-acquisition terms. The announcement says the fees were dropped.

## Options

### Engine

**Our own Swift code on Virtualization.framework, in the worker. Chosen.**

The API surface Hangar needs is small and measured above: `VZMacPlatformConfiguration` from saved
hardware-model and machine-identifier data, a disk attachment, an NVRAM file, NAT networking, one virtio-fs
device, a vsock device, `start`, `pause`, `saveMachineStateTo`, `restoreMachineStateFrom`, `resume`, `stop`.
The spike tool that did all of it is about 200 lines. Owning it gives:

- **Typed failures.** "Invalid argument" on restore means "this state is stale, cold-boot and save a new
  one". "Maximum number of VMs" means "another VM on this Mac holds a slot". That decides what the worker
  does next. Through a CLI it is stderr text.
- **Slots built for save/restore.** The constraints above (one machine identifier and MAC per saved state, a
  per-VM NVRAM clone, a configuration identical to the saved one) are how Hangar must lay out its files.
  Tart's `suspend` keeps one state per VM and does not model "N restorable slots from one image".
- **One binary.** The worker stays the one file the server hands out and the idle self-update replaces. It
  is signed ad hoc with the virtualization entitlement at release (the spike showed this is enough), and the
  SHA-256 the self-update compares is taken after signing.
- **No external dependency in a root-installed daemon.** Tart would be another binary under `hangar`,
  updated by Homebrew, from a vendor whose plans changed this year.

The on-disk layout of an image is Tart's (`config.json` with base64 `hardwareModel` and `ecid`, `disk.img`
raw, `nvram.bin`), so `tart run` can open a Hangar image to debug it, and Tart-format OCI images import as
they are.

**Depending on Tart (CLI). Rejected as the runtime, kept as a tool.** The license is no longer the blocker:
FSL-1.1-ALv2 permits internal use, and Hangar is self-hosted. What remains: shelling out and parsing output
for every lifecycle step, no direct access to save/restore per slot, a second binary to install and keep in
step, and an owner whose roadmap for Tart is unpublished. Tart stays useful by hand: pulling an image to
inspect, `tart run` to open an image in a window.

**Anka, Orka, Parallels, UTM. Rejected.** Anka and Orka are commercial fleet products with their own
controllers. Parallels needs a license per Mac and a GUI app. UTM is QEMU plus VZ, aimed at desktop use.
Each is a larger dependency than the 200 lines it would replace.

### How the worker talks to the guest

**Option A: the guest runs `hangar-worker` in a one-job mode, and the host supervises. Chosen.**

The guest runs the existing `JobPipeline` against its own disk, unchanged: checkout, hooks, xcodebuild,
export, artifacts, the TestFlight post-action. The host worker claims the job, prepares the VM, hands the
guest a job-scoped token and the signing material, relays the guest's API calls to the server, enforces the
timeout and deletes the VM. The pipeline, about 80 % of the worker, is reused as it is. Logs and step
statuses reach the server through the same `ServerConnection` code they use today.

**Option B: the host worker runs the pipeline and drives the guest over SSH or vsock. Rejected.** Every
`ProcessRunner` call would become a remote exec, and every `FileManager` call in the steps (secrets
materializing, artifact collection, the workspace layout, build number stamping) would need a remote
equivalent. It would be a rewrite of the steps behind a remote-filesystem abstraction, for no security gain:
the secrets enter the guest either way, because xcodebuild runs there.

**What the guest holds in option A:** a token valid only for its job (read its assignment, post that job's
steps, logs and artifacts, finish it), revoked when the job finishes or the host reports the VM gone. Never
the machine token, never the server's address on the network: the guest reaches the server only through the
host (see *Network*).

## Decision

**A macOS VM per job, on Virtualization.framework, driven by the worker's own code. Each job runs on an
APFS clone of a per-Xcode image, restored from a saved state, and the guest runs the existing pipeline with
a one-job token.** The host keeps the `hangar` LaunchDaemon, the CI keychain (now only a store for the
identity it injects) and the machine token. Images are built on each Mac from a vanilla macOS image plus
the host's own Xcode. Saved states are per Mac and per slot.

## How it works

### Image storage

`vmStorage` in the worker configuration, default `/Users/hangar/.hangar/vm`. It must be an APFS volume:
clones only work within one volume, so images, slot states and job clones all live on it. An external SSD
works (Thunderbolt or USB4, APFS). The worker checks the volume is APFS and that ownership is enabled
(`diskutil info` → "Owners: Enabled"). External volumes default to ignoring ownership, which would make a
running job's clone, with its secrets, readable by every local user. On such a volume `isolate` runs
`diskutil enableOwnership` (it already runs as root). FileVault or an encrypted APFS volume is recommended:
a deleted clone is not scrubbed.

```
vm/
  images/<name>/            config.json  disk.img  nvram.bin  image.json (macOS build, Xcode, runtimes, digest)
  images/<name>/slots/<n>/  disk.img (clone)  nvram.bin (clone)  mid.bin  state.vzstate  slot.json (MAC, CPU, memory)
  jobs/<job-id>/            disk.img (clone)  nvram.bin (clone)  share/  (deleted when the job ends)
```

The directory is 0700, owned by `hangar`.

### Base image pipeline

Two layers, both on the Mac that uses them.

**1. Vanilla macOS** (`vanilla-26.6.2`): macOS with Setup Assistant done, an `admin` user, SSH on. Getting
past Setup Assistant is the one step Apple gives no API for. Options, honestly ranked:

- **Import Cirrus's vanilla image (first slice).** `hangar-worker vm import
  ghcr.io/cirruslabs/macos-tahoe-vanilla:26.6.2@sha256:…`: an OCI pull (Tart's format: LZ4 disk chunks
  written straight into a sparse `disk.img`, no compressed copy kept). It is pinned by digest. Measured
  4.5 minutes and 26 GiB. It trusts an image published by Cirrus/OpenAI, built from their open Packer
  template. That is the same trust as installing Tart. Mitigated because the image only seeds a build
  user's VM: its `admin` password is replaced before any job, and nothing in it is trusted with a secret.
- **IPSW plus a person (second slice).** `hangar-worker vm create --ipsw latest` installs (measured: 75 %
  in 80 s), then opens the VM in a window in the operator's GUI session. The operator clicks through Setup
  Assistant once per macOS version (about 3 minutes, a checklist on screen) and turns on Remote Login. No
  third-party image. It needs about 40 GiB free during the install (IPSW plus disk), which the mini only
  has with an external SSD.
- **IPSW plus scripted keystrokes (later, maybe).** What Cirrus's Packer template does, through Tart's VNC
  server: about 40 timed keystroke steps per macOS release, which break when Setup Assistant changes. We
  could drive a `VZVirtualMachineView` in an offscreen window with synthesized key events, but that needs a
  GUI session and the same per-release maintenance. Not worth it for two Macs.
- **Patching the guest volume offline** (`.AppleSetupDone`, a user record and a launch daemon written into
  the mounted disk image). Rejected: it needs root on the host to write root-owned files, depends on
  undocumented local directory formats, and it was not tried.

**2. Xcode image** (`xcode-27.2`), provisioned over SSH as `admin` from a clone of the vanilla image (an
APFS clone, so the two share blocks):

1. Replace `admin`'s password with a random one kept only in the host CI keychain, install the host's
   provisioning SSH key, and turn off password authentication. The vanilla image's `admin`/`admin` must not
   survive into a job image: the build user could `su` with it.
2. Create `builder`: standard user, not an administrator, no sudo. Turn on automatic login for `builder`,
   so the saved state contains its logged-in GUI session (simulators and UI tests expect one, as on Xcode
   Cloud).
3. `/opt/homebrew` owned by `builder`, Homebrew installed from its tarball, `brew update` done once, and
   `HOMEBREW_NO_AUTO_UPDATE=1` set for jobs. Measured: a formula install then takes about 40 s.
4. Xcode: the host's `/Applications/Xcode_<version>.app` (or `Xcode.app` when that is the version), streamed
   with `tar | ssh 'tar --hfsCompression -x'`. Measured at 55 MB/s, so about 3 minutes for Xcode 27.2's
   8.9 GB, which keeps its compressed size. A `.xip` the operator downloads works too (`xip -x` in the
   guest). Downloading Xcode in the guest is rejected: it needs an Apple ID.
5. `xcode-select -s`, `xcodebuild -license accept`, `xcodebuild -runFirstLaunch`, the Metal toolchain
   component, and the simulator platforms the workflows need: `xcodebuild -downloadPlatform iOS` in the
   guest, or `-exportPath` on the host and `-importPlatform` in the guest to avoid downloading twice.
6. The guest agent (see *Control channel*) as a LaunchDaemon. Spotlight indexing off (`mdutil -a -i off`),
   sleep and screen lock off, software update checks off.
7. Shut down. Record `image.json`: macOS build, Xcode version and build, runtimes, sizes, the vanilla
   digest.

Size estimate per Xcode image: macOS 26 GiB, Xcode 3.7 GiB, an iOS simulator runtime about 8 to 17 GiB
(the host's iOS 24 runtime volume holds 17 GiB), the Metal toolchain about 3 GiB, Homebrew 0.3 GiB: **about
45 to 50 GiB on disk**, 60 to 140 GB nominal. Two Xcode images built on one vanilla share the macOS blocks,
so the second costs about 25 GiB. Building one takes about 15 to 30 minutes, mostly the runtime download.
`hangar-worker vm build-image --xcode 27.2` runs the pipeline and can be started from the Machines page.

**Saved states, one per slot.** For each slot `n`: clone the image's disk and NVRAM, give the slot its own
machine identifier and its own locally administered MAC (`02:68:67:<machine>:<slot>:00`), cold boot with the
slot's CPU and memory, wait for `builder`'s session and for the guest to settle (load below 1 for 30 s, which
is why Spotlight is off: the spike's guest was at load 54 a minute after boot), pause, save. Keep
that slot disk and NVRAM next to the state. They cost the blocks the boot changed plus the state file (1.3
GiB for 4 GB of memory, more for 8 GB).

States are encrypted with a key tied to the host (Apple's documentation), so they are made on the Mac that
restores them and never copied. Whether they are also tied to the macOS user is not known (see *Open
questions*). They are made by the `hangar` daemon itself, which also restores them.

### Per-job lifecycle

1. **Claim.** The host worker claims a job for a free slot of an image with the workflow's Xcode, as today.
2. **Clone.** `clonefile` the slot's `disk.img` and `nvram.bin` into `jobs/<id>/` (measured 0.015 s).
3. **Restore.** Configuration identical to the slot's (CPU, memory, MAC, machine identifier, NVRAM path
   pointing at the clone, one virtio-fs device whose host directory is `jobs/<id>/share/`), then
   `restoreMachineStateFrom` and `resume` (measured 1.5 to 4.9 s). On "invalid argument" (a stale state
   after a host update, or an image changed under it): cold boot this job's clone instead (about 15 to 20 s,
   plus the settle wait), and mark the slot to save a new state when it is next idle.
4. **Hand over.** Over the control channel: set the clock (the spike saw it right, but this is cheap
   insurance), write fresh entropy into `/dev/random` (every clone resumes with the same RNG state), give the
   guest its hostname, and deliver the job bundle. The bundle holds the job ID, the job-scoped token, the
   `hangar-worker` binary the host runs (so the image never needs rebuilding for a worker update), the
   signing `.p12` and its password, and the App Store Connect key file. The share directory carries only
   non-secret files. Secrets go over the control channel into a 0700 directory of `builder`'s.
5. **Run.** In the guest, as `builder`: `hangar-worker run-job --job <id>`, with the server reached through
   the host relay. The guest runs the job's pipeline and streams logs as today.
6. **Collect.** Artifacts upload from the guest through the same relay, as `upload-artifacts` does today.
   The host does not copy files out of the guest. *(Revised 2026-11-06 for archives: the host copies the archive,
   the result bundle, the TestFlight notes and the full log out, exports and uploads them itself; see decision 19
   of* First slice as built.*)*
7. **Destroy.** `stop()` (a hard stop: nothing in the guest is worth a clean shutdown), revoke the job token,
   delete `jobs/<id>/`. On every path: success, failure, cancel, timeout, host shutdown.

Target from claim to a shell in the guest: under 10 s. Measured end to end without the hand-over: 2.3 to
5.9 s.

### Control channel

**First slice: SSH over the NAT network, host to guest only.** It is proven by the spike and needs nothing
new in the guest. The host's provisioning key logs in as `admin` to set up and as `builder` to run the job.
Host-to-guest connections are allowed by the network rules. Guest-to-host ones are not.

**Then: a guest agent over virtio-vsock.** `hangar-worker guest-agent` listens on a vsock port in the guest,
and the host connects through `VZVirtioSocketDevice`. No network path, no sshd in job images, and the same
binary. It also carries the server relay: in the guest, the agent listens on `127.0.0.1:8787`, and each
connection is forwarded over vsock to the host worker, which forwards it to the server. The guest's server
URL is `http://127.0.0.1:8787`. Not yet proven: that a vsock listener in the guest keeps working across
save and restore. That is the first thing to test in the vsock slice, and SSH stays the fallback.

**The relay, either way.** The host worker forwards the guest's HTTP requests to the server. It is a good
place to check that each request carries the job's token, so a guest cannot reach any other API even if
the server's scoping had a bug. In the SSH slice, it is a remote port forward (`ssh -R`) to a host-side
listener of the worker's.

### Signing

The team App Store Connect key with an issuer ID is configured. Cloud-managed distribution signing during
`-exportArchive` needs no local distribution key. Archiving still needs an Apple Development identity in a
keychain.

- **One identity for the whole server, created explicitly, once.** *(Revised 2026-11-06, owner's call; this
  replaces "one identity per worker".)* The owner has live apps and will not have Hangar minting
  certificates per build or per Mac, nor importing one per worker by hand. The Hangar server keeps one
  Apple Development identity and hands it to every VM archive. See *Server-managed identity* below.
- **Injected per job.** The server puts the `.p12` and its password in the archive's assignment, which the
  host passes to the guest in the job bundle over the SSH session's standard input. The guest worker creates a temporary keychain
  (random password), imports it, sets the partition list (`apple-tool:,apple:,codesign:`, as `CIKeychain`
  does today), puts it first on the search list, and passes the ASC key to xcodebuild as today.
  Provisioning profiles are downloaded per job by `-allowProvisioningUpdates`, which adds a few seconds.
- **Gone with the VM.** The keychain lives on the clone, and the clone is deleted. The `.p12` file is
  removed after import anyway.
- *(Revised 2026-11-06: no App Store Connect key enters a guest; it archives with server-provided profiles, and the
  host exports and uploads. See decisions 19 to 23 of* First slice as built.*)*
- The private key does enter every guest. A malicious build can copy it out during its run, exactly as it
  can on the host today. *(Revised 2026-11-06: it is now imported non-extractable, decision 22; a build can still
  sign with it during its run, not take it away.)* That is a development identity, revocable, and it can't publish to the App Store
  alone. The distribution identity stays with Apple (cloud-managed).

#### Server-managed identity

Decided 2026-11-06, built on branch `managed-identity`:

1. **One identity per server, not per worker, VM or job.** It is stored in the server's database, the `.p12`
   and its password each sealed with `master.key` (AES-GCM, as secret variables), with what the certificate
   says about itself: name, team, serial, expiry, when, and whether Hangar created it (with its App Store
   Connect ID) or the owner imported it.
2. **Created only on an explicit owner action, at most once.** Settings › Signing ("Create Hangar's Signing
   Certificate", behind a confirmation) or `hangar signing create --yes`. Never automatically, never from a
   job or a worker, never from an MCP tool or any API token (the routes have no token scope). The server
   makes an RSA 2048 key in process (Security framework, no keychain), a CSR with `/usr/bin/openssl`, and
   calls `POST /v1/certificates` with `certificateType: DEVELOPMENT`, the "Apple Development" type (the API
   has no `APPLE_DEVELOPMENT`; the per-platform types are legacy). That needs the team key: individual keys
   cannot use the provisioning endpoints. Key and `.p12` work happens in a 0700 directory under the data
   directory, files 0600, passwords on standard input only; the directory is deleted afterwards and swept at
   start-up.
3. **Duplicates are refused.** A valid identity refuses another (`409`) until it is within 30 days of
   expiring. As a backstop the server creates at most one certificate per 24 hours whatever else happens
   (`429`), counted from the request; a definite 4xx refusal from App Store Connect does not count.
4. **Renewal is the same action, only in the last 30 days (or after expiry).** It creates the new
   certificate, switches to it, then revokes the old one only if Hangar created it, by the App Store Connect
   ID it stored; never any other certificate. A failed revoke is reported; the new identity stays in use.
5. **Import instead of create.** Settings › Signing › Import .p12 or `hangar signing import`: an existing
   Apple Development `.p12` (key and certificate checked to match, not expired). Nothing is created at Apple,
   and Hangar never revokes an imported certificate. It is repacked under a password of the server's, so the
   owner's is not kept. Import is refused while an identity is stored: remove it first.
6. **Remove deletes the stored copy only.** It does not revoke the certificate, and says so. It does not
   reset the 24-hour guard.
7. **Delivery.** Only an archive assigned to a machine whose report has `vm` gets `signingIdentity` in its
   `JobAssignment`; host workers and test jobs never do. The host worker moves it out of the assignment into
   the guest bundle, and the guest's temporary keychain imports it as before.
8. **The per-worker identity stays, as an override.** `hangar-worker vm identity import|from-keychain` still
   store one next to the worker's configuration; when present it wins over the server's, and the VM report
   says so (`ownIdentity`). Kept because it costs a few lines and lets one Mac use a different identity
   without touching the server; removing it is a later clean-up if nobody uses it.
9. **Scheduling.** The VM doctor no longer needs any identity. A VM archive is held back only when the
   server has no usable identity (none, or expired) and the worker has no override; the queue note and the
   deploy check point at Settings › Signing. Host workers are unchanged: they sign with their own keychain.
10. **Distribution signing is untouched.** Exports stay cloud-managed (`-allowProvisioningUpdates` with the
    App Store Connect key).

### Caching

Speed without leaking state means caches go host → guest, read-only, and are written only by the host,
never by a build.

- **First slice: nothing.** DerivedData is cold (accepted), packages resolve from the network.
- **Later: a package mirror.** The host keeps bare git mirrors of the package URLs in each app's
  `Package.resolved` (`git clone --mirror`/`fetch`, which runs no package code). It is mounted read-only into
  the guest through the virtio-fs device. In the guest, SPM resolves against it with `url.<mirror>.insteadOf`
  git configuration, or by copying into `-clonedSourcePackagesDirPath`. The mirror only adds commits fetched
  from the real remote, so a build cannot poison it.
- **Later: Homebrew downloads.** A read-only share as `HOMEBREW_CACHE` source, filled by the host from the
  formulae jobs used. Same rule.
- **Never:** anything copied out of a guest.

### Network

The spike showed a NAT guest reaches the host's T3 Code, sshd, AirPlay, the Hangar server through Tailscale,
and the LAN. Filtering is part of the first slice, not a later hardening.

- **Attachment:** `VZNATNetworkDeviceAttachment`. No extra entitlement. Bridged needs
  `com.apple.vm.networking`, which Apple grants on request. macOS 26's `VZVmnetNetworkDeviceAttachment`
  adds custom networks but no destination filtering, and it needs a vmnet entitlement.
- **Filtering: a pf anchor.** `/etc/pf.conf` already evaluates `anchor "com.apple/*"`. `isolate` (root)
  installs `/Library/LaunchDaemons/app.hangar.pf.plist`, which loads `com.apple/250.HangarVM` at boot and
  enables pf. The rules: on the VM bridge, from the guest subnet, allow UDP/TCP 53 to the gateway; block to
  the gateway and every host address; block 10/8, 172.16/12, 192.168/16, 100.64/10 (Tailscale), 169.254/16,
  224/4 and the IPv6 equivalents; allow everything else (GitHub, Apple, Homebrew, package hosts). The worker
  reads the actual bridge subnet (192.168.64.0/24 unless changed in `com.apple.vmnet`) and checks the
  anchor is loaded before it starts a VM. A Mac whose anchor is missing reports no VM slots: no VM jobs
  without filtering.
- **The server** is reached only through the host relay, never by address.
- **Guest to guest:** blocked by the same RFC 1918 rule (the guests share a subnet).
- The guest's sshd (first slice) listens on the NAT subnet only, and only the host can open connections into
  it.

### Security summary

| Asset | How the guest is kept from it |
|---|---|
| Host files (owner's home, `/Users/hangar`, the server's data and master key) | No share but the per-job directory, read-only and holding no secrets. VZ gives no other host file access. |
| Host services (T3 Code, sshd, Postgres, AirPlay), LAN, tailnet | pf anchor. The worker refuses VM jobs without it. |
| Worker machine token, other jobs | One-job token, revoked at the end. The relay checks it. |
| Secrets of earlier jobs | Fresh clone and fresh memory state per job. Secrets are never in an image or a state. |
| A VM escape | The VM process runs as `hangar`, not as the owner and not as root. |

### Resources

| Mac | Slots | Per VM | Left for the host |
|---|---|---|---|
| mini (M4, 10 cores, 16 GB) | 1 | 6 vCPU, 8 GB | 8 GB for the server, Postgres and the owner |
| MacBook Pro (M3 Max, 48 GB) | 2 | 6 vCPU, 14 GB | 20 GB for the owner's work |

`vmSlots`, `vmCPUs` and `vmMemoryGB` in the worker configuration. Memory is part of the saved state, so
changing it re-saves the slot states. A memory balloon device is configured but not used at first. Apple's
limit of two running macOS VMs per Mac caps slots at two, and a VM the owner runs (Tart, UTM) takes one. The
worker treats "maximum number of VMs" as "slot busy, retry in a minute", not as a job failure.

### Disk budget

Per Mac: Xcode image about 45 to 50 GiB (a second Xcode about 25 GiB more), per slot a state file (1.3 GiB
measured at 4 GB, an estimated 2 to 4 GiB at 8 to 14 GB) plus the blocks the slot's boot changed (about
1 GiB), and per running job the clone's growth: the checkout, DerivedData and the archive, 2 to 20 GiB,
freed when the job ends. Building an image temporarily needs the vanilla image plus Xcode plus a runtime
download.

The mini cannot hold an Xcode image on its internal disk above the owner's 40 GiB floor (77 GiB free now).
**On the mini, VM builds need an external APFS SSD** (or freed space). The MacBook's free space decides
the same there. The worker refuses a job when free space on `vmStorage` would fall below the job reserve
(`vmJobReserveGB`, default 25) plus the floor (`vmFloorGB`, default 40 on a shared Mac), and reports this as
the existing `lowDisk` ineligibility.

### Failure handling

- **One child process per VM.** The worker starts `hangar-worker vm-host --job <id>`, which owns the
  `VZVirtualMachine` on its own run loop. Its stdin is a pipe from the worker, and EOF means the worker
  died, so it stops the VM and exits. `kill -9` of the VM's owner ends the VM (measured), so even a
  SIGKILL of the child leaves nothing running.
- **Hung guest.** The job's timeout (as today) and a guest heartbeat over the control channel (30 s). Either
  one stops the VM, and the job fails with "the build VM stopped responding" or the timeout reason.
- **Guest crash** (`didStopWithError`, or a guest stop before the job finished): the job fails with that
  reason. The clone is deleted.
- **Worker start and reboot.** Before polling: delete every `jobs/*` (no VM survives its process), delete
  `$TMPDIR/com.apple.Virtualization.Installation.*` left by a killed image install (the spike left 1 GiB
  there), report jobs that were running as lost (existing behavior). Saved states survive a reboot.
- **Host macOS update.** Restore may fail with "invalid argument": the job cold-boots, and the slot is
  re-saved when it is idle. The doctor reports stale slots.
- **Image build failure.** Builds go into `images/.building-<name>`, renamed only when complete. A failed
  build is deleted.

### Scheduler and reporting

`MachineReport` gains a `vm` section (optional, nil from older workers): `slots`, `freeSlots`, `storageFreeGB`,
`networkFilter` (anchor loaded), and `images: [{name, macOS, xcode, xcodeBuild, simulatorRuntimes,
tools}]`, where `tools` is what the image's Homebrew has preinstalled.

- A workflow runs in a VM on a machine whose worker reports VM slots and whose machine setting `executor`
  is `vm`. On such a machine, `xcode:` matches against `vm.images[].xcode`, and simulator destinations
  against the image's runtimes. `tools:` stops being a host requirement in VM mode: a `ci_post_clone.sh`
  installs what it needs, as on Xcode Cloud.
- New ineligibilities: `noVMImage(xcode)` ("no VM image with Xcode 27.2 on this Mac"), `vmSlotsBusy`,
  `noNetworkFilter`.
- `busy` becomes per slot: a machine with two free slots takes two jobs.
- `needsTeamKey` stays: the guest has no Xcode account either.

### Migration

1. Workers update to the version with VM support. Nothing changes until a machine's `executor` is `vm`.
2. The operator runs `isolate` again (it is idempotent) to install the pf anchor and, for an external SSD,
   enable ownership. Then they build an image from the Machines page or with `hangar-worker vm
   build-image`.
3. They switch the machine to `vm`. Its host-side DerivedData and workspaces stay until the operator deletes
   them (the doctor shows their size).
4. When both Macs have run VM builds for a while, the host executor becomes opt-in, and later goes.

The `hangar` user, the LaunchDaemon and the CI keychain stay as the VM host's account. The ownership
problem with `/opt/homebrew` disappears in VM mode: the guest's Homebrew belongs to `builder`.

## What this does not stop

- A build exfiltrating what it is given: the development identity, the ASC key, the git token, the source.
  It can reach the internet, because builds need it.
- A build using the guest as a network client on the internet for the length of a job (e.g. mining or
  scanning). The timeout bounds it.
- A VZ or guest-kernel escape. The VM runs as `hangar`, which bounds the damage to that account.
- Supply-chain trust in the vanilla image (first slice), Homebrew and package hosts.

## Key Decisions

1. **A fresh macOS VM per job, not a user or container on the host.** It is the only way to give a build a
   writable `/opt/homebrew` and its own system without touching the owner's environment. Spike: ready in
   2.3 to 5.9 s from a saved state.
2. **Our own VZ code in the worker, not Tart.** Typed errors, slot-aware save/restore, one self-updating
   binary, no external runtime. Tart's license (FSL-1.1-ALv2, internal use permitted) is not the reason.
   Image layout stays Tart-compatible.
3. **Save/restore with one state per slot.** Each slot has its own machine identifier, MAC, NVRAM and state,
   because restore requires an identical configuration and two VMs from one state cannot run together.
   Cold boot is the automatic fallback.
4. **Images are built per Mac, from a vanilla macOS plus the host's own Xcode.** First slice: import
   Cirrus's vanilla image pinned by digest. Next: IPSW install plus a one-time click-through by the
   operator. Never download Xcode with an Apple ID in a guest, never publish images.
5. **The guest runs the existing pipeline with a one-job token. The host supervises and relays.** That
   reuses the steps unchanged, keeps the machine token on the host, and the relay limits the guest to its
   own job.
6. **SSH first, vsock agent second.** SSH is proven. Vsock across save/restore is not yet.
7. **One development identity per worker, kept on the host, injected per job as a `.p12`** into a temporary
   keychain. No certificate per VM.
8. **Caches are read-only, host-written, and not in the first slice.** DerivedData stays cold.
9. **A pf anchor is a precondition for VM slots.** The spike showed NAT guests reach the owner's tools.
10. **One slot on the mini (8 GB), two on the MacBook.** The mini needs an external SSD for images.

## Open Questions

1. **VZ from the `system` domain as `hangar`.** The spike ran as the interactive user, in the GUI session
   and in the Background session. A LaunchDaemon with `UserName hangar` was not tried (it needs root). It is
   very likely to work (Tart runs this way in CI), but it is the first manual check.
2. **Are saved states tied to the macOS user** as well as the host? Moot if the daemon makes its own states,
   which it does, but it decides whether an image build started as the operator can save the slot states.
3. **Does the two-VM limit count VMs across macOS users?** If yes, an owner's own VM blocks a Hangar slot.
   The design already treats that as "slot busy".
4. **Why did `ditto` from a virtio-fs share fail with symlink loops** when a small share's symlinks resolve?
   The tar stream works, so this only matters if we want a share-based copy.
5. **A vsock listener across save and restore** (see *Control channel*).
6. **The MacBook's free disk** decides whether it needs an external SSD too.
7. **pf from a LaunchDaemon on macOS 26 and 27:** the anchor and `pfctl -e` reference counting were not tried
   (root).
8. **Does the anchor survive a reload of `/etc/pf.conf`?** macOS reloads it on some network changes (Internet
   Sharing, for one). A nested anchor's rules should survive a reload of its parent, but the marker would not
   notice if they did not. Checked in *Manual verification*.
9. **Guest to guest.** Two slots share the NAT bridge. Whether pf sees bridged traffic between two guests (and
   so whether the RFC 1918 rule blocks it) was not tried; the MacBook's two slots are the place to check.
10. **`security export` of the CI keychain's identity as `hangar`, headless.** It goes through `security -i` with
   the keychain unlocked and the partition list set, which should need no prompt. Unproven: if it prompts,
   `vm identity import` of a `.p12` exported in Keychain Access is the way.

## First slice as built

Built on branch `vm-slice-1`: one host role, one slot by default (two allowed), one Xcode per image, SSH control,
no caching. The code is in `Sources/HangarWorker/VM`, the commands in `hangar-worker vm …`. Where this design left
something open, the slice decided as follows.

### Decisions

1. **The switch is the worker's `vm` section, not a server setting.** `hangar-worker vm enable` writes `vm` into
   the worker configuration (storage, slots, CPUs, memory, timeout, floor, reserve). A worker with it reports a
   `vm` section and runs every job in a VM; one without it builds on the host exactly as before. There is no
   per-machine `executor` setting on the server: the report is the setting. A machine whose `vm` section has no
   ready slot takes **no** jobs (`vmNotReady`, with the reason), instead of falling back to the host: the
   fallback would quietly run untrusted builds next to the owner's tools, which is what VM builds exist to stop.
2. **VZ runs in the worker process, on one serial queue per VM, not in a `vm-host` child.** `kill -9` of the
   process that owns a VM ends the VM (spike), so a crashed worker leaves no VM running either way, and the
   daemon is restarted by launchd. A child process would add a protocol between the two for nothing in this
   slice. Revisit if a Virtualization.framework call is ever seen to wedge the worker.
3. **The guest gets its job from the host, not from the server.** The host claims the job with its machine
   token as today and passes the assignment, the job token and the identity to the guest as the first line of
   the SSH session's standard input. A job token cannot call `jobs/next` or mint tokens. The guest then reports
   start, info, steps, log, artifacts and finish itself; the host reports only what the guest could not (a VM
   that did not boot, a guest that vanished, a cancel or timeout it did not answer), and a 409 there means the
   guest already did.
4. **Job tokens are issued on request after the claim** (`POST jobs/{id}/token`, machine token only), not put in
   every assignment: host workers never see one. `hgj_` and 256 random bits, stored as a SHA-256, refused
   (401) once the job is terminal or no longer the machine's, deleted by `finish` and by
   `DELETE jobs/{id}/token`, which the host calls when the VM is gone. Scope is enforced in the worker route
   middleware: only `POST jobs/<own id>/{start,info,steps,log,finish,artifacts/<name>}`; anything else is 403
   `job_token_scope`.
5. **The relay is a loopback listener per job, reached by `ssh -R 127.0.0.1:8787:127.0.0.1:<port>`.** One
   request per connection: the head must be a `POST` to one of the job's routes with the job's token and a
   `Content-Length` (no chunked bodies, so the request ends where the relay says); it is rewritten with the
   server's `Host` and path prefix and `Connection: close`, exactly that many body bytes follow, and the answer
   streams back. Anything else gets a 403 and never reaches the server.
6. **The worker's evidence for the network filter is a root-owned marker.** The worker runs as `hangar` and
   cannot read pf's state. The `app.hangar.pf` LaunchDaemon loads the anchor at boot, runs `pfctl -E`, and
   writes `/Library/Application Support/Hangar/vm-network-filter.json` with the rules' SHA-256 and
   `kern.boottime`. No marker, a marker not root's, other rules, or another boot: no slots. The rules match the
   guest subnet (read from `com.apple.vmnet`), not an interface name, except for dropping IPv6 on
   `bridge100`–`bridge102`. Host-to-guest connections are passed with state, which is what lets SSH and its
   port forward work while every packet a guest starts towards the host is dropped. DHCP passes.
7. **Installing the filter is its own command**, `hangar-worker vm network install [--dry-run]`, not part of
   `isolate`: it is the one root step of VM builds, and it is easier to read and to undo on its own
   (`vm network uninstall`).
8. **`admin`'s new password is random and kept nowhere.** `admin` is reached with the host's key only, keeps
   its passwordless sudo for the hand-over, and password logins are off. The published password is needed once
   more, as the old password for `dscl . -passwd`: `admin` holds a Secure Token. Keeping the new one would only
   matter for a GUI login, and the host's key can reset it.
9. **The guest's host keys are pinned per image.** The build records them in the image's `known_hosts` under one
   alias (`hangar-guest`); every clone has the same keys, and SSH to a clone checks them strictly.
10. **Automatic login is written by hand.** `sysadminctl -autologin set` records the user but leaves the image's
    `/etc/kcpassword` (admin's) in place, so the login window fails and the saved state has no session. The
    build writes `/etc/kcpassword` itself (the password, a zero, padding to 12 bytes, XOR with Apple's key).
11. **The identity is a `.p12` and its password in two 0600 files next to the worker's configuration**, from
    `vm identity from-keychain` (`security export` of the CI keychain, through `security -i`) or `vm identity
    import`. *(Superseded 2026-11-06 by* Server-managed identity *under* Signing*: the server holds the one
    identity; these files are now an optional per-worker override.)* Creating one through the App Store Connect API is left for later: both Macs' CI keychains already
    hold the identity their host archives created. An archive in a VM fails before the VM boots when there is
    none, so a fresh VM never creates certificates. The guest imports it into a keychain made for the job with a
    random password, and the `.p12` file is deleted right after the import.
12. **There was no job timeout; VM jobs get one.** `vm.jobTimeoutMinutes`, default 120: the host sends the guest
    a cancel with the reason, waits a minute for it to report, then stops the VM and reports it itself.
13. **Slot states are saved when they are missing or stale, never in the middle of a job.** At start the worker
    saves every missing or stale state in the background, holding each slot meanwhile; a job waits up to 15
    minutes for a held slot. A job that had to cold-boot saves its slot again after it ends, before it frees the
    slot. Stale means: the image was rebuilt, the CPUs or memory changed, or the host's macOS build changed.
14. **"Settled" is six quiet samples in a row:** `builder` owns the console and the one-minute load is under 1,
    sampled every 5 s; after 5 minutes it saves anyway.
15. **Each job's VM gets this host's `hangar-worker`**, copied to `~/.hangar/bin` of the build user before the run,
    so an image never needs rebuilding for a worker update. The guest's work directory is `/Users/builder/hangar`.
    `HOMEBREW_NO_AUTO_UPDATE`, `HOMEBREW_NO_ANALYTICS` and `HOMEBREW_NO_INSTALL_CLEANUP` are added to the job's
    variables unless the app sets them.
16. **The import keeps at most four compressed chunks on disk at a time** (one per parallel download, each at most
    a few hundred MB), not none: a chunk is downloaded, checked against its digest, then decompressed into the
    sparse disk, all-zero 64 KiB blocks left as holes. The import and the image build watch free space and stop,
    deleting what they made, at the floor.
17. **The vanilla image is pinned** to `ghcr.io/cirruslabs/macos-tahoe-vanilla:26.6.2@sha256:eeec54bf…6e34640`,
    the default of `vm image import`.
18. **One image per Xcode, named `xcode-<version>`; the Metal toolchain and the iOS platform are in by default**
    (`--no-metal-toolchain`, `--no-platforms`, `--platform` to change that). `tools:` is not checked on a VM
    machine; `xcode:` and simulator platforms are matched against the images.

19. **An archive is split between the guest and its host** *(2026-11-06, security review C1)*. No App Store
    Connect key of the server's ever enters a guest. The guest runs `checkout` through `stamp`, then
    `post-xcodebuild`, and reports them itself. Then it prints `hangar-handoff {json}`, with the guest paths of the
    archive, the result bundle, the TestFlight notes and the full log, instead of a result. The host copies those
    out with `tar` over SSH while the VM still runs, then stops the VM. It then runs `export`, the post-actions,
    `upload-artifacts` and `cleanup` in the job's directory with the server's key, and reports the result with its
    machine token. The steps' names and order on the build page do not change; only the order they run in does.
    The details:
    - **`post-xcodebuild` runs before the export**, as before in the guest, so in a VM it sees
      `CI_XCODEBUILD_EXIT_CODE` but not `CI_APP_STORE_SIGNED_APP_PATH` or `CI_DEVELOPER_ID_SIGNED_APP_PATH`. An
      Xcode Cloud `ci_post_xcodebuild.sh` that uploads the exported `.ipa` (to a crash reporter, a store, a chat)
      gets an empty path in a VM. Uploading dSYMs from `CI_ARCHIVE_PATH` still works, since the archive is there. A
      script that needs the exported product must move to a post-action, or run on a host Mac.
    - **The copy is checked before anything of the host's reads it.** The guest's paths must be absolute, without
      `..`, and end in `.xcarchive`, `.xcresult`, `/TestFlight` and `.txt`. `tar` unpacks into a staging directory
      (bsdtar refuses absolute and `..` member names by default). The host then refuses a copy that holds a
      symbolic link whose target is absolute or leads outside it, or anything but regular files, directories and
      links. A link to `/Users/hangar/.hangar/…` would otherwise be followed by the export and land in the `.ipa`.
      Not limited: the copy's size. A hostile guest can send a large archive until the host's disk floor is reached
      (the job then fails).
    - **The export runs on the host with an environment of its own**: the identity variables, `PATH`,
      `DEVELOPER_DIR` and a `TMPDIR` of the job's, and none of the job's variables. The host's CI keychain is unlocked
      first when it has one. It needs the workflow's Xcode installed on the host (an image's Xcode is copied from
      the host when the image is built, so it normally is); without it the export fails with "Xcode … not
      installed".
    - **Residual risk:** the host's `xcodebuild -exportArchive` and `altool`/the upload parse an archive that
      build code wrote: property lists, Mach-O files, code signatures and asset catalogs. This is Apple's code, run
      as `hangar` with the server's key on disk for the length of the step. A memory-safety bug in those parsers,
      or an export option the archive can steer, is the remaining path from a malicious build to the key. It is
      much narrower than a build phase reading the key file, which was the path before. No Run Script phase,
      package plugin or `ci_*` script runs on the host.
20. **The guest signs with development profiles from the server** *(2026-11-06, owner's call)*. Before the VM
    boots, the host asks `POST /worker/jobs/{id}/provisioning` with its machine token. For the app's own bundle
    IDs (the App Store Connect app's bundle ID and every registered ID under it, `<id>.*`, of the archive's
    platform), the server returns an active development profile of the platform's type that holds Hangar's
    certificate. It creates one only when there is none: development types only (the client has no distribution
    type), Hangar's certificate, the team's enabled devices, a name `Hangar Development <id> <date>`, logged on
    the server and in the archive's log. The guest installs the profiles in both of Xcode's profile directories
    and archives with an `-xcconfig`: `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = Apple Development`, and
    `PROVISIONING_PROFILE_SPECIFIER = $(HANGAR_PROFILE_$(PRODUCT_BUNDLE_IDENTIFIER:identifier))` with one
    `HANGAR_PROFILE_<id>` per profile. Only targets whose bundle ID has a profile get one, so frameworks and
    package targets, which refuse a profile, get none. No `-allowProvisioningUpdates` and no account. Checked on the
    mini with Xcode 27.2: the mapping reaches only the app target, and its framework and SwiftPM dependencies
    build without complaint. Not checked: a real signed archive (`xcodebuild` must accept installed profiles
    without any Apple account), which is item 21 of *Manual verification*. Automatic signing would ignore profiles
    created through the API, which is why manual signing is used. Found while building it: an iOS device archive
    will not sign ad hoc (`CODE_SIGN_IDENTITY=-` still "requires a provisioning profile"), and an unsigned one
    (`CODE_SIGNING_ALLOWED=NO`) carries no entitlements, which the export takes from the archive's signature. So
    the guest has to sign with a real profile.
21. **The development key is the fallback, and only that** *(2026-11-06, owner's call)*. Settings › Development
    Key holds an optional second team key. The server refuses an individual key, its own key, and a key that can
    list the team's users (an Admin key). It comes with the provisioning answer only when a profile is missing; the
    guest then archives as before, automatically with `-allowProvisioningUpdates` and that key. The guest always
    has Hangar's identity installed before the archive, so Xcode has no reason to create a certificate. With
    neither a profile nor the key, an iOS, tvOS, visionOS or watchOS archive fails before its VM boots, naming
    each missing bundle ID and why. A macOS one goes on, since an app that needs no profile signs with the
    certificate alone. A worker's own identity (`vm identity import`) gets no profiles (they hold Hangar's
    certificate), only the development key. A limit: the server sees only bundle IDs registered with Apple. A new
    extension whose ID is not registered yet gets no profile and is not reported missing, so the archive fails with
    Xcode's "requires a provisioning profile". Registering the ID (Certificates, Identifiers & Profiles) fixes it:
    the next archive gets a profile made for it. Capabilities are not synchronised either: a profile is made with
    the capabilities the App ID has at Apple.
    - **What a leak of the development key exposes:** whoever controls a build's code during a fallback archive
      can copy it. With the Developer role and access to Certificates, Identifiers & Profiles it can, until it is
      revoked: create and revoke development certificates, register devices, create bundle IDs and change their
      capabilities, and create development profiles. Apple's role table gives distribution certificates and
      distribution profiles to Account Holder, Admin and App Manager, not Developer. Hangar checks only that the
      key is not an Admin key (it cannot list users); it cannot tell App Manager from Developer without trying a
      write. Use the Developer role, and keep the key unset unless a profile cannot be provided otherwise. *(Still
      to confirm against Apple's page, see* Manual verification *item 22.)*
22. **The guest's identity cannot be exported** *(2026-11-06, security review H1)*. `security import -x` is
    ignored for a `.p12`: on macOS 27.2, with a throwaway keychain, the key exported again byte for byte. So the
    guest splits the `.p12` with `/usr/bin/openssl` (passwords on standard input), imports the private key alone as
    a PKCS#1 PEM with `-x` and only `/usr/bin/codesign` in its access list, then the certificates as a PEM
    sequence. On the same throwaway keychain, `security export` of that key then fails at once with "The contents
    of this item cannot be retrieved", without a prompt. The partition list is the same as before
    (`apple-tool:,apple:,codesign:`), so Xcode's `codesign` signs without a prompt. Not checked here: codesign
    signing with the non-extractable key, since a throwaway self-signed certificate is not a valid signing
    identity without changing this Mac's trust settings. Item 23 of *Manual verification* checks it. The keychain's
    password is no longer written to `~/.hangar-keychain/keychain-password`: the guest worker keeps it in memory
    to unlock the keychain and set the partition list after each xcodebuild step. The keychain has no lock timeout
    and a VM does not sleep. `builder` is not an administrator and cannot attach a debugger to that process.
23. **The App Store Connect key is a server setting** *(2026-11-06, security review C1)*. It is never a variable.
    The server's certificate and profile calls use it. An assignment carries it in `appStoreConnectKey`: for every
    job on a host Mac, and for an archive on a VM Mac, whose host removes it from the guest's copy. On a host Mac
    the worker writes the `.p8` into the job's `asc-key/` directory only while the archive, test or export
    `xcodebuild` (not package resolution) and each post-action run, and removes it right after. No hook's
    environment has it. **What still sees it on a host Mac:** Run Script phases, package plugins and macros run
    as the worker's user during those `xcodebuild` steps and can read the file, and anything running as that user
    can read the worker's memory. VM builds are the boundary; a host Mac is not one.

**Revised 2026-11-05: an image installs only what is necessary.** *(owner's call)* A job image carries macOS and
Xcode (first launch done), and nothing else: no Homebrew, no Metal toolchain and no simulator runtime by default
(archives use the SDKs inside Xcode; only test jobs need a runtime, and `--platform iOS` adds one). A job assumes only macOS and Xcode and installs what it needs itself, so no build depends
on what the image happened to carry. `/opt/homebrew` exists, empty and owned by
`builder`, so a job's script can unpack Homebrew there without sudo and get bottles. `vm image build --homebrew`
and `--metal-toolchain` add them ahead of time for a Mac whose owner wants them. This supersedes the Homebrew parts of goal 2 and of the base image pipeline above.

### Found while building it

- **macOS 27's Virtualization.framework can provision a guest.** `VZMacGuestProvisioningOptions` (full name,
  user name, password, automatic login, Remote Login) set through `VZMacOSVirtualMachineStartOptions` on the first
  boot after an IPSW install, for macOS 27 guests. That is Setup Assistant without a person or a third-party
  image. The MacBook (macOS 27.2) can use it once a macOS 27 restore image is supported; it is the natural
  replacement for the Cirrus import, ahead of "IPSW plus a person".
- `sysadminctl -autologin set` does not write `kcpassword` over an existing one (decision 10).
- `dscl . -passwd` needs the old password for a Secure Token user (decision 8).
- `brew update` on a tarball install turns it into a git checkout and prints a warning about the deprecated
  `master` branch; Homebrew works.

### Measured on the mini

On 2026-11-05, as the interactive user, with the storage in a scratch directory on the internal disk and a
watchdog keeping 40 GiB free. Everything was deleted afterwards.

| Step | Measured |
|---|---|
| `vm image import` (the pinned vanilla, 24.0 GB compressed, 94 disk chunks) | 4 min 57 s, 80 MB/s, 26 GiB on disk |
| `vm image build --no-platforms --no-metal-toolchain` (Xcode 27.2, Homebrew) | 5 min 18 s; about 6 GiB over the vanilla |
| … boot of the vanilla clone to its DHCP lease | 7.1 s |
| … Homebrew (tarball, `brew update`) | 54 s |
| … Xcode 27.2 by `tar` over SSH (8.9 GB, kept compressed) | 172.5 s |
| … `xcodebuild -runFirstLaunch` | 49.7 s |
| `vm slots prepare`: save (8 GB guest, paused) | 5.2 s, a 1.8 GB state |
| `vm smoke`: clone + restore to `ssh builder@guest true` (first build: no GUI session in the state) | 5.7 s, 4.9 s, 2.7 s |
| A second build, with the automatic-login fix, while the test suite ran | 7 min 38 s (Xcode copy 249.5 s) |
| … the fresh guest's load (boot storm), then `vm slots prepare`'s settle | load 203 after boot, still above 1 after 5 minutes: saved anyway, 5.0 s |
| `vm smoke` from that state (a logged-in GUI session, a busy guest) | 8.0 s, 9.4 s |
| `vm smoke --slot 1` (no state): cold boot to `ssh builder@guest true` | 10.1 s, `builder` already logged in |
| `vm run-assignment`: a test job of `nicklockwood/LRUCache`, claim to result | 30.3 s (restore 9.4 s, clone 8 s, `xcodebuild test` 7 s) |

The job ran against a stand-in for the server on loopback (no root, so no pf filter: `--ignore-network-filter`).
Every call the guest made (`start`, `info`, 18 `steps`, 6 `log`, two artifact uploads, `finish`) reached it
through the relay and `ssh -R`, with the job token and the server's `Host`; the machine token appeared only on
the host's `POST` and `DELETE` of `jobs/{id}/token`. The guest cloned the repository from GitHub, ran Xcode
27.2's `xcodebuild test`, and failed on the project's own error (a macOS 10.15 deployment target, which Xcode
27.2 no longer supports); the job log's first line was "VM: restored slot 0's saved state in 9.4 s on rurzomac
mini".

A state saved from a busy guest restores more slowly (8 to 9 s against 2.7 to 5.7 s) and resumes busy. The
5-minute settle cap is too short for the first boot of a fresh image on the mini's 4 vCPUs; on the MacBook,
watch for `the guest did not settle within 5 minutes` (step 6 of *Manual verification*) and raise it if it
shows.

In each restored guest: `builder` is not in `admin`, `/opt/homebrew` is `builder`'s, Homebrew 7.0.12 and
Xcode 27.2 answer. After each run no
`com.apple.Virtualization.VirtualMachine` process was left and `jobs/` was empty; a `SIGTERM` to a command
holding a VM ended the VM. A failed image build deleted its partial directory.

Not proven here: anything that needs root (the pf anchor, the `app.hangar.pf` daemon, `isolate`), the `hangar`
LaunchDaemon running VMs, a simulator runtime and the Metal toolchain in an image (they do not fit above the
floor), an archive with signing, TestFlight, two slots at once, and the cold-boot fallback after a real host
update. *Manual verification* covers them on the MacBook.

## PR Plan

First shippable slice, MacBook only (disk), one slot, one Xcode version, SSH control, no caching. Roughly
3,000 to 4,000 lines with tests, about 8 PRs:

1. **`HangarVM` module.** Image and slot bundle format (Tart-compatible), `clonefile` helpers, VM
   configuration from a bundle, boot, save, restore with typed errors, the `vm-host` child process with the
   stdin-EOF rule. Ad hoc signing with the entitlement in the release script, with the SHA-256 taken after
   signing.
2. **`hangar-worker vm import`:** an OCI pull of a Tart-format image pinned by digest (LZ4 chunks into a
   sparse disk).
3. **`hangar-worker vm build-image --xcode`:** the SSH provisioning above (admin password rotation,
   `builder`, Homebrew, Xcode by tar stream, first launch, platforms), then per-slot state saving.
4. **Job-scoped tokens on the server.** Issue them on claim, limit them to their job's endpoints, revoke at
   the end.
5. **The VM executor in the worker:** clone, restore (cold-boot fallback), hand-over over SSH, relay, `run-job`
   mode in the guest, the temporary keychain, destroy, the start-up sweep.
6. **pf anchor in `isolate`,** and the worker's anchor check.
7. **Reporting and scheduling:** `MachineReport.vm`, per-slot `busy`, image matching, the new
   ineligibilities, the per-machine `executor` setting, the Machines page.
8. **Docs:** `docs/worker-setup.md` (external SSD, building an image), and this file's manual verification.

Then: vsock agent, IPSW plus click-through images, the package mirror, a second slot, the mini on an
external SSD.

## Manual verification

On the MacBook (rurzobuk-max), after a backup, with `vm-slice-1` merged and the server reinstalled on the mini
(`scripts/server/install-server.sh`, which now signs the `hangar-worker` it hands out). Every command runs in
Terminal as the owner (an administrator). `hw` runs the `hangar` user's worker as `hangar`:

```sh
hw() { sudo -u hangar -H /Users/hangar/.local/bin/hangar-worker "$@"; }
```

**What needs sudo:** `hw` itself (`sudo -u hangar`, to act as the worker's user), steps 4 and 12 (`vm network
install`: it writes `/etc/pf.anchors/app.hangar.vm`, `/Library/Application Support/Hangar/vm-network-filter.sh`
and `/Library/LaunchDaemons/app.hangar.pf.plist`, and loads them), the `pfctl` and `launchctl` checks, and the
`kill`, `ls` and `rm` of `hangar`'s files below. Nothing else changes system files.

1. **The worker is the signed one.** Wait for the MacBook's worker to update itself (Machines page: its version
   is 0.11.0), or run the install command again. Then
   `sudo codesign -d --entitlements - /Users/hangar/.local/bin/hangar-worker` lists
   `com.apple.security.virtualization`. `df -g /System/Volumes/Data` has at least 40 + 60 GiB free (else use an
   external SSD: *VM builds* in docs/worker-setup.md).
2. **Turn it on, one slot first:** `hw vm enable --cpus 6 --memory-gb 14`, then
   `sudo launchctl kill SIGTERM system/app.hangar.worker`. The Machines page shows "VM builds not ready: the VM
   network filter is not installed …", and a deploy waits with that reason. No job runs on the host.
3. **The filter, read first:** `sudo /Users/hangar/.local/bin/hangar-worker vm network install --dry-run`. Read
   the rules: `guests = "192.168.64.0/24"` (or the subnet in `com.apple.vmnet`), the pass rules, then the blocks.
4. **The filter, installed:** the same without `--dry-run`. Then:
   - `sudo pfctl -a com.apple/250.HangarVM -sr` prints the rules; `sudo pfctl -s info | head -1` says
     `Status: Enabled`.
   - `ls -l "/Library/Application Support/Hangar/vm-network-filter.json"` is `root`'s; `hw vm network check`
     says it is loaded.
   - `sudo pfctl -f /etc/pf.conf` (what macOS does on some network changes), then
     `sudo pfctl -a com.apple/250.HangarVM -sr` again: the rules are still there (open question 8). If not,
     note it: the loader must then also run on network changes.
5. **Import:** `time hw vm image import`. About 5 minutes and 26 GiB (mini: 4 min 57 s). Run
   `hw vm image import --name scratch` and press Ctrl-C after a minute: it says `interrupted; removed …`, and
   `sudo ls -a /Users/hangar/.hangar/vm/images` shows no `.partial-scratch`.
6. **Build the image:** `time hw vm image build` (iOS platform and Metal toolchain included; 15 to 30
   minutes). It ends with `slot 0: saved its state in …`. `hw vm image list` shows `xcode-27.2: Xcode 27.2,
   macOS 26.6.2 (25G83)` and `slot 0: saved …`; `cat` of `images/xcode-27.2/image.json` (with sudo) lists
   `iOS 27.2` (or the runtime the download got) in `simulatorRuntimes`. During the build, `df -g` never shows
   less than 40 GiB free.
7. **The image's users:** `hw vm smoke --command 'id; dseditgroup -o checkmember -m builder admin; sudo -n true
   && echo SUDO || echo no-sudo; dscl . -authonly admin admin && echo VANILLA-PASSWORD || echo admin-password-replaced;
   cat /etc/ssh/sshd_config.d/100-hangar.conf; stat -f %Su /dev/console; ls -ld /opt/homebrew'`. Expect: `builder`
   not a member of `admin`, `no-sudo`, `admin-password-replaced`, `PasswordAuthentication no`, the console
   owned by `builder` (automatic login worked), `/opt/homebrew` owned by `builder`. The first line says
   `restored slot 0's saved state in` under 10 s.
8. **Homebrew and the network from a guest:** `hw vm smoke --command 'export PATH=/opt/homebrew/bin:$PATH;
   brew install -q xcodegen && xcodegen --version; curl -m 10 -so /dev/null -w "github %{http_code}\n"
   https://github.com; for t in 192.168.64.1:22 192.168.64.1:3773 <MacBook LAN IP>:22 <router IP>:80
   100.71.242.42:8787; do nc -z -G 3 ${t%:*} ${t#*:} && echo "$t OPEN" || echo "$t blocked"; done'`.
   Expect xcodegen's version, `github 200`, and every target `blocked`.
9. **The identity:** in Settings › Signing, import the `hangar` CI keychain's Apple Development identity as a
   `.p12`, or create Hangar's certificate there (once). `hw vm identity status` should say none: the worker
   uses the server's. (Before 2026-11-06: `hw vm identity from-keychain`, then `hw vm identity status` says
   stored, open question 10.) Count the team's development certificates in App Store Connect (Certificates,
   Identifiers & Profiles) before and after: at most one more, and none after the archives in step 11.
10. **Restart the worker:** `sudo launchctl kill SIGTERM system/app.hangar.worker`. Its log
    (`sudo tail /Users/hangar/Library/Logs/Hangar/worker.log`) says `VM builds on … ready: yes`; the Machines
    page shows "VM builds · 1 slot (1 free) · Xcode 27.2 · network filter on". This is the LaunchDaemon as
    `hangar` running VMs (open question 1).
11. **Legilo to TestFlight, twice.** Deploy Legilo's TestFlight workflow from Hangar. Its log's first line is
    `VM: restored slot 0's saved state in … on rurzobuk-max`; `ci_post_clone.sh` runs unchanged (its `brew
    install` works); archive, export and the TestFlight upload succeed; the build appears in TestFlight. Deploy
    again: same. The team's development certificate count is unchanged. While a job runs:
    `sudo ls /Users/hangar/.hangar/vm/jobs` shows one clone; after it, none.
12. **Job token scope** (with a throwaway branch of Legilo whose `ci_scripts/ci_post_clone.sh` adds
    `for p in heartbeat jobs/next "jobs/$CI_BUILD_ID/finish"; do curl -s -o /dev/null -w "$p %{http_code}\n"
    -X POST http://127.0.0.1:8787/api/v1/worker/$p -d '{}'; done; curl -m 5 -s http://100.71.242.42:8787/ || echo
    "server unreachable"`): the log shows `403` for each (the relay refuses them) and `server unreachable`.
13. **Timings** in the job logs and the worker log: claim to guest shell under 10 s. Then the cold-boot
    fallback: `sudo -u hangar rm /Users/hangar/.hangar/vm/images/xcode-27.2/slots/0/state.vzstate` and deploy:
    the log says `cold-booted in …` (under 30 s), the job succeeds, and afterwards `hw vm image list` shows
    slot 0 `saved` again.
14. **`kill -9` during a job:** `sudo pkill -9 -f '/Users/hangar/.local/bin/hangar-worker run'`. Within seconds
    `pgrep -fl com.apple.Virtualization.VirtualMachine` prints nothing; launchd restarts the worker, whose log
    says `swept leftover VM clone …`; the job fails as lost on the build page; `sudo ls
    /Users/hangar/.hangar/vm/jobs` is empty.
15. **Timeout:** `hw vm enable --timeout-minutes 2`, restart the worker, and deploy a branch whose
    `ci_post_clone.sh` runs `sleep 600`. After 2 minutes the job is cancelled with "the job ran longer than 2
    min, the VM job timeout on rurzobuk-max", the VM is gone and `jobs/` is empty. Set it back with
    `hw vm enable --timeout-minutes 120` and restart.
16. **Cancel:** deploy, then cancel from the build page during the archive: the job ends cancelled within a
    minute, VM gone.
17. **Reboot during a job:** as 14, after the reboot. Then the first job restores from the saved state.
18. **A host macOS update:** the first job after it cold-boots (`… macOS on this Mac was updated`) and
    succeeds; the slot is saved again.
19. **Two slots:** `hw vm enable --slots 2 --memory-gb 14`, restart, wait for the worker log's `slot 1: saved
    its state`. Deploy two apps (or Legilo twice): both run at once in two VMs and succeed. A third waits ("busy").
    From inside one job, `nc -z -G 3 <the other guest's 192.168.64.x> 22` is `blocked` (open question 9). Then
    start a VM by hand (the spike's `tart`): a job that starts meanwhile logs "already runs two macOS VMs …
    trying again" in the worker log and runs once the hand-started VM stops; no job fails.
21. **No key in the guest, both signing paths** (decisions 19 to 21). Before: in Settings, the App Store
    Connect card shows the team key and no app variable or global variable named `HANGAR_ASC_*` is left (the
    migration moved them). Leave Settings › Development Key unset.
    - *Profiles path.* Deploy Legilo's TestFlight workflow (iOS and macOS archives). In each archive's log:
      `signing for development with Hangar's profiles for …; no App Store Connect key is in this VM`, and a
      `created development profile …` line for each bundle ID that had none (also in the server's log). Then
      `post-xcodebuild`, then `export` with `exporting on rurzobuk-max with Xcode 27.2 …, outside the VM`, the
      TestFlight upload, and both builds in TestFlight. In App Store Connect › Profiles, only `Hangar Development …`
      development profiles are new; no distribution profile and no certificate is new.
    - *Prove the key is absent:* on a throwaway branch whose `ci_post_clone.sh` and `ci_post_xcodebuild.sh` run
      `env | grep -c HANGAR_ASC; ls ~/hangar ~/.hangar* /Volumes/workspace/hangar 2>/dev/null | grep -ci p8;
      grep -rl "PRIVATE KEY" ~ /Volumes/workspace 2>/dev/null | head`, the log shows `0`, `0` and nothing.
    - *If Xcode refuses offline manual signing* (the archive fails with "No Account for Team" or "No profiles for
      … were found" although the profile is installed), that is the risk decision 20 names. Add a development key
      (next bullet) and record what Xcode said here.
    - *Fallback path.* Make a team key with the Developer role and access to Certificates, Identifiers &
      Profiles, and add it in Settings › Development Key. Try the Admin key there first: it is refused
      (`development_key_too_powerful`). Then make the profiles unavailable: give the MacBook its own identity
      (`hw vm identity import`, any Apple Development `.p12` of the team), for which the server provides no
      profiles. Deploy: the archive's log says `no development profile for Legilo: this Mac signs VM archives with
      its own identity …` and `signing for development with Hangar's development key …`; the archive succeeds and
      the export still runs on the host. Remove the development key and deploy again: the iOS archive fails before
      its VM boots, naming the reason and Settings › App Store Connect. Then `hw vm identity remove`.
22. **The development key's role:** with the Developer-role key from 21, check App Store Connect › Users and
    Access › Integrations shows its role as Developer, and read Apple's role table
    (developer.apple.com/help/account/access/roles) for "Create and revoke distribution certificates" and
    "Create and delete distribution provisioning profiles": the Developer column must be empty. Do not try to
    create a distribution certificate with it.
23. **The guest identity cannot be exported** (decision 22, security review item 6): on a throwaway branch whose
    `ci_post_clone.sh` runs `security export -k ~/.hangar-keychain/job.keychain-db -t identities -f pkcs12 -P x
    -o /tmp/x.p12; echo "export $?"; ls ~/.hangar-keychain`, the log shows a failed export ("cannot be
    retrieved" or a non-zero status) and only `job.keychain-db`; the archive still signs (codesign works with the
    non-extractable key) and reaches TestFlight.
24. **A hostile archive does not reach the host:** on a throwaway branch whose `ci_post_xcodebuild.sh` runs
    `ln -s /Users/hangar/.hangar "$CI_ARCHIVE_PATH/Products/escape"`, the job fails with `… is a link to
    /Users/hangar/.hangar, outside it` and no export runs.

20. **Turning it off:** `hw vm disable`, restart: the next job builds on the host as before. `hw vm enable`
    and restart to go back. `sudo /Users/hangar/.local/bin/hangar-worker vm network uninstall` removes the
    filter (the Mac then reports no VM slots).
