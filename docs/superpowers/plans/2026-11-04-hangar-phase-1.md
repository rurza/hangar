# Hangar Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A worker, a server core and a `hangar` CLI that archive Legilo (macOS `Legilo`, iOS `LegiloMobile`) on the author's Macs with a collision-free build number and ship it to TestFlight, plus a recorded answer to "can an ASC API key export with a cloud-managed Developer ID certificate?".

**Architecture:** One SwiftPM monorepo. `HangarCore` holds the models, the `.hangar.yml` schema, the Xcode Cloud `CI_*` environment builder, the secret masker and the process-runner seam. `HangarServer` (Hummingbird 2 + GRDB/SQLite) owns apps, variables, build numbers, the queue and scheduler, logs and artifacts, and serves the REST API, the SSE streams and the worker API. `HangarWorker` pulls jobs by long-poll, runs the Xcode Cloud-shaped pipeline per archive action with a `ProcessRunner` seam, stamps `CFBundleVersion` after the archive, runs post-actions, and streams masked logs back. `HangarClient` + `hangar` CLI talk to the API; the Claude Code plugin shells out to `hangar`.

**Tech Stack:** Swift 6.4 (strict concurrency, `swift-tools-version:6.0`, macOS 15+), Hummingbird 2, GRDB.swift 7, swift-argument-parser, Yams, swift-dependencies (clock, process runner, ASC client, source host), CryptoKit (AES-GCM secrets, ES256 ASC JWT), swift-log, Swift Testing, HummingbirdTesting.

**Spec:** `/Users/adam/Developer/hangar/docs/superpowers/specs/2026-11-04-hangar-design.md`

## Global Constraints

- Swift 6 language mode with strict concurrency in every target; no `@unchecked Sendable` without a comment saying why.
- One SwiftPM package; executables `hangar-server`, `hangar-worker`, `hangar`; libraries `HangarCore`, `HangarAppStoreConnect`, `HangarServer`, `HangarWorker`, `HangarClient`. Licence MIT. All code, docs, CLI copy and README in English.
- Swift Testing for tests (`@Test`, `#expect`). No real `xcodebuild`, App Store Connect, GitHub or `notarytool` call in a unit test; those go behind `ProcessRunner`, `AppStoreConnectClient`, `SourceHost`, `HTTPTransport` and `Clock` seams. Real-world checks are explicit manual steps.
- Secrets are write-only: no API response, CLI output, log line or DB row holds a secret in plaintext. Logs are masked on the worker before they leave it.
- Archive workflows only. `.hangar.yml` is required at the built commit. Build numbers are plain integers; a non-integer `CFBundleVersion` from App Store Connect is an error, never guessed at.
- Build number = `max(every known number) + 1`, reserved atomically before the job starts; a failed build burns its number; manual bump never decreases.
- Pipeline order per action is fixed by the spec: checkout → `ci_post_clone.sh` → `ci_pre_xcodebuild.sh` → `xcodebuild archive` (`-allowProvisioningUpdates -allowProvisioningDeviceRegistration` + ASC key) → stamp `CFBundleVersion` → `-exportArchive` with `manageAppVersionAndBuildNumber = NO` → `ci_post_xcodebuild.sh` → post-actions → upload artifacts → wipe secrets and clean tree. `ci_scripts/` lives next to the project or workspace; hooks run with cwd `ci_scripts/`.
- Stamping touches the archived app, its app extensions (`PlugIns/*.appex`, `Extensions/*.appex`), App Clips and watch apps only; login-item helpers, privileged helpers, XPC services and frameworks keep their own `CFBundleVersion`. `CURRENT_PROJECT_VERSION` is never overridden globally.
- Hangar never starts an Xcode Cloud build; it reads Xcode Cloud run numbers read-only.
- Workers connect out to the server; the server binds the Tailscale interface; one concurrent job per machine by default; no fastlane or Ruby.
- Workers run as the `hangar` macOS user, logged in via fast user switching, as a launchd agent in that GUI session.
- Commit messages are plain; no AI attribution lines.

## Review Focus

Spec-implied inputs no task's tests would otherwise exercise; each line's test is added to the task named.

1. `.hangar.yml` missing, unparsable or naming an unknown post-action at the requested commit → `hangar deploy` is refused with the error and no build number is reserved (Task 11).
2. A `ci_*` script that exists but lacks the executable bit → Hangar runs it through `/bin/sh` and logs a warning, rather than failing minutes later with "permission denied" (Task 17).
3. A worker that stops reporting while a job runs → the job fails with "worker lost" within 120 s, the build fails, the number stays burned and the next deploy gets a higher number (Task 10).
4. App Store Connect unreachable, or a build whose `CFBundleVersion` is `1.2.3` → deploy refused, `hangar numbers` reports the error, nothing reserved (Task 9).
5. A secret that appears in a log line percent-encoded, or a multi-line secret (a `.p8`) of which only one line is printed → still masked (Task 5).

---

## File structure

```
Package.swift
LICENSE, README.md, .gitignore
Sources/
  HangarCore/            models, .hangar.yml, CI env, masking, ProcessRunner seam, JSONValue
    Models/App.swift, Variable.swift, Build.swift, Job.swift, Machine.swift, Numbers.swift
    API/Requests.swift, WorkerAPI.swift        (DTOs shared by server, worker and CLI)
    Workflow/WorkflowFile.swift, WorkflowFileParser.swift, PostActionCatalog.swift, TestFlightSettings.swift
    Environment/CIEnvironment.swift, EnvEntry.swift
    Secrets/SecretMasker.swift
    Process/ProcessRunner.swift, RecordingProcessRunner.swift
    Support/JSONValue.swift, XcodeVersion.swift, Dependencies.swift, HTTPTransport.swift
  HangarAppStoreConnect/ ASCJWT.swift, AppStoreConnectClient.swift, LiveAppStoreConnectClient.swift, Models.swift
  HangarServer/
    Database/Database.swift, Migrations.swift
    Secrets/SecretBox.swift, MasterKey.swift
    Repositories/AppRepository.swift, VariableRepository.swift, BuildRepository.swift, MachineRepository.swift
    Numbers/BuildNumberService.swift, KnownNumberSources.swift
    Scheduling/Scheduler.swift, SchedulerLoop.swift
    Builds/BuildService.swift, SourceHost.swift, GitHubSourceHost.swift
    Storage/LogStore.swift, ArtifactStore.swift, RetentionSweeper.swift
    Events/EventBus.swift
    API/Router.swift, AppsAPI.swift, VariablesAPI.swift, MachinesAPI.swift, BuildsAPI.swift, NumbersAPI.swift, SSE.swift
    WorkerAPI/WorkerRoutes.swift, MachineAuth.swift
    ServerConfiguration.swift, HangarServerApp.swift
  hangar-server/main.swift
  HangarWorker/
    Doctor/Doctor.swift, XcodeLocator.swift
    Connection/ServerConnection.swift
    Workspace/WorkspaceLayout.swift, SecretsMaterializer.swift
    Steps/Checkout.swift, HookRunner.swift, ArchiveStep.swift, ExportStep.swift, BuildNumberStamper.swift, ArtifactCollector.swift
    PostActions/PostActionModule.swift, TestFlightAction.swift
    JobRunner.swift, JobLog.swift, WorkerLoop.swift, WorkerConfiguration.swift
  hangar-worker/main.swift
  HangarClient/HangarAPI.swift, SSEReader.swift
  hangar/ Hangar.swift, Commands/*.swift, Output/Table.swift
Tests/ HangarCoreTests, HangarAppStoreConnectTests, HangarServerTests, HangarWorkerTests, HangarClientTests, hangarTests
plugins/hangar/.claude-plugin/plugin.json, skills/hangar-deploy/SKILL.md, skills/hangar-status/SKILL.md
scripts/spike/developer-id-cloud-signing.sh
scripts/server/install-server.sh, app.hangar.server.plist
scripts/worker/Brewfile, install-worker.sh, app.hangar.worker.plist
docs/spikes/2026-11-developer-id-cloud-signing.md
docs/worker-setup.md, docs/server-setup.md, docs/hangar-yml.md, docs/api.md
```

Shared vocabulary used by every task (defined in Tasks 3–6, repeated nowhere else):

- `Platform` (`ios`, `macos`, `visionos`, `tvos`, `watchos`), `ExportMethod` (`app-store-connect`, `developer-id`), `ArchiveAction { scheme, platform, export }`, `Workflow`, `WorkflowFile`, `PostActionSpec`.
- `App`, `Variable`/`VariableSummary`/`EnvEntry`, `Build`, `Job`, `StepRecord`, `Machine`, `MachineReport`, `NumbersReport`, `JobAssignment`.
- `ProcessRunner`, `ProcessCommand`, `ProcessOutcome`.
- Reserved variable names: `HANGAR_ASC_KEY_ID`, `HANGAR_ASC_ISSUER_ID` (plain), `HANGAR_ASC_KEY_PATH` (secret, as-file), `HANGAR_GITHUB_TOKEN` (secret). An as-file variable's env value is the path of a 0600 temp file holding the stored value.
- Data directories: server `~/Library/Application Support/Hangar/server/` (`hangar.sqlite`, `master.key`, `jobs/<jobID>/log.jsonl`, `jobs/<jobID>/artifacts/`); worker `~/Library/Application Support/Hangar/worker/` (`config.json`, `workspaces/<appSlug>/repository`, `workspaces/<appSlug>/DerivedData`, `jobs/<jobID>/{secrets,archive,export,upload,result.xcresult}`).
- Ports and labels: server port 8787; launchd labels `app.hangar.server`, `app.hangar.worker`.

---

### Task 1: Package scaffold

**Files:**
- Create: `Package.swift`, `LICENSE`, `README.md`, `.gitignore`, one placeholder `.swift` per target, `Tests/HangarCoreTests/SmokeTests.swift`

**Interfaces:**
- Produces: the target graph. `HangarCore` depends on swift-dependencies and Yams. `HangarAppStoreConnect` → Core. `HangarServer` → Core, ASC, Hummingbird, GRDB, swift-log. `HangarWorker` → Core, ASC. `HangarClient` → Core. `hangar` → Client, ArgumentParser. `hangar-server` → Server, ArgumentParser. `hangar-worker` → Worker, ArgumentParser. Test targets mirror libraries; `HangarServerTests` adds HummingbirdTesting.

- [ ] **Step 1: Write `Package.swift`** with `swift-tools-version:6.0`, `platforms: [.macOS(.v15)]`, `swiftLanguageModes: [.v6]`, dependencies pinned `from:` — hummingbird 2.x, GRDB.swift 7.x, swift-argument-parser 1.5+, Yams 5.x, swift-dependencies 1.x, swift-log 1.6+. MIT `LICENSE` with the author's name. `.gitignore`: `.build/`, `*.xcodeproj`, `.swiftpm/`, `.DS_Store`.
- [ ] **Step 2: Write `SmokeTests.swift`** with `@Test func packageBuilds() { #expect(true) }`.
- [ ] **Step 3: Run** `swift build && swift test`. Expected: all targets build, 1 test passes.
- [ ] **Step 4: Commit** `build: scaffold SwiftPM package with Hangar targets`.

### Task 2: Developer ID cloud-signing spike

Answers the spec's open question early and independently of the TestFlight path. Nothing later in Phase 1 depends on its result; Phase 2 branches on it (see *How the spike branches the plan* at the end).

**Files:**
- Create: `scripts/spike/developer-id-cloud-signing.sh`, `docs/spikes/2026-11-developer-id-cloud-signing.md`

- [ ] **Step 1: Write the script.** Usage: `developer-id-cloud-signing.sh --archive <path.xcarchive> --team <TEAMID> --key-id <ID> --issuer-id <ID> --key <AuthKey.p8> [--out <dir>]`. It writes `ExportOptions.plist` with `method = developer-id`, `signingStyle = automatic`, `teamID`, `manageAppVersionAndBuildNumber = false`, `destination = export`; runs `xcodebuild -exportArchive -archivePath … -exportOptionsPlist … -exportPath <out> -allowProvisioningUpdates -authenticationKeyPath … -authenticationKeyID … -authenticationKeyIssuerID …`; on success runs `codesign -dvv --verbose=2 <out>/*.app` and greps `Authority=Developer ID Application`. Prints `RESULT: PASS` or `RESULT: FAIL` plus the last 40 lines of xcodebuild output. Exit code mirrors the result.
- [ ] **Step 2: Produce an archive to test with (manual, on `rurzomac-mini` as the `hangar` user).** Clone Herald, run `ci_scripts/ci_post_clone.sh` with `CI_PRIMARY_REPOSITORY_PATH` set, then `xcodebuild archive -scheme <Herald scheme> -destination 'generic/platform=macOS' -archivePath /tmp/spike/Herald.xcarchive -allowProvisioningUpdates -authenticationKeyPath … -authenticationKeyID … -authenticationKeyIssuerID …`. Expected: an archive; note whether this created an Apple Development identity in the `hangar` user's login keychain (`security find-identity -v -p codesigning`).
- [ ] **Step 3: Run the spike twice and record.** Run A: with no Developer ID certificate present in the keychain. Run B (only if A fails): after the author opens Xcode once as `hangar`, signed in, and lets Xcode create/download the cloud-managed Developer ID certificate, then run again. Record in `docs/spikes/2026-11-developer-id-cloud-signing.md`: date, macOS and Xcode build, the exact command, `RESULT`, the first error line for a failure, which keychain identities existed, and the conclusion: **Outcome A** "API key can export Developer ID via cloud-managed signing" or **Outcome B** "it cannot; Phase 2 uses the temporary-keychain `.p12` fallback".
- [ ] **Step 4: Commit** `spike: record Developer ID cloud-signing result` (script + doc).

