# Spike: Developer ID cloud-signing with an API key

## Purpose

The Hangar spec leaves one question open: can an App Store Connect API key, with no Developer ID certificate pre-installed, export a `developer-id` build through Xcode's cloud-managed signing (`-allowProvisioningUpdates` plus the `-authenticationKey*` flags)? The answer decides how Phase 2 signs macOS Developer ID exports. Nothing else in Phase 1 depends on it.

## Procedure

Run everything on the build Mac (`rurzomac-mini`) as the `hangar` user.

### 1. Produce an archive

Clone Herald, then:

```sh
export CI_PRIMARY_REPOSITORY_PATH=<path to the Herald clone>
"$CI_PRIMARY_REPOSITORY_PATH/ci_scripts/ci_post_clone.sh"

xcodebuild archive -scheme <Herald scheme> \
  -destination 'generic/platform=macOS' \
  -archivePath /tmp/spike/Herald.xcarchive \
  -allowProvisioningUpdates \
  -authenticationKeyPath <AuthKey.p8> \
  -authenticationKeyID <KEY_ID> \
  -authenticationKeyIssuerID <ISSUER_ID>

security find-identity -v -p codesigning
```

Note whether the archive step created an Apple Development identity in the `hangar` login keychain.

### 2. Run A: no Developer ID certificate in the keychain

Confirm with `security find-identity -v -p codesigning` that no "Developer ID Application" identity exists, then:

```sh
scripts/spike/developer-id-cloud-signing.sh \
  --archive /tmp/spike/Herald.xcarchive \
  --team <TEAMID> --key-id <KEY_ID> --issuer-id <ISSUER_ID> \
  --key <AuthKey.p8> --out /tmp/spike/run-a
```

Exit code 0 means `RESULT: PASS`, 1 means `RESULT: FAIL` (the last 40 lines of the xcodebuild log are printed).

### 3. Run B (only if Run A fails)

Open Xcode once as `hangar`, signed in with the Apple ID, and let Xcode create or download the cloud-managed Developer ID certificate. Re-check the keychain identities, then rerun the same command with `--out /tmp/spike/run-b`.

## Results

Status: pending — to be filled by the author.

| Field | Run A | Run B |
| --- | --- | --- |
| Date | pending — to be filled by the author | pending — to be filled by the author |
| macOS build | pending — to be filled by the author | pending — to be filled by the author |
| Xcode build | pending — to be filled by the author | pending — to be filled by the author |
| Exact command | pending — to be filled by the author | pending — to be filled by the author |
| RESULT (PASS/FAIL) | pending — to be filled by the author | pending — to be filled by the author |
| First error line (on FAIL) | pending — to be filled by the author | pending — to be filled by the author |
| Keychain identities present (`security find-identity -v -p codesigning`) | pending — to be filled by the author | pending — to be filled by the author |

Conclusion (Outcome A or B): pending — to be filled by the author.

## Outcomes

**Outcome A: "API key can export Developer ID via cloud-managed signing".** Run A passes, or Run B passes with only Xcode-managed certificates. Phase 2 exports Developer ID builds with the same API key flags as the App Store path and needs no certificate handling of its own.

**Outcome B: "it cannot; Phase 2 uses the temporary-keychain `.p12` fallback".** Both runs fail. Phase 2 stores a Developer ID `.p12` as a write-only secret, imports it into a temporary keychain for the job, exports with manual signing, and deletes the keychain afterwards.
