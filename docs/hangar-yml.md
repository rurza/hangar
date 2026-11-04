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
| `xcode` | yes | Prefix matched against the Xcode versions installed on the worker. |
| `team` | no | Apple developer team ID. |
| `tools` | no | Tool names the worker must report (for example `brew`). Default: none. |
| `actions` | yes | One or more archive actions. |
| `post-actions` | no | Steps run after all actions succeed, in order. Default: none. |

### Action

| Key | Values |
| --- | --- |
| `scheme` | Xcode scheme name. |
| `platform` | `ios`, `macos`, `visionos`, `tvos`, `watchos`. |
| `export` | `app-store-connect`, `developer-id`. |

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