### Task 3: `.hangar.yml` schema and parser

**Files:**
- Create: `Sources/HangarCore/Workflow/WorkflowFile.swift`, `WorkflowFileParser.swift`, `PostActionCatalog.swift`, `TestFlightSettings.swift`, `Sources/HangarCore/Support/JSONValue.swift`, `docs/hangar-yml.md`
- Test: `Tests/HangarCoreTests/WorkflowFileParserTests.swift`

**Interfaces:**
- Produces:
  - `enum Platform: String, Codable, Sendable, CaseIterable { case iOS = "ios", macOS = "macos", visionOS = "visionos", tvOS = "tvos", watchOS = "watchos" }` with `var ciName: String` (`iOS`, `macOS`, `visionOS`, `tvOS`, `watchOS`), `var genericDestination: String` (`generic/platform=iOS` …), `var appStoreConnectPlatform: String` (`IOS`, `MAC_OS`, `VISION_OS`, `TV_OS`, `WATCH_OS`).
  - `enum ExportMethod: String, Codable, Sendable { case appStoreConnect = "app-store-connect", developerID = "developer-id" }`.
  - `struct ArchiveAction: Codable, Hashable, Sendable { var scheme: String; var platform: Platform; var export: ExportMethod }`.
  - `struct PostActionSpec: Codable, Equatable, Sendable { var name: String; var settings: [String: JSONValue]; var requiresApproval: Bool }`.
  - `struct Workflow: Codable, Equatable, Sendable { var project: String?; var workspace: String?; var xcode: String; var teamID: String?; var tools: [String]; var actions: [ArchiveAction]; var postActions: [PostActionSpec] }` with `var projectOrWorkspacePath: String`, `var projectDirectory: String` (dirname of it).
  - `struct WorkflowFile: Codable, Equatable, Sendable { static let path = ".hangar.yml"; var version: Int; var workflows: [String: Workflow] }`.
  - `enum JSONValue: Codable, Equatable, Sendable { case string(String), int(Int), double(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue]) }`.
  - `enum WorkflowFileError: Error, Equatable, Sendable { case invalidYAML(String), unsupportedVersion(Int), noWorkflows, projectAndWorkspace(workflow: String), noProject(workflow: String), noActions(workflow: String), unknownPlatform(String), unknownExportMethod(String), unknownPostAction(name: String, workflow: String), invalidPostActionSettings(name: String, reason: String) }` with `CustomStringConvertible`.
  - `enum WorkflowFileParser { static func parse(_ yaml: String) throws(WorkflowFileError) -> WorkflowFile }`.
  - `protocol PostActionSettings: Codable, Sendable { static var actionName: String { get }; init(settings: [String: JSONValue]) throws(WorkflowFileError) }`.
  - `enum PostActionCatalog { static let all: [any PostActionSettings.Type]  /* Phase 1: [TestFlightSettings.self] */; static func validate(_ spec: PostActionSpec, workflow: String) throws(WorkflowFileError) }`.
  - `struct TestFlightSettings: PostActionSettings { static let actionName = "testflight"; var waitForProcessing = true; var processingTimeoutMinutes = 60; var groups: [String] = []; var whatToTest = true; var submitForExternalReview = false }`. YAML keys kebab-case: `wait-for-processing`, `processing-timeout-minutes`, `groups`, `what-to-test`, `submit-for-external-review`.

The YAML shape (document it in `docs/hangar-yml.md` with Legilo as the example):

```yaml
version: 1
workflows:
  testflight:
    project: Legilo.xcodeproj        # or `workspace:`; relative to the repo root
    xcode: "27.2"                    # prefix match against installed Xcodes
    team: YL78V8PY6H                 # optional
    tools: [brew]                    # optional; names the worker must report
    actions:
      - { scheme: Legilo, platform: macos, export: app-store-connect }
      - { scheme: LegiloMobile, platform: ios, export: app-store-connect }
    post-actions:
      - testflight:
          groups: [Internal]
```

A post-action entry is a one-key map (`name: settings`) or a bare string (`- testflight`); `requires-approval: true` inside the settings is lifted into `PostActionSpec.requiresApproval` and removed from `settings`.

- [ ] **Step 1: Write failing tests** in `WorkflowFileParserTests`: `parsesLegiloExample` (the YAML above → two actions with the exact scheme/platform/export values, `postActions == [PostActionSpec(name: "testflight", settings: ["groups": .array([.string("Internal")])], requiresApproval: false)]`, `projectDirectory == "."`); `bareStringPostAction` (`- testflight` → empty settings); `liftsRequiresApproval`; `rejectsUnknownPostAction` (`#expect(throws: WorkflowFileError.unknownPostAction(name: "slack", workflow: "testflight"))`); `rejectsVersion2`; `rejectsProjectAndWorkspace`; `rejectsEmptyActions`; `rejectsUnknownPlatform` (`platform: android`); `rejectsBadTestFlightSetting` (`groups: 3` → `.invalidPostActionSettings`); `invalidYAMLCarriesMessage`; `projectInSubdirectory` (`project: iOS/Winyl.xcodeproj` → `projectDirectory == "iOS"`).
- [ ] **Step 2: Run** `swift test --filter WorkflowFileParserTests`. Expected: compile failure (types missing).
- [ ] **Step 3: Implement** the types and parser. Parse with Yams into `JSONValue` first (`Yams.load` → `Any` → `JSONValue`), then map by hand so error cases name the workflow; `PostActionCatalog.validate` constructs the settings type by name and converts its throw into `.invalidPostActionSettings`.
- [ ] **Step 4: Run** `swift test --filter WorkflowFileParserTests`. Expected: PASS.
- [ ] **Step 5: Write `docs/hangar-yml.md`** (keys, defaults, the TestFlight settings table, the example).
- [ ] **Step 6: Commit** `feat(core): parse and validate .hangar.yml`.

### Task 4: Domain models, API DTOs and status derivation

**Files:**
- Create: `Sources/HangarCore/Models/{App,Variable,Build,Job,Machine,Numbers}.swift`, `Sources/HangarCore/API/{Requests,WorkerAPI}.swift`, `Sources/HangarCore/Support/XcodeVersion.swift`
- Test: `Tests/HangarCoreTests/StatusDerivationTests.swift`, `XcodeVersionTests.swift`, `ModelCodingTests.swift`

**Interfaces:**
- Produces (all `Codable, Sendable, Equatable`, ids are `UUID`, dates `Date`, JSON keys camelCase, dates ISO 8601):
  - `struct App: Identifiable { id; slug: String; name: String; repoURL: String; appStoreConnectAppID: String; iconURL: String?; createdAt }`. `slug` = lowercased name with non-alphanumerics → `-`, unique.
  - `enum VariableScope: Hashable { case global, app(UUID) }`; `struct VariableSummary { scope; name; isSecret: Bool; asFile: Bool; updatedAt }`; `struct VariableInput { value: String; isSecret: Bool; asFile: Bool }`; `struct EnvEntry { name; value; isSecret; asFile }`.
  - `enum BuildStatus: String { queued, running, succeeded, failed, cancelled }`; `enum JobStatus: String { queued, assigned, running, succeeded, failed, cancelled }` with `var isTerminal: Bool`; `enum StepStatus: String { pending, running, succeeded, failed, skipped }`.
  - `enum StepName { static let checkout = "checkout", postClone = "post-clone", preXcodebuild = "pre-xcodebuild", archive = "archive", stamp = "stamp", export = "export", postXcodebuild = "post-xcodebuild", uploadArtifacts = "upload-artifacts", cleanup = "cleanup"; static func postAction(_ name: String) -> String /* "post-action:testflight" */ }`.
  - `struct StepRecord { name: String; status: StepStatus; startedAt: Date?; finishedAt: Date? }`.
  - `struct Job: Identifiable { id; buildID; action: ArchiveAction; status: JobStatus; machineID: UUID?; steps: [StepRecord]; queueNote: String?; failureReason: String?; outputs: [String: String]; createdAt; assignedAt: Date?; startedAt: Date?; finishedAt: Date? }`.
  - `struct Build: Identifiable { id; appID; workflow: String; ref: String; commit: String; buildNumber: Int; status: BuildStatus; pinnedMachineID: UUID?; createdAt; finishedAt: Date?; jobs: [Job] }`.
  - `extension BuildStatus { static func derived(from jobs: [JobStatus]) -> BuildStatus }` — any `running`/`assigned` → `running`; else any `queued` → `queued`; else all `succeeded` → `succeeded`; else any `failed` → `failed`; else `cancelled`.
  - `struct InstalledXcode { version: String; build: String; path: String }`; `struct MachineReport { macOSVersion: String; xcodes: [InstalledXcode]; chip: String; performanceCores: Int; memoryGB: Int; freeDiskGB: Double; onACPower: Bool; tools: [String: String]; canSignWithoutPrompt: Bool; runningJobIDs: [UUID] }`; `struct Machine: Identifiable { id; name; maxConcurrentJobs: Int; lastSeenAt: Date?; report: MachineReport?; createdAt }` with `func isOnline(now: Date, timeout: TimeInterval = 90) -> Bool`.
  - `struct NumbersReport { appID; highestHangar: Int?; next: Int; highestAppStoreConnect: Int?; lastXcodeCloudRun: Int?; inFlight: Bool }`.
  - Requests: `DeployRequest { app: String; workflow: String; ref: String; machine: String? }`, `CreateAppRequest { name; repoURL; appStoreConnectAppID; iconURL? }`, `CreateMachineRequest { name; maxConcurrentJobs: Int = 1 }`, `CreateMachineResponse { machine: Machine; token: String }`, `BumpNumberRequest { next: Int }`, `APIError: Error { code: String; message: String }` (the JSON error body).
  - `enum ServerEvent: Codable, Sendable { case build(Build), job(Job), machine(Machine) }` — the SSE payload of `/events`.
  - Worker API: `JobAssignment { job: Job; app: App; workflow: Workflow; buildNumber: Int; commit: String; ref: String; environment: [EnvEntry] }`, `HeartbeatRequest { report: MachineReport }`, `HeartbeatResponse { cancelJobIDs: [UUID] }`, `StepUpdate { name; status; at: Date }`, `LogEntry { t: Date; step: String; line: String }`, `LogBatch { entries: [LogEntry] }`, `JobResult { status: JobStatus; failureReason: String?; outputs: [String: String] }`.
  - `enum XcodeVersion { static func matches(requested: String, installed: String) -> Bool /* component-prefix: "27.2" matches "27.2" and "27.2.1", not "27.20" */; static func best(_ installed: [InstalledXcode], requested: String) -> InstalledXcode? /* highest matching */ }`.

- [ ] **Step 1: Write failing tests**: `StatusDerivationTests` with one `@Test(arguments:)` table covering the five rules plus `[.succeeded, .failed] → .failed`, `[.cancelled, .succeeded] → .cancelled`, `[.queued, .failed] → .queued`; `XcodeVersionTests.prefixMatchIsComponentWise` (`"27.2"` vs `"27.20"` false; `"27"` vs `"27.2.1"` true) and `bestPicksHighest`; `ModelCodingTests.jobAssignmentRoundTrips` (encode → decode equals, ISO dates).
- [ ] **Step 2: Run** `swift test --filter 'StatusDerivationTests|XcodeVersionTests|ModelCodingTests'`. Expected: compile failure.
- [ ] **Step 3: Implement** the types; a shared `JSONCoding.encoder/decoder` in `Support` with `.iso8601` dates used by server, worker and client.
- [ ] **Step 4: Run** the same filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): domain models, API DTOs and build status derivation`.

### Task 5: Secret masker

**Files:**
- Create: `Sources/HangarCore/Secrets/SecretMasker.swift`
- Test: `Tests/HangarCoreTests/SecretMaskerTests.swift`

**Interfaces:**
- Produces: `struct SecretMasker: Sendable { init(secrets: [String]); func mask(_ line: String) -> String }`. Replacement token `[masked]`. Patterns per secret: the raw value; each line of a multi-line value; the percent-encoded form (`addingPercentEncoding(withAllowedCharacters: .alphanumerics)`); the base64 of the UTF-8 bytes. Candidates shorter than 4 characters are ignored (never mask `yes`). Longest match first.

- [ ] **Step 1: Write failing tests**: `masksRawValue`, `masksEachLineOfMultilineSecret` (a fake 3-line PEM; printing line 2 alone is masked), `masksPercentEncodedValue` (`p@ss/word` inside a URL), `masksBase64Value`, `ignoresShortSecrets` (`"ab"` leaves `"abc"` alone), `masksLongestFirst` (secrets `abc12345` and `abc12345-suffix` on a line containing the long one → single token), `emptyMaskerIsIdentity`.
- [ ] **Step 2: Run** `swift test --filter SecretMaskerTests`. Expected: compile failure.
- [ ] **Step 3: Implement** with precomputed sorted patterns and plain `replacingOccurrences`.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): secret masker`.

