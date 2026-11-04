# Hangar — a self-hosted build fleet for Apple apps

Date: 2026-11-04
Status: reviewed (4 builder checks); awaiting author approval

## Intent

Xcode Cloud is temporarily unavailable to the author. The author has two Macs
on a Tailscale tailnet: `rurzomac-mini`, a Mac mini (M4, 16 GB) that runs the
server, and `rurzobuk-max`, a MacBook Pro that runs as a worker. The Mac mini
may also run as a worker. Hangar turns them into a small build fleet that does
what Xcode Cloud does for the author's apps. It archives, signs and stamps the
build number. It ships the result to TestFlight, or for apps outside the App
Store it notarizes the build and publishes it with a Sparkle appcast.

This is not only a stand-in. Xcode Cloud and Hangar will run **side by side**
once Xcode Cloud returns, and the author expects to use Hangar more often. It is
designed from day one as a **public, open-source project** for any Apple-platform
developer, shaped like Xcode Cloud so that a repo set up for Xcode Cloud works
with Hangar without changes.

The author ships nine apps (Legilo, Horzono, Velum, Winyl, Hourly Beep, Vetero,
NepTunes, BatFi, Herald):

- several are on two or more platforms (iOS, macOS, visionOS),
- some ship only on the Mac App Store,
- some ship outside the App Store with notarization, and today those are
  deployed by hand. Herald, for example, uses `scripts/publish-release.sh`,
  Sparkle, R2 and `rclone`.

Every one of these repos already has `ci_scripts/`. Those scripts rely on Xcode
Cloud's `CI_*` environment: `CI_PRIMARY_REPOSITORY_PATH`, `CI_BUILD_NUMBER`,
`CI_ARCHIVE_PATH`, `CI_PRODUCT_PLATFORM`, `CI_XCODEBUILD_ACTION` and
`CI_WORKFLOW`. Some of them also rely on secret env vars such as `SENTRY_DSN`
and `SENTRY_AUTH_TOKEN`. Several run XcodeGen in `ci_post_clone.sh` and stamp
`CI_BUILD_NUMBER` into `project.yml` or `Project.json`.

The author starts builds **from AI skills**, as in "build Legilo to TestFlight".
Hangar ships its own skills. Xcode Cloud keeps separate ones, and the author's
agent picks whichever fits. The author also wants a browser UI to see
everything and to trigger a deploy.

## Goals

1. **Deploy from the browser.** From the web UI the author picks an app, a
   workflow and a branch or commit, then clicks Deploy. Hangar chooses a
   machine, builds and ships, and shows live progress and logs.
2. **Deploy from AI skills.** Claude Code skills, shipped in this repo, trigger
   and watch builds through the same API the UI uses. They cover Hangar
   only. Xcode Cloud keeps its own separate skills, and the author's agent
   picks whichever fits. Hangar never starts Xcode Cloud builds.
3. **Xcode Cloud compatibility.**
   - Hangar runs the repo's `ci_scripts/ci_post_clone.sh`,
     `ci_pre_xcodebuild.sh` and `ci_post_xcodebuild.sh` at the same moments
     Xcode Cloud does.
   - It sets the same `CI_*` environment variables, so existing scripts work
     unchanged.
4. **Build numbers that never collide or go backwards**, while both Hangar and
   Xcode Cloud are in use (see *Build numbers*).
5. **Machine selection.** Hangar picks an eligible machine with free capacity
   (see *Scheduling*). The author can also pin a machine.
6. **Post-actions for every distribution path:**
   - TestFlight and App Store Connect upload, on all platforms,
   - Developer ID export, notarization and stapling,
   - upload of artifacts to a file host,
   - generating and signing a Sparkle appcast,
   - arbitrary scripts.
7. **Extensibility like Xcode Cloud.** Users add behaviour in two ways:
   - lifecycle hooks (the `ci_*` scripts),
   - post-actions, which are a pluggable, documented module so contributors can
     add new ones such as Slack, GitHub Release or Sentry.
