# `.hangar.yml`

Hangar reads `.hangar.yml` from the root of the commit it builds. A missing or invalid file refuses the deploy before a build number is reserved.

## Example (Legilo)

```yaml
version: 1
workflows:
  testflight:
    project: Legilo.xcodeproj        # or `workspace:`; relative to the repo root
    xcode: "27.2"                    # prefix match against installed Xcodes
    team: YL78V8PY6H                 # optional
    tools: [brew]                    # optional; names the worker must report
    start: { manual: { branches: [main, "release/*"] } }   # optional; default: any branch
    actions:
      - { scheme: Legilo, platform: macos, export: app-store-connect }
      - { scheme: LegiloMobile, platform: ios, export: app-store-connect }
    post-actions:
      - testflight:
          groups: [Internal]
```

## Keys

| Key | Required | Meaning |
| --- | --- | --- |
| `version` | yes | Must be `1`. |
| `workflows` | yes | Map of workflow name to workflow. At least one. |

### Workflow

| Key | Required | Meaning |
| --- | --- | --- |
| `project` / `workspace` | exactly one | Path relative to the repository root. Its directory is where `ci_scripts/` lives. |
| `xcode` | yes | Quoted string, prefix-matched against installed Xcodes (`"27.2"`; unquoted `27.10` would become 27.1, so numbers are rejected). |
| `team` | no | Apple developer team ID (quote it; numeric values are rejected). |
| `tools` | no | Tool names the worker must report (for example `brew`). Default: none. |
| `start` | no | How the workflow starts. Only manual start (Deploy in Hangar, `hangar deploy`, a skill) exists: `start: { manual: { branches: [main, "release/*"] } }` or `branches: any`. Without `start`, any branch. Anything else under `start` is refused with "Only manual start is supported for now". See [Start](#start). |
| `actions` | yes | One or more archive or test actions. Each becomes one job of the build. |
| `post-actions` | no | Steps run after each archive action succeeds, in order. Test actions have none. Default: none. |

### Start

`start.manual.branches` lists the branches a build may start from, like Xcode Cloud's Manual Start source branch: `any`, or a non-empty list of names and patterns. Deploy suggests the first exact name in the list (else the repository's default branch), offers only matching branches, and warns, without refusing, when you type a branch that doesn't match. A tag or a commit SHA can always be typed.