### Task 6: CI environment builder and process-runner seam

**Files:**
- Create: `Sources/HangarCore/Environment/CIEnvironment.swift`, `Sources/HangarCore/Process/ProcessRunner.swift`, `RecordingProcessRunner.swift`, `Sources/HangarCore/Support/Dependencies.swift`
- Test: `Tests/HangarCoreTests/CIEnvironmentTests.swift`, `RecordingProcessRunnerTests.swift`

**Interfaces:**
- Produces:
  - `struct CIEnvironment { struct Paths { repository: String; projectFile: String; derivedData: String; archive: String; resultBundle: String; workspace: String } ; static func make(app: App, workflow name: String, action: ArchiveAction, buildNumber: Int, jobID: UUID, buildID: UUID, commit: String, ref: String, teamID: String?, paths: Paths, developerDir: String, basePATH: String) -> [String: String] }`.
    Fixed values: `CI=TRUE`, `CI_HANGAR=TRUE` (and **not** `CI_XCODE_CLOUD`), `CI_START_CONDITION=manual`, `CI_XCODEBUILD_ACTION=archive`, `CI_PRIMARY_REPOSITORY_PATH`, `CI_WORKSPACE` (job directory), `CI_PROJECT_FILE_PATH`, `CI_DERIVED_DATA_PATH`, `CI_ARCHIVE_PATH`, `CI_RESULT_BUNDLE_PATH`, `CI_BUILD_NUMBER`, `CI_BUILD_ID` (job id), `CI_WORKFLOW`, `CI_WORKFLOW_ID` (same as `CI_WORKFLOW`), `CI_PRODUCT` (app name), `CI_PRODUCT_ID` (app slug), `CI_PRODUCT_PLATFORM` (`platform.ciName`), `CI_XCODE_SCHEME`, `CI_COMMIT`, `CI_BRANCH` (ref when it is not a 40-hex SHA), `CI_TEAM_ID` (when known), `DEVELOPER_DIR`, `PATH = basePATH + ":/opt/homebrew/bin:/usr/local/bin"` (deduplicated), `HOME` passthrough, `GIT_TERMINAL_PROMPT=0`.
  - `static func postXcodebuildAdditions(exitCode: Int32, action: ArchiveAction, exportedAppPath: String?) -> [String: String]` → `CI_XCODEBUILD_EXIT_CODE`, and `CI_APP_STORE_SIGNED_APP_PATH` or `CI_DEVELOPER_ID_SIGNED_APP_PATH` by `action.export`.
  - `struct MergedEnvironment { env: [String: String]; filesToWrite: [(path: String, contents: String)]; warnings: [String] }`; `static func merge(ci: [String: String], entries: [EnvEntry], secretsDirectory: String) -> MergedEnvironment` — app/global entries override nothing in the `CI_*` set (a user variable named `CI_BUILD_NUMBER` is dropped with a warning); as-file entries map to `<secretsDirectory>/<NAME>`.
  - `struct ProcessCommand: Sendable { executable: String; arguments: [String]; environment: [String: String]; currentDirectory: String? }`, `struct ProcessOutcome: Sendable { exitCode: Int32; output: String }`, `protocol ProcessRunner: Sendable { func run(_ command: ProcessCommand, onLine: @Sendable (String) -> Void) async throws -> ProcessOutcome }` (stdout and stderr merged line-wise, in order of arrival); `struct LiveProcessRunner: ProcessRunner` (Foundation `Process`, kills the child on task cancellation); `final class RecordingProcessRunner: ProcessRunner` (actor-isolated: `var commands: [ProcessCommand]`, `func script(_ match: (ProcessCommand) -> Bool, lines: [String], exitCode: Int32)`; unscripted commands return exit 0 with no output).
  - `DependencyValues.processRunner` (swift-dependencies, live = `LiveProcessRunner`, test = `RecordingProcessRunner`).

- [ ] **Step 1: Write failing tests**: `CIEnvironmentTests.setsXcodeCloudVariablesForLegiloMobile` (asserts every fixed key above with exact values for `LegiloMobile`/`ios`, build 311, ref `main`); `shaRefSetsNoBranch`; `postXcodebuildAdditionsAppStore` and `…DeveloperID`; `userVariablesCannotOverrideCI` (warning text contains `CI_BUILD_NUMBER`); `asFileEntryBecomesPath` (`HANGAR_ASC_KEY_PATH` → env value `<dir>/HANGAR_ASC_KEY_PATH`, file contents = stored value); `RecordingProcessRunnerTests.scriptedOutcomeAndRecording`.
- [ ] **Step 2: Run** `swift test --filter 'CIEnvironmentTests|RecordingProcessRunnerTests'`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): Xcode Cloud-compatible CI environment and process runner seam`.

### Task 7: Server database and secrets at rest

**Files:**
- Create: `Sources/HangarServer/Database/{Database,Migrations}.swift`, `Sources/HangarServer/Secrets/{SecretBox,MasterKey}.swift`, `Sources/HangarServer/Repositories/{AppRepository,VariableRepository,BuildRepository,MachineRepository}.swift`
- Test: `Tests/HangarServerTests/{SecretBoxTests,VariableRepositoryTests,BuildRepositoryTests,MachineRepositoryTests}.swift`

**Interfaces:**
- Produces:
  - `final class Database: Sendable { init(path: String) throws /* ":memory:" allowed */; let pool: DatabaseWriter; func migrate() throws }`. Tables: `apps`, `variables(scope TEXT, app_id, name, ciphertext BLOB, is_secret, as_file, updated_at, UNIQUE(scope, app_id, name))`, `machines(id, name UNIQUE, token_hash, max_concurrent_jobs, last_seen_at, report_json, created_at)`, `builds`, `jobs(…, steps_json, outputs_json)`, `build_numbers(app_id, number, build_id, UNIQUE(app_id, number))`, `app_counters(app_id PRIMARY KEY, highest_assigned INTEGER)`. SQLite in WAL mode, foreign keys on.
  - `struct MasterKey { static func loadOrCreate(at path: String) throws -> SymmetricKey }` — 32 random bytes, file mode 0600, created once.
  - `struct SecretBox: Sendable { init(key: SymmetricKey); func seal(_ plaintext: String) throws -> Data; func open(_ sealed: Data) throws -> String }` — AES-GCM, `combined` representation.
  - `AppRepository`: `create(CreateAppRequest) throws -> App` (slug derived, duplicate slug → `APIError(code: "app_exists")`), `all()`, `find(slugOrID: String) -> App?`, `delete(id)`.
  - `VariableRepository`: `set(scope:, name:, input: VariableInput) throws`, `delete(scope:, name:)`, `summaries(scope:) -> [VariableSummary]`, `resolvedEntries(appID:) throws -> [EnvEntry]` (global then app, app wins, values decrypted), `value(global name: String) throws -> String?`. **Every** value is sealed, plain or secret; `isSecret` only governs what the API shows later.
  - `MachineRepository`: `create(name:, maxConcurrentJobs:) throws -> (Machine, token: String)` (token = 32 random bytes base64url; store SHA-256 hex), `authenticate(token:) -> Machine?`, `all()`, `find(nameOrID:)`, `updateReport(id:, report:, seenAt:)`, `delete(id)`.
  - `BuildRepository`: `insert(Build) throws`, `build(id:) -> Build?` (with jobs), `builds(appID: UUID?, limit: Int) -> [Build]`, `jobs(status: Set<JobStatus>) -> [Job]`, `job(id:) -> Job?`, `assign(jobID:, to machineID:, at:) throws -> Bool` (`UPDATE jobs SET status='assigned', machine_id, assigned_at WHERE id=? AND status='queued'`, true when one row changed), `unassign(jobID:)`, `setJobStatus(id:, status:, at:, failureReason: String?)`, `setQueueNote(jobID:, note: String?)`, `upsertStep(jobID:, StepUpdate)`, `setOutputs(jobID:, [String: String])`, `refreshBuildStatus(buildID:) throws -> Build` (applies `BuildStatus.derived`, sets `finishedAt` when terminal), `inFlight(appID:) -> Bool`, `reserveNumber(appID:, number:, buildID:) throws` (within the caller's write transaction), `highestAssigned(appID:) -> Int?`, `setHighestAssigned(appID:, Int)`.
  - All repositories are `struct`s over `Database` and expose `func inTransaction<T>(_ body: (GRDB.Database) throws -> T) throws -> T` where the service layer needs atomicity.

- [ ] **Step 1: Write failing tests**: `SecretBoxTests.roundTripsAndDiffersPerSeal`, `SecretBoxTests.rejectsTamperedCiphertext`; `VariableRepositoryTests.appOverridesGlobal`, `VariableRepositoryTests.plaintextNeverInDatabaseFile` (on-disk DB in a temp dir; after `set`, read the file bytes and `#expect(!bytes.contains("hunter2-plaintext"))`), `VariableRepositoryTests.summariesCarryNoValue`; `BuildRepositoryTests.assignIsAtomic` (two `assign` calls for one job → exactly one `true`), `BuildRepositoryTests.refreshBuildStatusDerives`, `BuildRepositoryTests.duplicateReservedNumberThrows`; `MachineRepositoryTests.tokenShownOnceAndHashed` (authenticate with returned token works; the stored `token_hash` ≠ token).
- [ ] **Step 2: Run** `swift test --filter HangarServerTests`. Expected: compile failure.
- [ ] **Step 3: Implement** migrations with GRDB `DatabaseMigrator` (`v1`) and the repositories.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(server): SQLite schema, repositories and AES-GCM secret storage`.

### Task 8: App Store Connect client

**Files:**
- Create: `Sources/HangarCore/Support/HTTPTransport.swift`, `Sources/HangarAppStoreConnect/{ASCJWT,Models,AppStoreConnectClient,LiveAppStoreConnectClient}.swift`
- Test: `Tests/HangarAppStoreConnectTests/{ASCJWTTests,LiveClientDecodingTests}.swift`, fixtures under `Tests/HangarAppStoreConnectTests/Fixtures/*.json`

**Interfaces:**
- Produces:
  - `struct ASCCredentials: Sendable { keyID: String; issuerID: String; privateKeyPEM: String }`.
  - `enum ASCJWT { static func token(_ c: ASCCredentials, now: Date, lifetime: TimeInterval = 1200) throws -> String }` — ES256 via `P256.Signing.PrivateKey(pemRepresentation:)`, header `{alg: ES256, kid, typ: JWT}`, claims `iss`, `iat`, `exp`, `aud: appstoreconnect-v1`.
  - In `HangarCore`: `protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`; `struct URLSessionTransport: HTTPTransport`; test helper `StubTransport` (ordered responses, records requests) shared by the server, ASC and client test targets.
  - `struct ASCBuild: Sendable, Equatable { id: String; version: String; processingState: String /* PROCESSING, FAILED, INVALID, VALID */; platform: String? /* IOS, MAC_OS, … */; uploadedDate: Date? }`, `struct ASCBetaGroup { id; name; isInternal: Bool }`.
  - `enum ASCError: Error, Equatable { case notConfigured, http(status: Int, body: String), decoding(String), nonIntegerBuildNumber(version: String, buildID: String) }`.
  - `protocol AppStoreConnectClient: Sendable { func builds(appID: String, version: String?) async throws -> [ASCBuild] /* pages through next links; include=preReleaseVersion for platform */; func xcodeCloudRunNumbers(appID: String) async throws -> [Int] /* ciProducts?filter[app] → ciProducts/{id}/buildRuns, attribute `number`, all pages */; func betaGroups(appID: String) async throws -> [ASCBetaGroup]; func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws; func setWhatToTest(buildID: String, locale: String, text: String) async throws /* POST betaBuildLocalizations, or PATCH when one exists for the locale */; func submitForBetaReview(buildID: String) async throws }`.
  - `final class LiveAppStoreConnectClient: AppStoreConnectClient { init(credentials: ASCCredentials, transport: any HTTPTransport, now: @Sendable () -> Date = Date.init) }` — one JWT cached until 60 s before expiry.
  - `DependencyValues.appStoreConnect: (any AppStoreConnectClient)?` — nil until credentials are configured.

- [ ] **Step 1: Write failing tests**: `ASCJWTTests.producesVerifiableES256Token` (generate a `P256` key in the test, sign, split, verify signature with the public key, decode claims: `aud == "appstoreconnect-v1"`, `exp - iat == 1200`, header `kid`); `LiveClientDecodingTests.buildsFollowsNextLinkAndReadsPlatform` (two fixture pages → 3 builds, platform from included preReleaseVersion), `xcodeCloudRunNumbersAcrossProducts` (fixture with numbers `[250, 251, 252]`), `setsAuthorizationHeader`, `httpErrorCarriesStatusAndBody` (409 → `.http(status: 409, …)`), `setWhatToTestPatchesExistingLocalization`.
- [ ] **Step 2: Run** `swift test --filter HangarAppStoreConnectTests`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(asc): App Store Connect API client with ES256 auth`.