8. **Look and feel.** The UI looks like something Apple makes for consumers.
   This is direction "B" from brainstorming: a large title, app cards with
   icons, machines as widgets with utilisation rings, and a Deploy sheet. All
   UI text is in English, and so are the code, docs and README.

## Non-goals (v1)

- Authentication and multi-user support. The server is reached only over
  Tailscale and binds to the tailnet interface.
- Automatic triggers such as push, tag, schedule or PR webhooks. The author
  triggers every build by hand today. The trigger is still modelled so that
  automatic triggers can be added later.
- Test, analyze and build-only actions. v1 runs archive workflows only, which
  is what the author ships with. Horzono's snapshot tests can stay on Xcode
  Cloud. *(designer's call)*
- Clean VMs per build (Tart or Anka). Builds run as the dedicated `hangar`
  macOS user on each Mac, in a per-app workspace. VM isolation is a later
  executor.
- App Store review submission and editing metadata.
- AI agents inside the build pipeline. Builds are deterministic. The author's
  AI agent sits outside and drives Hangar through the CLI and skills.
- Linux, Android and Windows.

## Anti-goals (would be failure even if it "works")

- A build number that duplicates or goes below one already in App Store
  Connect or an appcast, or that reaches users out of order.
- Requiring users to restructure an Xcode Cloud-ready repo. The only addition
  is the workflow file, `.hangar.yml`.
- Secrets showing up in logs, the UI, the database in plaintext, or a
  worker's disk after the build.
- A UI that looks like Jenkins.
- A skill that can do something the API cannot. Skills are thin clients.

## Decided

### Shape

| Part | What it is |
|---|---|
| `hangar-server` | Swift 6, Hummingbird 2, SQLite. Serves the web UI, the REST API and live updates over SSE. Owns the queue, scheduling, build numbers and secrets. Runs on the Mac mini as a launchd service. |
| `hangar-worker` | Swift CLI daemon, a launchd agent in the `hangar` user's GUI session on each build Mac. It connects **out** to the server and pulls jobs, reports health and resources, runs the pipeline, and streams logs back. |
| `hangar` CLI | Swift client for the API, used by people and by AI skills. Examples: `hangar deploy`, `hangar status`, `hangar logs`, `hangar machines`. |
| Skills | A Claude Code plugin in this repo. Skills call the `hangar` CLI. |
| Shared package | Models, the API contract, and the `.hangar.yml` schema. |

Everything lives in one SwiftPM repo. The licence is MIT. *(builder's call; the
author can change it)*

### Workflows live in the app repo

Each app repo contains a `.hangar.yml`. It declares one or
more workflows. Each workflow has:

- the project or workspace path, which may be in a subdirectory,
- a list of **archive actions**, each a (scheme, platform) pair. Legilo, for
  example, archives `Legilo` for macOS and `LegiloMobile` for iOS,
- the Xcode version,
- the export method for each action: App Store Connect or Developer ID,
- an ordered list of post-actions with their settings.

Apps are registered on the server with their repo URL, App Store Connect app
id and display icon. The workflow definition comes from the repo at the
commit being built.

### Pipeline on the worker

This matches Xcode Cloud. Each archive action runs the **whole sequence on
its own**, with that action's own `CI_PRODUCT_PLATFORM`, `CI_XCODE_SCHEME`,
`CI_XCODEBUILD_ACTION` and `CI_ARCHIVE_PATH`. Actions may run one after
another on one Mac or in parallel on different Macs. All actions in one run
share **one build number**.

For each action:

1. Fetch the source into a per-app cached workspace, check out the requested
   commit, and clean the tree (`git clean -fdx`). Files generated by an
   earlier build's scripts never survive into the next one.
2. Set the Xcode Cloud-compatible `CI_*` environment, including
   `CI_BUILD_NUMBER`, and add this job's secrets.
3. Run `ci_scripts/ci_post_clone.sh` if it exists.
4. Run `ci_scripts/ci_pre_xcodebuild.sh` if it exists.
5. Run `xcodebuild archive` with `-allowProvisioningUpdates`,
   `-allowProvisioningDeviceRegistration` and the App Store Connect API key.
6. **Stamp the build number** as Xcode Cloud does: set `CFBundleVersion` to the
   assigned number in the archived app and in its embedded app extensions,
   App Clips and watch apps. Other embedded bundles, such as privileged
   helpers, keep their own `CFBundleVersion`; BatFi pins its helper on
   purpose. Then check every stamped bundle. Do not override
   `CURRENT_PROJECT_VERSION` globally. Hourly Beep hard-codes
   `CFBundleVersion` 3 in its Info.plist, and BatFi commits 99999, so only
   stamping after the archive gives the right number.
7. Export (`-exportArchive`) with the action's method and
   `manageAppVersionAndBuildNumber = NO`, so Xcode never renumbers the build.
8. Run `ci_scripts/ci_post_xcodebuild.sh` if it exists, with these set:
   `CI_ARCHIVE_PATH`, `CI_APP_STORE_SIGNED_APP_PATH` or
   `CI_DEVELOPER_ID_SIGNED_APP_PATH`, and `CI_RESULT_BUNDLE_PATH`.
9. Run the post-actions in order. The `testflight` action reads
   `TestFlight/WhatToTest.<locale>.txt` from the repo, as Xcode Cloud does.
10. Upload logs, the `.xcresult` when there is one, dSYMs and the exported
    artifact to the server, which keeps them for a set retention period. Then
    wipe this job's secrets from the worker and clean the source tree.
    DerivedData is kept as a cache. Values that scripts compile into the app,
    such as BatFi's `SENTRY_DSN`, ship inside the binary anyway and do not
    count as worker-side secrets.

### Signing

- **Distribution signing at export** uses Xcode's cloud-managed certificates
  through `-allowProvisioningUpdates` and an App Store Connect API key.
- **The archive step still signs locally** with an Apple Development identity.
  Xcode creates that identity through the API key and keeps it in the worker
  user's keychain. That identity is per worker and persistent, and it is not a
  job secret.
- `codesign` needs that user to be **logged in with an unlocked keychain**.
  The worker's health check reports "can sign without a prompt".
- It is not confirmed that an API key, rather than a person signed in to
  Xcode, can use the cloud-managed **Developer ID** certificate. The fallback
  is a Developer ID identity installed on designated workers, and scheduling
  sends Developer ID jobs only to those workers. The first milestone tests
  this as a spike.
- Notarization uses `notarytool` with the same API key.

### Environment variables and secrets (like Xcode Cloud)

**Everything an app needs is set in Hangar's UI**: repo access, the App Store
Connect key, env vars and secrets, appcast feeds and so on. Nothing is set up
by hand on a worker beyond the one-time bootstrap: the `hangar` user, Xcode
and tools. Adding a Mac or changing a key never means touching the other
Macs.

**Secrets are write-only.** You can set, replace or delete a secret, but no
page, API call or CLI command returns its value. Only a job receives it, and
only at run time. This matters because v1 has no login: anyone on the tailnet
can trigger builds, but nobody can read secrets out of Hangar.

- **Each app is configured in Hangar** with environment variables, the way an
  Xcode Cloud workflow is. Each variable is either **plain** or **secret**.
  Examples:
  - `SENTRY_DSN`, `SENTRY_AUTH_TOKEN`,
  - the Sparkle ed25519 private key,
  - R2/S3 credentials,
  - Hangar's own feed and bucket settings.

  There are also global variables, such as the App Store Connect API key
  (a team key with the Admin role), which every app inherits.
- **Hooks, custom scripts and post-actions read everything from the
  environment.** Nothing is read from a worker's keychain or from per-machine
  config files. A value that a tool needs as a file, such as a `.p8` key or a
  Sparkle key, is written to a temp file and exposed through a variable that
  holds its path.
- The server stores secrets **encrypted at rest**. They reach a worker only
  for the length of one job and are wiped afterwards. Log output masks them,
  and the UI never shows them again after entry.
- Custom release scripts that today read keys from a keychain, such as
  Herald's `publish-release.sh`, are adapted to read from env. The "onboard an
  app" skill points out and drafts these changes. Hangar itself never edits
  app repos.
- Workers authenticate to the server with a per-machine token, issued in the
  UI.

### Build numbers

There is one counter per app, shared across platforms and workflows, as in an
Xcode Cloud product.

- **For a Hangar build**, the server assigns `max(every known number) + 1`.
  The known numbers come from:
  - the highest build in App Store Connect for the app, across every platform
    and version,
  - the numbers of all Xcode Cloud runs for the app, including runs still in
    progress,
  - for Developer ID apps, the highest `sparkle:version` in the app's
    published appcast(s). BatFi and Herald have App Store Connect records but
    no App Store Connect builds,
  - Hangar's own assigned and reserved numbers.

  The server records the reservation atomically before the job starts. A
  failed build burns its number, as in Xcode Cloud.
- **Hangar never starts Xcode Cloud builds.** That stays with the author's
  existing App Store Connect scripts and skills. Hangar only **reads** Xcode
  Cloud runs, read-only through the App Store Connect API, to count their
  numbers.
- **Xcode Cloud imposes its own number.** Evidence from the repos: Hourly
  Beep's plist says 3 and BatFi commits 99999, yet both ship rising Xcode Cloud
  numbers (BatFi's appcast shows 227…252). Hangar therefore cannot steer what
  Xcode Cloud ships. It does expose read-only number info for each app:
  `hangar numbers <app>`, also available in the API. The info covers:
  - Hangar's highest and next number,
  - the last Xcode Cloud run's number,
  - whether a Hangar build of that app is in flight.

  Whoever starts an Xcode Cloud run, whether that is the author or their
  separate Xcode Cloud skill, can use this to see whether Xcode Cloud's "Next
  Build Number" needs raising first. That step is outside Hangar.
- **Accepted risk:** an Xcode Cloud run started while a Hangar build of the
  same app is in flight can pick the same number, because the window is the
  whole build. The "in flight" flag in `hangar numbers` makes this visible.
- The UI shows the next number for each app and allows a manual bump, never a
  decrease.

### Scheduling

- **Eligible machine:**
  - it is online and has a free slot (one concurrent build per machine by
    default, configurable),
  - it has the Xcode version the workflow asks for,
  - it has at least a configurable amount of free disk,
  - it has the tools the workflow needs, reported by the worker's health
    check (xcodegen, rclone and so on).
- **Ranking among eligible machines:** idle first, then the faster performance
  class, then more free disk, then a machine on AC power.
- If no machine is eligible, the job queues. The UI says what is missing, for
  example "MacBook Pro: Xcode 27.1 not installed".
- The author can pin a job to a machine.

### Machine health ("doctor")

Workers report the following:

- macOS version and the installed Xcodes and runtimes,
- CPU and memory class,
- free disk and power source,
- current job,
- which known tools are present.

The UI's Machines view shows this, along with what is missing for each
registered app. A bootstrap script, such as a Brewfile plus a checklist, gets
a new Mac ready. The scripts that releases use live in the app repos, and the
skills live in this repo, so there is nothing to sync beyond Hangar itself.

### Web UI (direction B)

- **Pages:**
  - Apps (cards, the default),
  - History,
  - Machines (widgets),
  - App detail (workflows, builds, next build number),
  - Build detail (steps with timing, a live log, artifacts, and the App Store
    Connect or appcast result),
  - Settings (App Store Connect key, secrets, worker tokens, apps).
- **Deploy sheet fields:** workflow, branch or commit, where (Automatic or a
  specific machine), build number preview, and the post-actions summary.
- **App detail also lists Xcode Cloud runs**, read-only, so the numbering of
  both sides is visible in one place.
- Live updates come over SSE.
- The UI works on a phone.
- Light and dark mode follow the system.

### Skills

All of these are thin clients over the `hangar` CLI:

- **deploy**: picks the app, workflow and, optionally, a machine. It starts
  the build, watches it to completion and reports the result.
- **status/logs**: what is running and why a build failed, with log excerpts.
- **onboard an app**: reads the repo's `ci_scripts`, project and release
  scripts, then drafts `.hangar.yml`.

## Left to the builder

- The exact `.hangar.yml` schema, REST and SSE API shape, and database schema.
- The web UI implementation, either server-rendered or a small client app,
  within the look of direction B.
- How the worker gets jobs: long-poll, WebSocket or SSE. In every case the
  worker connects to the server, not the reverse.
- The encryption-at-rest mechanism for secrets, for example a key held in the
  server Mac's Keychain.
- Artifact retention defaults, the log format and the workspace cache policy.
- Which of the author's nine apps to onboard first as proof. The author's
  suggestion is Herald, which covers the Developer ID, notarize, R2 and Sparkle
  path, plus Legilo, which covers multi-platform, XcodeGen and TestFlight.

## Calls made by the designer (not discussed with the author)

- **`.hangar.yml` is required.** A repo without one cannot be built by Hangar.
  The "onboard an app" skill drafts it from the repo's `ci_scripts`, project
  and release scripts. Importing Xcode Cloud workflows through the App Store
  Connect API is not in v1.
- **Projects may live in a subdirectory** of the repo, as Winyl's does under
  `iOS/`. The path is set in `.hangar.yml`. `ci_scripts/` is looked up next to
  the project or workspace, as Xcode Cloud does.
- **Source access.** The server hands the worker a GitHub token for each job,
  through the same secrets mechanism, and wipes it afterwards. This covers
  private repos, submodules and private SPM dependencies.
- **What the TestFlight post-action does:**
  - uploads the build,
  - waits for App Store Connect processing,
  - optionally adds the build to internal tester groups,
  - optionally sets "What to Test".

  Submitting for external beta review is an option and off by default. A build
  counts as "done" once processing completes, or when the upload is accepted
  if the workflow says not to wait.
- **Native `upload` and `sparkle-appcast` post-actions** must produce the same
  output as `scripts/publish-release.sh` (the same object keys, download URLs
  and appcast entries) before they replace it. Otherwise existing installs
  stop updating. Until then, Herald and BatFi publish through their own
  scripts run by the `script` post-action, reading the Sparkle key and the R2
  credentials from Hangar's env vars.
- **Approval gate (optional).** Any post-action can be marked "requires
  approval". The job pauses, and the author confirms in the browser or through
  a skill. This can stand in for the keychain prompt that Herald's script
  treats today as a person confirming a release.
- **Build numbers are plain integers.** A non-integer `CFBundleVersion` found in
  App Store Connect or an appcast is reported as an error, not guessed at.
- The name "Hangar" and the `.hangar.yml` file name.
- MIT licence.
- v1 runs archive workflows only, with no test or analyze actions.
- Builds run directly on the Mac, not in VMs.
- The repo is created locally first and only published to GitHub with the
  author's go-ahead.

## Decisions by the author (resolved after review)

1. Hangar never starts Xcode Cloud builds. It only reads Xcode Cloud's numbers
   for its own counter. Skills for Xcode Cloud are separate and outside this
   project.
2. Workers run as a **dedicated `hangar` macOS user** on each Mac, logged in
   permanently in the background through fast user switching. The development
   signing identity in that user's keychain is persistent.
3. **Everything a build or release script needs comes from per-app
   environment variables configured in Hangar**, as in Xcode Cloud.
4. The App Store Connect API key is a **team key with the Admin role**.
   Whether it can use the cloud-managed Developer ID certificate is still
   checked as an early spike.

## Process

Planning (the implementation plan) is done with the **Fable** model at **high**
reasoning effort, at the author's request.