Patterns (`RefPattern` in HangarCore, shared with the web UI's `branchMatches`):

- A name without `*` matches exactly that branch; case matters.
- `*` matches any characters within one level, not `/`: `release/*` matches `release/2.0`, not `release/2.0/hotfix`.
- `**` matches across levels: `release/**` matches both, `**` matches every branch.
- The whole name must match; nothing else is special.

In JSON (the API) a workflow carries `"start": {"manual": {"branches": "any" | ["main", "release/*"]}}`, or no `start`.

### Action

An action archives a scheme or runs its tests, like Xcode Cloud's Archive and Test actions. There are no Build or Analyze actions.

```yaml
    actions:
      - { scheme: LegiloMobile, platform: ios, export: app-store-connect }              # archive (flat form)
      - archive: { scheme: Legilo, platform: macos, export: developer-id }              # archive (explicit form)
      - test: { scheme: LegiloMobile, platform: ios, destination: "iPhone 17 Pro", test-plan: Smoke }
      - test: { scheme: Legilo, platform: macos }
```

| Key | Archive | Test | Values |
| --- | --- | --- | --- |
| `scheme` | required | required | Xcode scheme name. |
| `platform` | required | required | `ios`, `macos`, `visionos`, `tvos`, `watchos`. |
| `export` | required | not allowed | `app-store-connect`, `developer-id`. |
| `destination` | not allowed | optional | A simulator name, or `recommended` (the default). Not allowed on a macOS test. |
| `test-plan` | not allowed | optional | Test plan passed to `xcodebuild -testPlan`; default: the scheme's. |

#### What a test action runs

A test job runs `checkout` → `post-clone` → `pre-xcodebuild` → `test` → `post-xcodebuild` → `upload-artifacts` → `cleanup`. It has no stamp, export or post-actions. The `test` step resolves Swift packages as an archive does, then runs `xcodebuild test -scheme … -destination … [-testPlan …] -resultBundlePath <job>/result.xcresult` with the same signing flags as an archive (`-allowProvisioningUpdates`, and the team API key when there is one) and without secret variables. The worker does not need the App Store Connect key for a test job, but a deploy still does: the server reserves the build number through App Store Connect, for test-only workflows too.

Destinations:

- macOS tests run on the worker itself (`platform=macOS`).
- iOS, visionOS, tvOS and watchOS tests run on a simulator from `xcrun simctl list devices available`, using the workflow's Xcode. `recommended` picks the newest runtime of the platform and its newest iPhone, Apple Vision, Apple TV or Apple Watch. A name picks the device with that name or device type (case-insensitive) on the newest runtime that has it.
- With no simulator for the platform, the job fails before checkout ("No iOS simulator available on <machine>; install one in Xcode › Settings › Components"). The scheduler already skips machines that report no runtime for the platform ("no iOS simulator"). It knows runtimes only, not device names, so a test that names a device can go to a Mac that lacks it and fail there. Workers list runtimes with the Xcode `xcode-select` points at, every 10 minutes; the job uses the workflow's Xcode, so a runtime only one of them can use may make the two disagree.
- Two test jobs running at once on one Mac (`maxConcurrentJobs` above 1) pick the same simulator; give test-heavy Macs one slot.
- Test jobs need an updated worker: one from before test actions shows "update the worker (run the install command again)" in the queue note and gets no test jobs. Its archive jobs keep running.

The environment has `CI_XCODEBUILD_ACTION=test`, `CI_RESULT_BUNDLE_PATH`, `CI_TEST_DESTINATION_DEVICE_TYPE` and `CI_TEST_DESTINATION_RUNTIME` (for example `iPhone 17` and `iOS 27.2`), and `CI_TEST_PLAN` when set. `CI_ARCHIVE_PATH` is not set.

After the tests, pass or fail, Hangar reads the result bundle with `xcrun xcresulttool get test-results summary` (Xcode 16 or later; with an older Xcode there are no totals and the job keeps xcodebuild's reason) and logs the totals and each failing test. Failing tests fail the job with "test: 3 tests failed"; when xcodebuild fails for another reason (a compile error, say), the reason stays "test: xcodebuild exited with 65". The result bundle is uploaded as `<scheme>.xcresult.zip`, and the totals become job outputs (see the [API](api.md#test-outputs)).

### Secret variables

Secret variables are available to `ci_scripts` hooks and post-actions but not to `xcodebuild`, so not to build phases: xcodebuild records its environment in DerivedData logs and in the result bundle, which is uploaded as an artifact. If a build phase needs a secret, write it to a file from `ci_pre_xcodebuild.sh`.

### Reserved names

Hangar sets `CI_*` (the Xcode Cloud variables), `PATH`, `HOME`, `DEVELOPER_DIR`, `USER`, `LOGNAME`, `TMPDIR` and `SHELL` for every job; a variable with one of these names is ignored with a warning in the job log, and the web UI refuses to create one. `LANG`, `LC_ALL` and `LC_CTYPE` may be overridden. `TMPDIR` is the job's own folder in the Mac user's temporary directory (`/var/folders/…/T/hangar-jobs/<job id>`, a path without spaces), created before the first hook and deleted with the job; the worker removes leftovers of a crashed run when it starts.

### Private Swift packages

Swift packages are resolved before the archive (or the tests), in a separate `xcodebuild -resolvePackageDependencies` run that uses the system git. That run, and only that run, can authenticate to github.com with the `HANGAR_GITHUB_TOKEN` variable, so private packages hosted on GitHub resolve as long as the token can read them. The archive itself then runs with automatic package resolution disabled and without the token. Packages on other hosts must be reachable without credentials.

### Post-actions

An entry is either a bare name (`- testflight`) or a one-key map (`- testflight: { ... }`). Every post-action accepts `requires-approval: true`, which holds the step until someone approves it. Unknown post-action names, unknown settings and wrongly typed settings are rejected when the file is parsed.

#### `testflight`

| Setting | Type | Default | Meaning |
| --- | --- | --- | --- |
| `wait-for-processing` | bool | `true` | Wait until App Store Connect finishes processing the build. |
| `processing-timeout-minutes` | positive integer | `60` | How long to wait for processing. |
| `groups` | list of strings | `[]` | Beta groups to add the build to. |
| `what-to-test` | bool | `true` | Set the "What to Test" text. |
| `submit-for-external-review` | bool | `false` | Submit the build for external beta review. |

## Defining the workflow in Hangar instead

An app does not need a committed `.hangar.yml`. Its workflow file can be stored in Hangar instead, in the same format, with `hangar workflows <app> --set <file.yml>` (or `PUT /apps/{id}/workflow-file`). The file is validated when you store it and again whenever a build uses it. While an app has a stored file, deploys and `hangar workflows` use it and ignore the repository's `.hangar.yml`; the commit is still resolved and recorded as usual. `hangar workflows <app> --clear` removes it, and the repository's `.hangar.yml` is required again. Stored files are limited to 64 KB. Hangar never writes to your repository, so to move a stored workflow into the repo, copy its YAML to `.hangar.yml` and clear the stored one.