### Task 9: Build-number service

**Files:**
- Create: `Sources/HangarServer/Numbers/{KnownNumberSources,BuildNumberService}.swift`
- Test: `Tests/HangarServerTests/BuildNumberServiceTests.swift`

**Interfaces:**
- Consumes: `BuildRepository`, `AppStoreConnectClient`.
- Produces:
  - `protocol KnownNumberSource: Sendable { var name: String { get }; func highestNumber(for app: App) async throws -> Int? }`. Implementations: `AppStoreConnectBuildsSource` (max of integer `version`s; a non-integer throws `BuildNumberError.nonInteger(source:, value:)`), `XcodeCloudRunsSource` (max of run numbers), `AppcastSource` (Phase 1 stub returning nil, carries the name `appcast` so Phase 2 only fills the body).
  - `enum BuildNumberError: Error, Equatable { case appStoreConnectNotConfigured, sourceUnavailable(source: String, reason: String), nonInteger(source: String, value: String), bumpNotHigher(current: Int, requested: Int) }`.
  - `struct BuildNumberService: Sendable { init(repository: BuildRepository, sources: @Sendable () async throws -> [any KnownNumberSource]); func preview(app: App) async throws -> NumbersReport; func reserve(app: App, buildID: UUID) async throws -> Int; func bump(app: App, to next: Int) async throws -> NumbersReport }`.
    `reserve`: query every source first (any throw → `.sourceUnavailable`), then in **one write transaction** read `highestAssigned`, compute `n = max(remoteMax, highestAssigned ?? 0) + 1`, `reserveNumber`, `setHighestAssigned(n)`. `bump(to:)` sets `highestAssigned = next - 1` and rejects `next <= currentNext`. `preview` computes `next` the same way without writing and fills `lastXcodeCloudRun`, `highestAppStoreConnect`, `inFlight`.

- [ ] **Step 1: Write failing tests** (fake sources with scripted values, in-memory DB): `nextIsMaxOfAllSourcesPlusOne` (ASC 300, XC runs 305, Hangar 299 → next 306); `remoteLowerThanLocalKeepsLocal`; `failedBuildBurnsNumber` (reserve 306, mark the build failed, reserve again → 307); `concurrentReservationsAreDistinctAndIncreasing` (50 `reserve` calls in a task group → 50 distinct consecutive numbers); `nonIntegerVersionIsAnError` (ASC fixture with version `"1.2.3"` → `.nonInteger(source: "app-store-connect", value: "1.2.3")`, and `highestAssigned` unchanged); `unreachableSourceReservesNothing`; `bumpNeverDecreases` (next 306, bump to 306 → `.bumpNotHigher`; bump to 400 → next 400); `previewReportsInFlight`.
- [ ] **Step 2: Run** `swift test --filter BuildNumberServiceTests`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(server): collision-free build number reservation`.

### Task 10: Scheduler

**Files:**
- Create: `Sources/HangarServer/Scheduling/{Scheduler,SchedulerLoop}.swift`, `Sources/HangarServer/Events/EventBus.swift`
- Test: `Tests/HangarServerTests/{SchedulerTests,SchedulerLoopTests}.swift`

**Interfaces:**
- Consumes: `BuildRepository`, `MachineRepository`, `XcodeVersion.matches`.
- Produces:
  - `struct QueuedJob: Sendable { id: UUID; buildID: UUID; createdAt: Date; xcode: String; tools: [String]; pinnedMachineID: UUID? }`; `struct MachineSnapshot: Sendable { id; name; isOnline: Bool; freeSlots: Int; runningJobs: Int; xcodeVersions: [String]; tools: Set<String>; freeDiskGB: Double; performanceCores: Int; onACPower: Bool; canSign: Bool }`.
  - `enum Ineligibility: Equatable, CustomStringConvertible { case offline, busy, xcodeMissing(String) /* "Xcode 27.1 not installed" */, lowDisk(freeGB: Double, minimumGB: Double), toolMissing(String), cannotSign, notPinned }`.
  - `struct Assignment: Equatable { jobID: UUID; machineID: UUID }`; `struct SchedulerPlan: Equatable { assignments: [Assignment]; waiting: [UUID: [String: [Ineligibility]]] /* jobID → machine name → reasons */ }`.
  - `enum Scheduler { static func plan(jobs: [QueuedJob], machines: [MachineSnapshot], minFreeDiskGB: Double) -> SchedulerPlan }` — jobs FIFO by `createdAt`; eligible = online, `freeSlots > 0`, an Xcode matching the request, `freeDiskGB >= minFreeDiskGB`, every tool present, `canSign`; pinned jobs consider only the pinned machine; rank eligible by `(runningJobs == 0 ? 0 : 1, -performanceCores, -freeDiskGB, onACPower ? 0 : 1)`; decrement `freeSlots`/increment `runningJobs` on the chosen snapshot before the next job. `queueNote` text for the UI/CLI: `"<machine>: <reason>; <machine>: <reason>"`.
  - `final class EventBus: Sendable { enum Event: Sendable { case server(ServerEvent), log(jobID: UUID, [LogEntry]) }; func publish(_:); func subscribe() -> AsyncStream<Event> }`.
  - `actor SchedulerLoop { init(builds: BuildRepository, machines: MachineRepository, events: EventBus, config: SchedulerConfig /* minFreeDiskGB = 20, machineTimeout = 120, assignmentTimeout = 60, tickInterval = 2s */, clock: any Clock<Duration>); func tick() async throws; func run() async /* loops tick() every tickInterval; also wake via `func poke()` */ }`.
    `tick`: (1) jobs `assigned` longer than `assignmentTimeout` → `unassign` (back to queued); (2) jobs `assigned`/`running` on a machine whose `lastSeenAt` is older than `machineTimeout` → fail with `"worker lost: <name> stopped reporting"`, refresh build; (3) `Scheduler.plan` → for each assignment `assign` (ignore `false`), for each waiting job `setQueueNote`; publish job/build events on every change.

- [ ] **Step 1: Write failing tests**: `SchedulerTests.prefersIdleThenCoresThenDiskThenAC` (four machines differing in one field each, expected order); `xcodeMissingIsReported` (waiting note contains `"MacBook Pro: Xcode 27.1 not installed"`); `pinnedJobWaitsForItsMachine`; `oneSlotPerMachineByDefault` (two jobs, one machine → one assignment, second waits with `.busy`); `secondJobGoesToSecondMachine`; `lowDiskAndMissingToolAccumulate`; `SchedulerLoopTests.assignsAndPublishes` (in-memory DB, fake clock); `failsRunningJobWhenMachineSilentFor120s` (advance clock 121 s → job `failed`, reason starts with `"worker lost"`, build `failed`; then a new deploy of that app reserves a higher number — reuse `BuildNumberService` with a fake source); `requeuesAssignedJobNotStartedWithin60s`; `assignIsNotDoubled` (two concurrent `tick`s → one assignment).
- [ ] **Step 2: Run** `swift test --filter 'SchedulerTests|SchedulerLoopTests'`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(server): eligibility, ranking and worker-loss handling`.

### Task 11: Source host and deploy creation

**Files:**
- Create: `Sources/HangarServer/Builds/{SourceHost,GitHubSourceHost,BuildService}.swift`
- Test: `Tests/HangarServerTests/{GitHubSourceHostTests,BuildServiceTests}.swift`

**Interfaces:**
- Consumes: `WorkflowFileParser`, `BuildNumberService`, `BuildRepository`, `AppRepository`, `MachineRepository`, `VariableRepository`, `EventBus`, `HTTPTransport`.
- Produces:
  - `protocol SourceHost: Sendable { func resolveCommit(repoURL: String, ref: String, token: String?) async throws -> String; func readFile(repoURL: String, commit: String, path: String, token: String?) async throws -> String? }`; `struct GitHubSourceHost: SourceHost` (parses `owner/repo` from `https://github.com/owner/repo(.git)` and `git@github.com:owner/repo.git`; `GET /repos/{o}/{r}/commits/{ref}` → `sha`; `GET /repos/{o}/{r}/contents/{path}?ref=` with `Accept: application/vnd.github.raw`, 404 → nil).
  - `enum DeployError: Error, Equatable { case appNotFound(String), machineNotFound(String), refNotFound(String), workflowFileMissing(commit: String), workflowFile(WorkflowFileError), workflowNotFound(name: String, available: [String]), approvalNotSupported(postAction: String), numbering(BuildNumberError) }`.
  - `struct BuildService: Sendable { init(apps:, builds:, machines:, variables:, numbers: BuildNumberService, sourceHost: any SourceHost, events: EventBus, scheduler: SchedulerLoop); func deploy(_ request: DeployRequest) async throws -> Build; func cancel(buildID: UUID) async throws -> Build; func workflows(app: App, ref: String) async throws -> (commit: String, file: WorkflowFile) }`.
    `deploy` order: find app → find pinned machine (if any) → resolve commit → read `.hangar.yml` (nil → `workflowFileMissing`) → parse → pick workflow → reject `requiresApproval` (Phase 2) → **only now** `numbers.reserve` → insert `Build` with one `queued` `Job` per action → publish → `scheduler.poke()`. `cancel`: queued jobs → `cancelled`; assigned/running → remembered in `cancelRequested` set that the worker API hands out in `HeartbeatResponse.cancelJobIDs`.

- [ ] **Step 1: Write failing tests**: `GitHubSourceHostTests.parsesHTTPSAndSSHRemotes`, `readFileReturnsNilOn404`, `sendsBearerToken`; `BuildServiceTests.deployCreatesOneJobPerActionSharingTheNumber` (Legilo YAML via fake host → 2 jobs, both builds `buildNumber == 306`); `deployPinsCommitSHA` (`ref: "main"` → `build.commit` is the resolved SHA, `build.ref == "main"`); `invalidWorkflowFileReservesNothing` (YAML with `platform: android` → `.workflowFile(.unknownPlatform("android"))` and `highestAssigned` unchanged) — Review Focus 1; `missingWorkflowFileIsExplicit`; `unknownWorkflowListsAvailable`; `approvalGateRejectedInPhase1`; `cancelQueuedBuild`.
- [ ] **Step 2: Run** `swift test --filter 'GitHubSourceHostTests|BuildServiceTests'`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(server): deploy creation from .hangar.yml at the resolved commit`.

### Task 12: Public REST API and SSE

**Files:**
- Create: `Sources/HangarServer/API/{Router,AppsAPI,VariablesAPI,MachinesAPI,BuildsAPI,NumbersAPI,SSE}.swift`, `Sources/HangarServer/Storage/{LogStore,ArtifactStore,RetentionSweeper}.swift`, `Sources/HangarServer/{ServerConfiguration,HangarServerApp}.swift`, `docs/api.md`
- Test: `Tests/HangarServerTests/{PublicAPITests,LogStoreTests,RetentionSweeperTests}.swift`

**Interfaces:**
- Consumes: everything from Tasks 7–11.
- Produces:
  - `struct ServerConfiguration { host: String; port: Int = 8787; dataDirectory: String; retentionDays: Int = 30; minFreeDiskGB: Double = 20 }`.
  - `struct HangarServerApp { init(configuration:, database:, appStoreConnectFactory:, sourceHost:, clock:) ; func build() -> some ApplicationProtocol }` — Hummingbird router with JSON codable responders; errors map to `{ "code", "message" }` with 400/404/409/502.
  - `LogStore`: `append(jobID:, [LogEntry])` (JSONL at `jobs/<id>/log.jsonl`), `read(jobID:, step: String?, tail: Int?) -> [LogEntry]`; `ArtifactStore`: `write(jobID:, name:, stream:) -> URL`, `list(jobID:) -> [ArtifactInfo { name; sizeBytes }]`, `url(jobID:, name:)`; `RetentionSweeper.sweep(now:)` deletes `jobs/<id>` directories of builds finished more than `retentionDays` ago, keeps DB rows.
  - Routes (all under `/api/v1`, JSON):
    - `GET /apps`, `POST /apps` (201), `GET /apps/{slugOrID}`, `DELETE /apps/{id}`.
    - `GET /apps/{id}/variables` → `[VariableSummary]`; `PUT /apps/{id}/variables/{name}` body `VariableInput` (204); `DELETE`; same under `/variables/{name}` for global scope.
    - `GET /apps/{id}/numbers` → `NumbersReport` (502 with `BuildNumberError` text when a source fails); `PUT /apps/{id}/numbers/next` body `BumpNumberRequest`.
    - `GET /apps/{id}/workflows?ref=` → `{ commit, workflows: WorkflowFile }`.
    - `POST /builds` body `DeployRequest` → 202 `Build`; `GET /builds?app=&limit=50`; `GET /builds/{id}`; `POST /builds/{id}/cancel`.
    - `GET /jobs/{id}`; `GET /jobs/{id}/log?step=&tail=` → `[LogEntry]`; `GET /jobs/{id}/log?follow=1` → SSE (`event: log` with a `LogEntry` JSON array, replays stored entries first, `event: end` when the job is terminal); `GET /jobs/{id}/artifacts`; `GET /jobs/{id}/artifacts/{name}` (file).
    - `GET /machines` (reports included, tokens never); `POST /machines` → 201 `CreateMachineResponse`; `DELETE /machines/{id}`.
    - `GET /events` → SSE of `ServerEvent`s (`event: build|job|machine`, data = the model JSON).
    - `GET /health` → `{ "ok": true, "version" }`.
- [ ] **Step 1: Write failing tests** with `HummingbirdTesting` (`app.test(.router)`): `PublicAPITests.appsCRUD`; `variablesNeverReturnValues` (PUT secret, GET list → no `value` key anywhere in the body); `deployReturns202WithJobs`; `numbersEndpointSurfacesSourceErrors` (fake source throws → 502, message contains the source name); `bumpBelowNextIs409`; `logFollowStreamsAndEnds` (append entries, mark the job succeeded → stream yields `log` then `end`); `unknownAppIs404WithCode`; `LogStoreTests.tailAndStepFilter`; `RetentionSweeperTests.deletesOnlyExpiredJobDirectories`.
- [ ] **Step 2: Run** `swift test --filter 'PublicAPITests|LogStoreTests|RetentionSweeperTests'`. Expected: compile failure.
- [ ] **Step 3: Implement.** SSE via a streamed `ResponseBody` over `AsyncStream`, `Content-Type: text/event-stream`, `Cache-Control: no-cache`, a `: keep-alive` comment every 15 s.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Write `docs/api.md`** (route table with request/response types; note that no endpoint returns a secret value).
- [ ] **Step 6: Commit** `feat(server): REST API, SSE streams, log and artifact storage`.

### Task 13: Worker API

**Files:**
- Create: `Sources/HangarServer/WorkerAPI/{WorkerRoutes,MachineAuth}.swift`
- Modify: `Sources/HangarServer/HangarServerApp.swift` (mount routes)
- Test: `Tests/HangarServerTests/WorkerAPITests.swift`

**Interfaces:**
- Consumes: `MachineRepository.authenticate`, `BuildRepository`, `VariableRepository.resolvedEntries`, `LogStore`, `ArtifactStore`, `EventBus`, `BuildService` (cancel set), `SchedulerLoop.poke`.
- Produces routes under `/api/v1/worker`, each requiring `Authorization: Bearer <machine token>` (401 otherwise), the machine resolved by `MachineAuth` middleware:
  - `POST /heartbeat` body `HeartbeatRequest` → `HeartbeatResponse`; stores the report and `lastSeenAt`, pokes the scheduler.
  - `GET /jobs/next?wait=25` → 200 `JobAssignment` for the oldest job `assigned` to this machine, else 204 after `wait` seconds (long-poll woken by `EventBus`). `environment` = `resolvedEntries(appID)` — the only place secrets leave the server, and only to the machine the job is assigned to.
  - `POST /jobs/{id}/start` (job → `running`, `startedAt`; 409 if not assigned to this machine), `POST /jobs/{id}/steps` body `StepUpdate`, `POST /jobs/{id}/log` body `LogBatch` (append + publish), `POST /jobs/{id}/artifacts/{name}` (raw body streamed to `ArtifactStore`), `POST /jobs/{id}/finish` body `JobResult` (terminal status, outputs, refresh build, publish).

- [ ] **Step 1: Write failing tests**: `WorkerAPITests.rejectsMissingOrWrongToken` (401); `nextReturns204WhenNothingAssigned` (`wait=0`); `nextReturnsAssignmentWithResolvedSecrets` (global + app variables resolved, app wins); `anotherMachineCannotStartTheJob` (409); `lifecycleStartStepsLogFinishUpdatesBuild` (after `finish` succeeded on both jobs, `GET /builds/{id}` is `succeeded`); `heartbeatReturnsCancelRequests`.
- [ ] **Step 2: Run** `swift test --filter WorkerAPITests`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(server): worker API with long-poll job pickup`.

### Task 14: `hangar-server` executable and install script

**Files:**
- Create: `Sources/hangar-server/main.swift`, `scripts/server/install-server.sh`, `scripts/server/app.hangar.server.plist`, `docs/server-setup.md`

**Interfaces:**
- Consumes: `HangarServerApp`, `ServerConfiguration`, `MasterKey`, `GitHubSourceHost`, `LiveAppStoreConnectClient`.
- Produces: `hangar-server run [--host] [--port 8787] [--data-dir] [--retention-days 30] [--min-free-disk-gb 20]`; env overrides `HANGAR_HOST`, `HANGAR_PORT`, `HANGAR_DATA_DIR`. Default host: the first IPv4 printed by `tailscale ip -4` (via `/Applications/Tailscale.app/Contents/MacOS/Tailscale` or `tailscale` on PATH); if unavailable, `127.0.0.1` with a warning. The ASC client factory reads the three reserved global variables on each use, so a key set after start-up works without restart.

- [ ] **Step 1: Implement `main.swift`** (ArgumentParser `AsyncParsableCommand`), start `SchedulerLoop.run()` and `RetentionSweeper` hourly alongside the HTTP server.
- [ ] **Step 2: Write `install-server.sh`**: `swift build -c release`, copies `hangar-server` and `hangar` to `/usr/local/bin`, installs the launchd plist into `~/Library/LaunchAgents` with `KeepAlive`, `RunAtLoad`, stdout/stderr to `~/Library/Logs/Hangar/server.log`, and `launchctl bootstrap gui/$(id -u)`.
- [ ] **Step 3: Verify on `rurzomac-mini` (manual).** Run the script; `curl http://rurzomac-mini:8787/api/v1/health` from `rurzobuk-max`. Expected: `{"ok":true,…}`; `curl http://localhost:8787/...` from outside the tailnet is not reachable.
- [ ] **Step 4: Write `docs/server-setup.md`** (install, data directory, backups of `hangar.sqlite` + `master.key`, how to rotate the master key: not supported in Phase 1, re-enter secrets).
- [ ] **Step 5: Commit** `feat(server): hangar-server executable and launchd install`.

### Task 15: Worker doctor and Xcode locator

**Files:**
- Create: `Sources/HangarWorker/Doctor/{Doctor,XcodeLocator}.swift`, `Sources/HangarWorker/WorkerConfiguration.swift`
- Test: `Tests/HangarWorkerTests/{DoctorTests,XcodeLocatorTests}.swift`

**Interfaces:**
- Consumes: `ProcessRunner`, `MachineReport`, `InstalledXcode`.
- Produces:
  - `struct WorkerConfiguration: Codable { serverURL: URL; token: String; maxConcurrentJobs: Int = 1; dataDirectory: String; static func load(from path: String) throws }`.
  - `struct XcodeLocator { init(runner:, fileManager:); func installed() async throws -> [InstalledXcode] }` — every `/Applications/Xcode*.app` and the `xcode-select -p` path; version/build from `Contents/version.plist` (`CFBundleShortVersionString`, `ProductBuildVersion`).
  - `struct Doctor { init(runner:, locator:, knownTools: [String] = ["git", "brew", "xcodegen", "rclone", "sentry-cli"]); func report(runningJobIDs: [UUID]) async -> MachineReport }` — `sw_vers -productVersion`; `sysctl -n machdep.cpu.brand_string`, `hw.perflevel0.physicalcpu`, `hw.memsize`; free disk via `URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])` on the data directory; power via `pmset -g batt` (`'AC Power'` → true; no battery line → true); tools via `command -v` per name (value = path); `canSignWithoutPrompt`: `security find-identity -v -p codesigning` lists `Apple Development` **and** `codesign --force --sign "<that identity>" <temp copy of /bin/ls>` exits 0 within 10 s (a prompt hangs → timeout → false).
- [ ] **Step 1: Write failing tests** with `RecordingProcessRunner`: `DoctorTests.parsesSysctlAndPower` (scripted outputs → `performanceCores == 10`, `memoryGB == 16`, `onACPower == true`), `batteryDischargingIsNotAC`, `canSignFalseWhenNoIdentity`, `canSignFalseWhenCodesignTimesOut` (scripted runner that never returns, 10 s → `false`, using a test clock), `toolsMapOnlyPresentOnes`; `XcodeLocatorTests.readsVersionPlists` (temp dir with two fake `Xcode*.app/Contents/version.plist`).
- [ ] **Step 2: Run** `swift test --filter 'DoctorTests|XcodeLocatorTests'`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): machine health report`.

### Task 16: Checkout step

**Files:**
- Create: `Sources/HangarWorker/Workspace/WorkspaceLayout.swift`, `Sources/HangarWorker/Steps/Checkout.swift`
- Test: `Tests/HangarWorkerTests/CheckoutTests.swift`

**Interfaces:**
- Consumes: `ProcessRunner`, `JobAssignment`.
- Produces:
  - `struct WorkspaceLayout { init(dataDirectory: String, appSlug: String, jobID: UUID); var repository: String; var derivedData: String; var jobDirectory: String; var secrets: String; var archive(scheme:) -> String /* <job>/archive/<scheme>.xcarchive */; var export: String; var upload: String; var resultBundle: String }`.
  - `struct Checkout { init(runner:, layout:); func run(repoURL: String, commit: String, token: String?, log: @Sendable (String) -> Void) async throws }` — `git clone <url> <repository>` when `<repository>/.git` is absent, else `git -C <repository> fetch --prune origin`; then `git checkout --detach <commit>`, `git submodule update --init --recursive`, `git clean -fdx`. Token passed through `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0="!f() { echo username=x-access-token; echo password=$HANGAR_GITHUB_TOKEN; }; f"` with `HANGAR_GITHUB_TOKEN` in the child env only — never in the URL or `.git/config`. `GIT_TERMINAL_PROMPT=0`. Failure → `CheckoutError.gitFailed(command: String, exitCode: Int32)`.
- [ ] **Step 1: Write failing tests** (real `git`, local bare repo in a temp dir): `CheckoutTests.clonesThenReusesWorkspace` (second run uses `fetch`, not `clone`); `cleansGeneratedFiles` (write `Generated.xcodeproj/x` after first checkout → absent after the second); `checksOutExactCommit` (two commits, check out the older → `git rev-parse HEAD` equals it); `tokenNeverWrittenToConfig` (run with token `ghp_secret`, `#expect(!config.contains("ghp_secret"))`).
- [ ] **Step 2: Run** `swift test --filter CheckoutTests`. Expected: compile failure.
- [ ] **Step 3: Implement** using `LiveProcessRunner`.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): cached per-app checkout`.

### Task 17: Hook runner

**Files:**
- Create: `Sources/HangarWorker/Steps/HookRunner.swift`
- Test: `Tests/HangarWorkerTests/HookRunnerTests.swift`

**Interfaces:**
- Consumes: `ProcessRunner`.
- Produces: `enum Hook: String, CaseIterable { case postClone = "ci_post_clone.sh", preXcodebuild = "ci_pre_xcodebuild.sh", postXcodebuild = "ci_post_xcodebuild.sh" }`; `struct HookRunner { init(runner:); func run(_ hook: Hook, scriptsDirectory: String /* <repository>/<projectDirectory>/ci_scripts */, environment: [String: String], log: @Sendable (String) -> Void) async throws -> HookOutcome }`; `enum HookOutcome: Equatable { case absent, ran }`; `enum HookError: Error { case failed(hook: Hook, exitCode: Int32) }`. Runs with `currentDirectory = scriptsDirectory` (Xcode Cloud parity). If the file is not executable, run `/bin/sh <script>` and log `warning: ci_scripts/<name> is not executable; running it with /bin/sh (Xcode Cloud requires chmod +x)`.
- [ ] **Step 1: Write failing tests** (real scripts in a temp dir): `HookRunnerTests.absentHookIsSkipped`; `runsWithCwdInCiScriptsAndEnv` (script writes `$PWD` and `$CI_BUILD_NUMBER` to a file → both match); `nonExecutableScriptRunsViaShWithWarning` (Review Focus 2; log contains `not executable`); `nonZeroExitFails` (`exit 3` → `.failed(hook: .postClone, exitCode: 3)`); `outputLinesAreForwardedInOrder`.
- [ ] **Step 2: Run** `swift test --filter HookRunnerTests`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): ci_scripts hooks with Xcode Cloud semantics`.

### Task 18: Archive and export steps

**Files:**
- Create: `Sources/HangarWorker/Steps/{ArchiveStep,ExportStep}.swift`
- Test: `Tests/HangarWorkerTests/{ArchiveStepTests,ExportStepTests}.swift`

**Interfaces:**
- Consumes: `ProcessRunner`, `WorkspaceLayout`, `Workflow`, `ArchiveAction`, `XcodeVersion.best`.
- Produces:
  - `struct ASCKeyArguments: Sendable { keyPath: String; keyID: String; issuerID: String; var xcodebuildArguments: [String] /* -authenticationKeyPath … -authenticationKeyID … -authenticationKeyIssuerID … */; init?(environment: [String: String]) /* from HANGAR_ASC_KEY_PATH/_ID/_ISSUER_ID */ }`.
  - `enum SigningMode: Sendable { case cloudManaged; case temporaryKeychain(p12Path: String, password: String) }` — Phase 1 implements `.cloudManaged`; `.temporaryKeychain` exists so Phase 2 (spike Outcome B) extends `ExportStep` without changing its signature; passing it in Phase 1 throws `ExportError.unsupportedSigningMode`.
  - `struct ArchiveStep { init(runner:); static func command(workflow: Workflow, action: ArchiveAction, repository: String, layout: WorkspaceLayout, developerDir: String, key: ASCKeyArguments, environment: [String: String]) -> ProcessCommand; func run(...) async throws }`. Arguments: `xcodebuild archive -project|-workspace <repository>/<path> -scheme <scheme> -destination <platform.genericDestination> -archivePath <layout.archive(scheme)> -derivedDataPath <layout.derivedData> -resultBundlePath <layout.resultBundle> -allowProvisioningUpdates -allowProvisioningDeviceRegistration -skipMacroValidation -skipPackagePluginValidation` + key arguments, `DEVELOPER_DIR` in env. Non-zero exit → `ArchiveError.xcodebuildFailed(exitCode:)`.
  - `struct ExportOptions { static func plist(method: ExportMethod, destination: String /* "export" | "upload" */, teamID: String?) -> Data }` — `method` = `app-store-connect` | `developer-id`, `signingStyle = automatic`, `manageAppVersionAndBuildNumber = false`, `uploadSymbols = true`, `destination`, `teamID` when given.
  - `struct ExportStep { init(runner:); func run(archivePath: String, method: ExportMethod, destination: String, exportPath: String, teamID: String?, developerDir: String, key: ASCKeyArguments, signing: SigningMode, environment:, log:) async throws -> ExportResult }`; `struct ExportResult { exportedArtifactPath: String? /* first .ipa, .pkg or .app under exportPath; nil for destination upload */ }`. Command: `xcodebuild -exportArchive -archivePath … -exportOptionsPlist <exportPath>/ExportOptions.plist -exportPath … -allowProvisioningUpdates` + key arguments.
- [ ] **Step 1: Write failing tests**: `ArchiveStepTests.legiloMobileCommand` (exact argument list for `LegiloMobile`/`ios`, project at repo root; `-destination generic/platform=iOS`; `DEVELOPER_DIR` set), `workspaceInSubdirectory`; `ExportStepTests.plistForAppStoreUpload` (decode the plist, `manageAppVersionAndBuildNumber == false`, `destination == "upload"`, `method == "app-store-connect"`), `plistForDeveloperIDExport`, `findsExportedPkgForMac` (temp export dir with `Legilo.pkg`), `temporaryKeychainUnsupportedInPhase1`.
- [ ] **Step 2: Run** `swift test --filter 'ArchiveStepTests|ExportStepTests'`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): xcodebuild archive and export steps`.

### Task 19: Build-number stamper

**Files:**
- Create: `Sources/HangarWorker/Steps/BuildNumberStamper.swift`
- Test: `Tests/HangarWorkerTests/BuildNumberStamperTests.swift`

**Interfaces:**
- Produces: `struct BuildNumberStamper { init(fileManager: FileManager = .default); func stamp(archivePath: String, buildNumber: Int, log: @Sendable (String) -> Void) throws -> [StampedBundle] }`; `struct StampedBundle: Equatable { relativePath: String; previous: String?; }`; `enum StampError: Error, Equatable { case noApplication(archivePath: String), unreadablePlist(String), verificationFailed(bundle: String, found: String?) }`.
  Rules: the app under `Products/Applications/*.app`; its `Info.plist` (`Contents/Info.plist` on macOS, `Info.plist` otherwise); then recursively inside each stamped bundle: `PlugIns/*.appex`, `Extensions/*.appex`, `Contents/PlugIns/*.appex`, `Contents/Extensions/*.appex`, `Watch/*.app`, `AppClips/*.app`. **Not** stamped: `Contents/Library/LoginItems/*.app`, `Contents/Library/LaunchServices/*`, `Frameworks/*`, `XPCServices/*`, `Contents/XPCServices/*`, `Contents/Frameworks/*`. Set `CFBundleVersion` = `"\(buildNumber)"` preserving the plist format (binary stays binary); also set the archive's own `Info.plist` → `ApplicationProperties.CFBundleVersion`. After writing, re-read every stamped plist and compare; any mismatch → `verificationFailed`. Log one line per bundle: `stamp: <relativePath> CFBundleVersion <previous> → <new>`.
- [ ] **Step 1: Write failing tests** on synthesized archive trees in a temp dir (plists written with `PropertyListSerialization`): `stampsLegiloMacArchive` (app with `Contents/PlugIns/LegiloShare.appex`, `Contents/Extensions/LegiloModelDownloader.appex`, `Contents/Library/LoginItems/LegiloCapture.app` → first three stamped to `"311"`, LoginItem keeps `"1"`); `stampsIOSArchiveWithWatchAndClip`; `helperAndXPCServicesUntouched` (BatFi-shaped: `Contents/Library/LaunchServices/helper` keeps `49`); `hardCodedPlistValueIsReplaced` (Hourly Beep-shaped `"3"` → `"311"`); `binaryPlistStaysBinary`; `archiveInfoPlistUpdated`; `missingAppThrows`.
- [ ] **Step 2: Run** `swift test --filter BuildNumberStamperTests`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): stamp CFBundleVersion after archive`.

### Task 20: Post-action protocol and the TestFlight action

**Files:**
- Create: `Sources/HangarWorker/PostActions/{PostActionModule,TestFlightAction}.swift`
- Test: `Tests/HangarWorkerTests/TestFlightActionTests.swift`

**Interfaces:**
- Consumes: `PostActionSettings`, `TestFlightSettings`, `ExportStep`, `AppStoreConnectClient`, `ProcessRunner`, `Clock`.
- Produces:
  - `struct PostActionContext: Sendable { app: App; action: ArchiveAction; buildNumber: Int; archivePath: String; exportedArtifactPath: String?; repository: String; projectDirectory: String; environment: [String: String]; layout: WorkspaceLayout; developerDir: String; key: ASCKeyArguments?; appStoreConnect: (any AppStoreConnectClient)?; runner: any ProcessRunner; clock: any Clock<Duration>; log: @Sendable (String) -> Void }`.
  - `struct PostActionOutput: Sendable { summary: String; outputs: [String: String] }`.
  - `protocol PostActionModule: Sendable { associatedtype Settings: PostActionSettings; init(settings: Settings); func run(_ context: PostActionContext) async throws -> PostActionOutput }`.
  - `enum PostActionRegistry { static func make(_ spec: PostActionSpec) throws -> any AnyPostAction }` with `protocol AnyPostAction { var name: String { get }; func run(_: PostActionContext) async throws -> PostActionOutput }` — Phase 1 registers `TestFlightAction`; Phase 2 adds `script`, Phase 4 `upload`/`sparkle-appcast`. This registry, `PostActionContext` and `PostActionSettings` are the contributor-facing module interface the Phase 4 guide documents.
  - `enum TestFlightError: Error, Equatable { case appStoreConnectNotConfigured, processingFailed(state: String), processingTimedOut(minutes: Int), unknownGroup(name: String, available: [String]) }`.
  - `struct TestFlightAction: PostActionModule`: (1) upload: `ExportStep.run(method: .appStoreConnect, destination: "upload", exportPath: layout.upload, …)`; (2) if `waitForProcessing`: poll `builds(appID:, version: "\(buildNumber)")` filtered by `platform == action.platform.appStoreConnectPlatform` every 30 s until `VALID` (→ continue), `FAILED`/`INVALID` (→ `TestFlightError.processingFailed(state:)`), or `processingTimeoutMinutes` elapses (→ `.processingTimedOut`); (3) groups: resolve names via `betaGroups`, unknown → `.unknownGroup(name:, available:)`, `addBuild` each; (4) `whatToTest`: for each `<repository>/<projectDirectory>/TestFlight/WhatToTest.<locale>.txt` call `setWhatToTest(locale:)`; none → log `no TestFlight/WhatToTest.*.txt; skipping`; (5) `submitForExternalReview` → `submitForBetaReview`. Steps 2–5 require `appStoreConnect` (nil → `.appStoreConnectNotConfigured`). Outputs: `testflight.buildID`, `testflight.processingState`. Summary: `Build 311 (iOS) is VALID in TestFlight; groups: Internal`.
- [ ] **Step 1: Write failing tests** with a fake `AppStoreConnectClient` (scripted sequence of `processingState`s), `RecordingProcessRunner`, test clock: `uploadsThenWaitsUntilValid` (states `PROCESSING, PROCESSING, VALID` → 3 polls, clock advanced 60 s, upload command contains `-exportOptionsPlist` and the plist has `destination = upload`); `failedProcessingThrows`; `timesOutAfterConfiguredMinutes`; `filtersByPlatformAndVersion` (a `MAC_OS` build 311 and an `IOS` build 311 → iOS action picks the IOS one); `unknownGroupListsAvailable`; `readsWhatToTestPerLocale` (temp repo with `TestFlight/WhatToTest.en-US.txt` and `.pl.txt` → two `setWhatToTest` calls with the file contents); `noWaitFinishesAfterUpload`; `registryBuildsTestFlightFromSpec`.
- [ ] **Step 2: Run** `swift test --filter TestFlightActionTests`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): post-action module protocol and TestFlight action`.

### Task 21: Job runner, secrets lifecycle and artifact upload

**Files:**
- Create: `Sources/HangarWorker/{JobRunner,JobLog}.swift`, `Sources/HangarWorker/Workspace/SecretsMaterializer.swift`, `Sources/HangarWorker/Steps/ArtifactCollector.swift`, `Sources/HangarWorker/Connection/ServerConnection.swift`
- Test: `Tests/HangarWorkerTests/{JobRunnerTests,SecretsMaterializerTests,ArtifactCollectorTests}.swift`

**Interfaces:**
- Consumes: Tasks 5, 6, 15–20.
- Produces:
  - `protocol ServerConnection: Sendable { func heartbeat(_: HeartbeatRequest) async throws -> HeartbeatResponse; func nextJob(wait: Int) async throws -> JobAssignment?; func start(jobID:) async throws; func step(jobID:, _: StepUpdate) async throws; func log(jobID:, _: LogBatch) async throws; func uploadArtifact(jobID:, name:, fileURL:) async throws; func finish(jobID:, _: JobResult) async throws }`; `struct HTTPServerConnection: ServerConnection` (URLSession, bearer token); test `FakeServerConnection` recording everything.
  - `struct SecretsMaterializer { init(directory: String); func write(_ files: [(path: String, contents: String)]) throws /* dir 0700, files 0600 */; func wipe() throws /* overwrite each file with zeros of its length, then remove the directory */ }`.
  - `final class JobLog: Sendable { init(jobID:, masker: SecretMasker, connection:, clock:); func line(step: String, _ text: String); func flush() async /* batches of ≤200 entries or every 1 s */ }`.
  - `struct ArtifactCollector { func collect(layout:, scheme:, log:) async throws -> [(name: String, url: URL)] }` — `<scheme>.xcarchive/dSYMs` zipped as `<scheme>-dSYMs.zip` (`ditto -c -k --keepParent`), `result.xcresult` as `<scheme>.xcresult.zip`, the exported `.ipa`/`.pkg`/`.app` (apps zipped), `ExportOptions.plist`, `DistributionSummary.plist` when present.
  - `struct JobRunner { init(connection:, runner:, locator: XcodeLocator, dataDirectory:, clock:); func run(_ assignment: JobAssignment, cancelled: @Sendable () -> Bool) async -> JobResult }`. Order and step names: `checkout` → `post-clone` → `pre-xcodebuild` → `archive` → `stamp` → `export` → `post-xcodebuild` → `post-action:<name>` for each spec in order → `upload-artifacts` → `cleanup`. Before `checkout`: pick Xcode (`XcodeVersion.best`, none → fail `"Xcode <x> not installed"`), read `ASCKeyArguments(environment:)` (nil → fail `"App Store Connect key not configured; run hangar settings asc-key"`), build `CIEnvironment.make` + `merge`, `SecretsMaterializer.write`. `ci_post_xcodebuild.sh` runs with `postXcodebuildAdditions` and also runs when archive/export failed (`CI_XCODEBUILD_EXIT_CODE` non-zero, as Xcode Cloud does), after which the job fails. Each step reports `running`/`succeeded`/`failed`/`skipped` via `connection.step`; the first failure skips later steps except `post-xcodebuild` (rule above), `upload-artifacts` (always attempted: logs and the `.xcresult` are what explains a failure) and `cleanup` (always: `SecretsMaterializer.wipe`, `git clean -fdx` in the repository, remove `jobDirectory`). Cancellation checked between steps and propagated to the running process. The returned `JobResult.outputs` merges post-action outputs.
- [ ] **Step 1: Write failing tests**: `SecretsMaterializerTests.filesAre0600AndWipedToZeroThenRemoved`; `ArtifactCollectorTests.namesAndZips` (temp archive tree, real `ditto`); `JobRunnerTests.happyPathStepOrder` (scripted runner, fake connection → step names reported in the exact order above with `post-action:testflight`, and `finish` is `succeeded`); `archiveFailureStillRunsPostXcodebuildAndUploads` (scripted `xcodebuild archive` exit 65 → steps `stamp`/`export` skipped, `post-xcodebuild` ran with `CI_XCODEBUILD_EXIT_CODE=65`, `upload-artifacts` and `cleanup` ran, result `failed`); `secretsWipedEvenOnFailure`; `logLinesAreMasked` (a scripted line echoing the ASC key path contents → `[masked]` in the batch sent); `missingXcodeFailsBeforeCheckout`; `missingASCKeyFailsBeforeCheckout`; `cancellationBetweenStepsYieldsCancelled`.
- [ ] **Step 2: Run** `swift test --filter 'JobRunnerTests|SecretsMaterializerTests|ArtifactCollectorTests'`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): job runner with secrets lifecycle and artifact upload`.

### Task 22: Worker loop, `hangar-worker` executable and bootstrap

**Files:**
- Create: `Sources/HangarWorker/WorkerLoop.swift`, `Sources/hangar-worker/main.swift`, `scripts/worker/{Brewfile,install-worker.sh,app.hangar.worker.plist}`, `docs/worker-setup.md`
- Test: `Tests/HangarWorkerTests/WorkerLoopTests.swift`

**Interfaces:**
- Consumes: `JobRunner`, `Doctor`, `ServerConnection`, `WorkerConfiguration`.
- Produces:
  - `actor WorkerLoop { init(configuration:, connection:, doctor:, jobRunner:, clock:); func run() async }` — two concurrent loops: heartbeat every 30 s (report + running job ids; `cancelJobIDs` flips the matching job's cancel flag) and a pull loop that long-polls `nextJob(wait: 25)` while running jobs `< maxConcurrentJobs`, calls `start`, runs the job, `finish`. Transport errors: log, back off 5 s → 60 s exponential, keep going.
  - `hangar-worker run [--config <path>]` (default `~/Library/Application Support/Hangar/worker/config.json`), `hangar-worker doctor` (prints the `MachineReport` as JSON, including `canSignWithoutPrompt`), `hangar-worker setup --server <url> --token <token>` (writes the config, 0600).
- [ ] **Step 1: Write failing tests**: `WorkerLoopTests.heartbeatsAndPicksUpOneJobAtATime` (fake connection hands out two assignments, `maxConcurrentJobs = 1` → second `nextJob` call happens only after the first `finish`); `backsOffOnTransportErrors`; `cancelFlagReachesRunningJob`.
- [ ] **Step 2: Run** `swift test --filter WorkerLoopTests`. Expected: compile failure.
- [ ] **Step 3: Implement** loop and `main.swift`.
- [ ] **Step 4: Write bootstrap files.** `Brewfile`: `xcodegen`, `rclone`. `install-worker.sh`: builds release, copies `hangar-worker` to `/usr/local/bin`, runs `hangar-worker setup`, installs the plist into `~/Library/LaunchAgents` (`KeepAlive`, `RunAtLoad`, `LimitLoadToSessionType: Aqua`, logs to `~/Library/Logs/Hangar/worker.log`), `launchctl bootstrap gui/$(id -u)`. `docs/worker-setup.md` checklist: create the `hangar` user (admin not required), enable fast user switching and log that user in, `sudo pmset -a sleep 0 disksleep 0`, install Xcode 27.2 and run `xcodebuild -runFirstLaunch` + `sudo xcodebuild -license accept`, `xcodebuild -downloadPlatform iOS`, Homebrew + `brew bundle`, create the machine with `hangar machines add <name>` on any tailnet Mac and paste the token into `install-worker.sh`, run `hangar-worker doctor` and confirm `canSignWithoutPrompt: true` (if false: open Keychain Access as `hangar`, find the Apple Development key, Access Control → allow `codesign`), and the note that the first archive with the ASC key creates the Apple Development identity.
- [ ] **Step 5: Verify on `rurzomac-mini` (manual).** As `hangar`: run `install-worker.sh`; `hangar machines list` on the server shows the machine online with Xcode 27.2, `canSignWithoutPrompt: true`, `tools` containing `xcodegen` and `brew`. Repeat on `rurzobuk-max`.
- [ ] **Step 6: Commit** `feat(worker): daemon loop, executable and bootstrap scripts`.

### Task 23: `HangarClient` and the `hangar` CLI

**Files:**
- Create: `Sources/HangarClient/{HangarAPI,SSEReader}.swift`, `Sources/hangar/Hangar.swift`, `Sources/hangar/Commands/{Apps,Variables,Settings,Machines,Deploy,Status,Logs,Builds,Numbers,Cancel,Workflows}.swift`, `Sources/hangar/Output/Table.swift`
- Test: `Tests/HangarClientTests/{HangarAPITests,SSEReaderTests}.swift`, `Tests/hangarTests/{CommandParsingTests,OutputTests}.swift`

**Interfaces:**
- Consumes: the DTOs of Task 4, the routes of Task 12.
- Produces:
  - `struct HangarAPI: Sendable { init(baseURL: URL, transport: any HTTPTransport); ... }` — one method per public route, typed; errors decode `APIError` and throw `HangarAPIError.server(APIError, status:)` or `.transport(Error)`. `func followLog(jobID:) -> AsyncThrowingStream<LogEntry, Error>` and `func events() -> AsyncThrowingStream<ServerEvent, Error>` built on `SSEReader` (`URLSession.bytes`, parses `event:`/`data:` frames, ignores comments).
  - CLI (`hangar`, `AsyncParsableCommand`): global `--server <url>` (default `HANGAR_SERVER` env, else `http://localhost:8787`) and `--json`.
    - `hangar apps list|add <name> --repo <url> --asc-app-id <id> [--icon <url>]|remove <app>`
    - `hangar var set <NAME> [--app <app>] [--secret] [--as-file] (--value <v> | --value-file <path> | stdin)`, `hangar var list [--app]`, `hangar var remove <NAME> [--app]`
    - `hangar settings asc-key --key-id <id> --issuer-id <id> --p8 <path>` → sets the three reserved globals; `hangar settings github-token` (stdin) → `HANGAR_GITHUB_TOKEN`
    - `hangar machines list|add <name> [--max-jobs 1]|remove <machine>` — `add` prints the token once with `Save this token now; it is not shown again.`
    - `hangar deploy <app> <workflow> [--ref main] [--machine <name>] [--watch] [--no-wait]` → prints build id, number, jobs; `--watch` (default on in a TTY) follows the build via `/events` until terminal, printing step transitions and, on failure, the last 40 log lines of the failed step; exit 0 on success, 1 on failure, 2 on cancel.
    - `hangar status [<build-id>]` — without id: queued/running builds with machine, current step and `queueNote`; with id: the build's jobs and steps with timings.
    - `hangar logs <job-id|build-id> [--follow] [--step <name>] [--tail <n>]` — rendered `HH:MM:SS [step] line`; a build id streams all its jobs prefixed by scheme.
    - `hangar builds [--app <app>] [--limit 20]`, `hangar numbers <app> [--bump <n>]`, `hangar cancel <build-id>`, `hangar workflows <app> [--ref main]`.
- [ ] **Step 1: Write failing tests**: `HangarAPITests.decodesAPIErrorIntoTypedError`, `deployPostsRequest`; `SSEReaderTests.parsesMultiLineDataAndIgnoresComments`; `CommandParsingTests.deployDefaultsRefToMain`, `varSetReadsStdinWhenNoValue`, `settingsAscKeyProducesThreeVariables` (plain `HANGAR_ASC_KEY_ID`/`ISSUER_ID`, secret+as-file `HANGAR_ASC_KEY_PATH` with the file contents as value); `OutputTests.statusTableShowsQueueNote`, `logsRenderTimeAndStep`, `jsonFlagEmitsRawDTO`.
- [ ] **Step 2: Run** `swift test --filter 'HangarAPITests|SSEReaderTests|CommandParsingTests|OutputTests'`. Expected: compile failure.
- [ ] **Step 3: Implement.** Commands take a `HangarAPI` through a dependency so tests inject a stub transport.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(cli): hangar command-line client`.

### Task 24: Claude Code plugin with deploy and status skills

**Files:**
- Create: `plugins/hangar/.claude-plugin/plugin.json`, `plugins/hangar/skills/hangar-deploy/SKILL.md`, `plugins/hangar/skills/hangar-status/SKILL.md`, `plugins/hangar/README.md`

**Interfaces:**
- Consumes: the `hangar` CLI only. A skill may not do anything the CLI cannot.
- Produces: plugin `hangar` (name, description, version `0.1.0`), skills:
  - `hangar-deploy` — description: "Use when asked to build, deploy or ship an app to TestFlight with Hangar (not Xcode Cloud)". Body: resolve app and workflow with `hangar apps list --json` and `hangar workflows <app> --json` (ask when ambiguous), show `hangar numbers <app>` and warn when `inFlight` is true or `lastXcodeCloudRun >= next`, run `hangar deploy <app> <workflow> --ref <ref> [--machine] --json --no-wait`, then `hangar status <id> --json` every 30 s until terminal, report number, platforms and the TestFlight summary from job outputs; on failure run `hangar logs <job> --tail 60` for the failed job and quote the cause. Never starts Xcode Cloud builds; if the user says "Xcode Cloud", stop and say so.
  - `hangar-status` — description: "Use when asked what Hangar is building, why a build is queued or failed, or for build logs". Body: `hangar status`, `hangar status <id>`, `hangar logs <id> --step <failed step> --tail 80`, `hangar machines list` for queue notes; summarise, quote log excerpts, no speculation beyond the log.
  - Both say: requires `hangar` on PATH and `HANGAR_SERVER` set (default `http://rurzomac-mini:8787` in the plugin README as the author's setup, not in the skill).
- [ ] **Step 1: Write the three files.**
- [ ] **Step 2: Verify (manual):** `claude --plugin-dir plugins/hangar` (or the marketplace-less local install documented in the README), ask "what is Hangar building?", confirm the skill fires and runs `hangar status`.
- [ ] **Step 3: Commit** `feat(skills): Claude Code plugin with deploy and status skills`.

### Task 25: End-to-end proof on Legilo

All steps are manual, on the author's tailnet; record the outcome in `docs/superpowers/plans/2026-11-04-hangar-phase-1.md` under a "Phase 1 verification" heading at the end (date, build number, ASC build ids).

**Files:**
- Modify: this plan (verification record), `README.md` (quick start: server, worker, app, deploy).
- In the Legilo repo (author's commit, Hangar never edits app repos): `.hangar.yml` with the Task 3 example (`tools: [brew]`, `groups` matching an existing internal group or omitted).

- [ ] **Step 1: Configure.** `hangar settings asc-key …` (team key, Admin role), `hangar settings github-token`, `hangar apps add Legilo --repo https://github.com/rurza/Legilo --asc-app-id <id>`. `hangar numbers legilo` → expected: `highestAppStoreConnect` and `lastXcodeCloudRun` populated, `next` greater than both, `inFlight: false`.
- [ ] **Step 2: Dry run one platform on one machine.** Temporarily use a `.hangar.yml` with only the macOS action (branch `hangar-smoke`), `hangar deploy legilo testflight --ref hangar-smoke --machine rurzomac-mini`. Expected: steps in order, `ci_post_clone.sh` installs xcodegen and generates the project with `CURRENT_PROJECT_VERSION` = the Hangar number, stamp log shows `Legilo.app`, `LegiloShare.appex`, `LegiloWeb.appex`, `LegiloModelDownloader.appex` set and `LegiloCapture.app` untouched, export produces `Legilo.pkg`, the TestFlight action reports `VALID`, and App Store Connect shows build N for macOS. `codesign -dvv` on the exported product shows the stamped `CFBundleVersion` (`defaults read <app>/Contents/Info.plist CFBundleVersion`).
- [ ] **Step 3: Full workflow, both platforms.** `hangar deploy legilo testflight --ref main`. Expected: two jobs with the same number N+1; with both machines online they run on different Macs (scheduler log/queue note confirms), ASC shows build N+1 for both iOS and macOS, `hangar numbers legilo` → `highestHangar == N+1`.
- [ ] **Step 4: Numbering across both systems.** Start an Xcode Cloud run of Legilo by the author's usual means after raising its next build number above N+1 as `hangar numbers` advises; then `hangar numbers legilo` → `lastXcodeCloudRun` reflects it and `next` is above it. Deploy once more → number above the Xcode Cloud run.
- [ ] **Step 5: Failure path.** Deploy a branch with a deliberate compile error. Expected: job `failed` at `archive`, `post-xcodebuild` ran with `CI_XCODEBUILD_EXIT_CODE=65` (Legilo has none, so it reports `skipped`), `.xcresult.zip` present in `hangar logs`/artifacts, `hangar numbers` shows the burned number, `hangar status <id>` names the failed step, and `grep -c "<any secret value>" ~/Library/Logs/Hangar/worker.log` on the worker is 0 and `jobs/<id>/secrets` no longer exists.
- [ ] **Step 6: Skill path.** In Claude Code with the plugin: "build Legilo to TestFlight with Hangar". Expected: the deploy skill runs and reports the number and TestFlight state.
- [ ] **Step 7: Commit** `docs: Phase 1 verification on Legilo`.

---

## How the spike (Task 2) branches the plan

Phase 1's TestFlight path never needs a Developer ID certificate, so Task 2 blocks nothing here; its result selects the shape of the Phase 2 plan:

- **Outcome A — the API key can export Developer ID with cloud-managed signing.** Phase 2's export step is `ExportStep.run(method: .developerID, destination: "export", signing: .cloudManaged, …)`; no new secrets; the `.hangar.yml` schema gains nothing. `SigningMode.temporaryKeychain` stays in the code as the documented alternative for users whose team cannot use cloud-managed Developer ID.
- **Outcome B — it cannot.** Phase 2 adds reserved secrets `HANGAR_DEVELOPER_ID_P12_PATH` (secret, as-file) and `HANGAR_DEVELOPER_ID_P12_PASSWORD`, a worker `TemporaryKeychain` (create with a random password → import `.p12` → add to the search list → `set-key-partition-list` → delete in `cleanup`), and `ExportStep` gains the `.temporaryKeychain` body behind the signature Task 18 already fixed (`signingStyle = manual` with the certificate name in `ExportOptions`). `hangar settings developer-id --p12 <path>` sets both secrets. Nothing in Phase 1 changes.

Either way, Phase 1 ships `SigningMode`, `ASCKeyArguments`, the as-file secret model and `ExportStep` so that Phase 2 is additive.

## Decisions the spec left open, as made here

- **Worker transport:** long-poll (`GET /worker/jobs/next?wait=25`) plus a 30 s heartbeat; assignment happens in the server's scheduler tick so ranking is honoured, and the claim is one conditional `UPDATE`.
- **Post-actions run per archive action**, on the worker that built it (spec step 9 is inside "for each action"), so a two-platform run uploads twice, once per platform, under one number.
- **The server reads `.hangar.yml` through the GitHub API** at the resolved commit (needed before scheduling for the Xcode version and tools); GitHub is the only source host in Phase 1.
- **The TestFlight upload is a second `-exportArchive` with `destination = upload`** from the same archive, after the retained `destination = export` artifact; it costs one extra signing pass and avoids `altool`, whose future is uncertain.
- **`CI_XCODE_CLOUD` is not set**; `CI_HANGAR=TRUE` is, so scripts can tell the two apart while every other `CI_*` value matches.
- **Secrets at rest:** AES-GCM with a 32-byte master key file (0600) in the server data directory; moving it to the Keychain is a later change behind `MasterKey`.
- **Retention:** 30 days for logs and artifacts; DB rows are kept. **Workspace cache:** one checkout and one DerivedData per app per worker, cleaned with `git clean -fdx` before and after each job.
- **"Performance class"** for ranking is the count of performance cores (`hw.perflevel0.physicalcpu`), the simplest number that orders the author's two Macs correctly and any future one sensibly.
- **Log format:** JSONL `{t, step, line}` per job; the CLI renders `HH:MM:SS [step] line`.

## Phase 1 verification

Fill-in checklist for the author. Everything here runs on the author's Macs and tailnet and touches App Store Connect, GitHub or the Legilo repo, so none of it is done by Hangar's tooling. Nothing is marked done: tick a box only after recording the outcome in its fields. Run on a Mac with `export HANGAR_SERVER=http://rurzomac-mini:8787` unless a step says otherwise.

### Earlier manual steps

- [ ] **Task 2, Step 2: archive for the spike** (on `rurzomac-mini`, as `hangar`).
  - Run: clone Herald, then `CI_PRIMARY_REPOSITORY_PATH=<clone> ci_scripts/ci_post_clone.sh`, then `xcodebuild archive -scheme <Herald scheme> -destination 'generic/platform=macOS' -archivePath /tmp/spike/Herald.xcarchive -allowProvisioningUpdates -authenticationKeyPath <AuthKey.p8> -authenticationKeyID <ID> -authenticationKeyIssuerID <ID>`, then `security find-identity -v -p codesigning`.
  - Expect: `/tmp/spike/Herald.xcarchive` exists; note whether an Apple Development identity now exists in the `hangar` login keychain.
  - Date: ______  Identity created: ______  Result: ______
- [ ] **Task 2, Step 3: run the spike** (Run A with no Developer ID certificate; Run B only if A fails, after opening Xcode once as `hangar` signed in).
  - Run: `scripts/spike/developer-id-cloud-signing.sh --archive /tmp/spike/Herald.xcarchive --team <TEAMID> --key-id <ID> --issuer-id <ID> --key <AuthKey.p8> --out /tmp/spike/out`
  - Expect: `RESULT: PASS` or `RESULT: FAIL` plus the last 40 lines of xcodebuild output.
  - Record in `docs/spikes/2026-11-developer-id-cloud-signing.md`: date, macOS and Xcode build, exact command, RESULT, first error line (if any), keychain identities, conclusion (Outcome A or Outcome B).
  - Run A date: ______  RESULT: ______  Run B date: ______  RESULT: ______  Outcome: ______
- [ ] **Task 14, Step 3: server install** (on `rurzomac-mini`).
  - Run: `scripts/server/install-server.sh`, then from `rurzobuk-max` `curl http://rurzomac-mini:8787/api/v1/health`, and from outside the tailnet `curl http://<server public address>:8787/api/v1/health`.
  - Expect: `{"ok":true,...}` on the tailnet; unreachable from outside.
  - Date: ______  Result: ______
- [ ] **Task 22, Step 5: worker install** (on `rurzomac-mini`, then on `rurzobuk-max`).
  - Run, on a Mac that has the CLI (the server Mac, where `install-server.sh` installs `hangar`; elsewhere `swift build -c release --product hangar` and copy the binary) with `HANGAR_SERVER` set: `hangar machines add <name>`, and copy the token. Then on the build Mac as `hangar`: `read -rs HANGAR_WORKER_TOKEN; export HANGAR_WORKER_TOKEN`; `scripts/worker/install-worker.sh --server http://rurzomac-mini:8787`; `hangar-worker doctor`. Then `hangar machines list` on the Mac with the CLI.
  - Expect: machine online with Xcode 27.2, `canSignWithoutPrompt: true`, `tools` containing `xcodegen` and `brew`.
  - rurzomac-mini date: ______  Result: ______  rurzobuk-max date: ______  Result: ______
- [ ] **Task 24, Step 2: plugin** (Claude Code).
  - Run: `claude --plugin-dir plugins/hangar`, ask "what is Hangar building?".
  - Expect: the `hangar-status` skill fires and runs `hangar status`.
  - Date: ______  Result: ______

### Task 25: end-to-end proof on Legilo

`.hangar.yml` for Legilo (from `docs/hangar-yml.md`). The author commits it in the Legilo repo, on a `hangar-smoke` branch for Step 2 (with only the macOS action) and on `main` for Step 3 (both actions). Hangar never edits app repos.

```yaml
version: 1
workflows:
  testflight:
    project: Legilo.xcodeproj        # or `workspace:`; relative to the repo root
    xcode: "27.2"                    # prefix match against installed Xcodes
    team: YL78V8PY6H                 # optional; adjust to Legilo's actual value
    tools: [brew]                    # optional; names the worker must report
    actions:
      - { scheme: Legilo, platform: macos, export: app-store-connect }
      - { scheme: LegiloMobile, platform: ios, export: app-store-connect }   # adjust scheme to Legilo's actual value
    post-actions:
      - testflight:
          groups: [Internal]         # adjust to Legilo's actual value
```

Adjust `team`, the `LegiloMobile` scheme and the `Internal` group to Legilo's actual values. The group must match an existing internal beta group in App Store Connect, or be omitted.

- [ ] **Step 1: Configure.**
  - Run: `hangar settings asc-key --key-id <ID> --issuer-id <ID> --p8 AuthKey_<ID>.p8` (team key, Admin role); `hangar settings github-token` (token on stdin); `hangar apps add Legilo --repo https://github.com/rurza/Legilo --asc-app-id <id>`; `hangar numbers legilo`.
  - Expect: `highestAppStoreConnect` and `lastXcodeCloudRun` populated, `next` greater than both, `inFlight: false`.
  - Date: ______  highestAppStoreConnect: ______  lastXcodeCloudRun: ______  next (N+1 base): ______  Result: ______
- [ ] **Step 2: Dry run, one platform, one machine.**
  - Run: `hangar deploy legilo testflight --ref hangar-smoke --machine rurzomac-mini`; afterwards on the worker `codesign -dvv <exported product>` and `defaults read <app>/Contents/Info.plist CFBundleVersion`.
  - Expect: steps in order; `ci_post_clone.sh` installs xcodegen and generates the project with `CURRENT_PROJECT_VERSION` equal to the Hangar number; stamp log shows `Legilo.app`, `LegiloShare.appex`, `LegiloWeb.appex`, `LegiloModelDownloader.appex` set and `LegiloCapture.app` untouched; export produces `Legilo.pkg`; the TestFlight action reports `VALID`; App Store Connect shows build N for macOS; `CFBundleVersion` equals the stamped number.
  - Date: ______  Build number: ______  ASC build id (macOS): ______  CFBundleVersion: ______  Result: ______
- [ ] **Step 3: Full workflow, both platforms.**
  - Run: `hangar deploy legilo testflight --ref main`; `hangar numbers legilo`.
  - Expect: two jobs with the same number N+1; with both machines online they run on different Macs (scheduler log or queue note confirms); ASC shows build N+1 for both iOS and macOS; `highestHangar == N+1`.
  - Date: ______  Build number: ______  ASC build id (iOS): ______  ASC build id (macOS): ______  Machines used: ______  Result: ______
- [ ] **Step 4: Numbering across both systems.**
  - Run: raise Xcode Cloud's next build number above N+1 as `hangar numbers legilo` advises, start an Xcode Cloud run of Legilo by the usual means, then `hangar numbers legilo`, then `hangar deploy legilo testflight --ref main`.
  - Expect: `lastXcodeCloudRun` reflects the Xcode Cloud run and `next` is above it; the new deploy's number is above the Xcode Cloud run.
  - Date: ______  Xcode Cloud build number: ______  Hangar build number: ______  ASC build ids: ______  Result: ______
- [ ] **Step 5: Failure path.**
  - Run: deploy a branch with a deliberate compile error (`hangar deploy legilo testflight --ref <broken-branch>`); `hangar status <build-id>`; `hangar logs <build-id>`; `hangar numbers legilo`; on the worker `grep -c "<any secret value>" ~/Library/Logs/Hangar/worker.log` and `ls <worker data dir>/jobs/<id>/secrets`.
  - Expect: job `failed` at `archive`; `post-xcodebuild` ran with `CI_XCODEBUILD_EXIT_CODE=65` (Legilo has no such script, so it reports `skipped`); `.xcresult.zip` present in logs/artifacts; `hangar numbers` shows the burned number; `hangar status <id>` names the failed step; the grep prints 0 and `jobs/<id>/secrets` no longer exists.
  - Date: ______  Build number (burned): ______  Failed step: ______  grep count: ______  secrets dir gone: ______  Result: ______
- [ ] **Step 6: Skill path.**
  - Run: in Claude Code with `claude --plugin-dir plugins/hangar`: "build Legilo to TestFlight with Hangar".
  - Expect: the deploy skill runs and reports the number and TestFlight state.
  - Date: ______  Build number: ______  ASC build ids: ______  Result: ______
