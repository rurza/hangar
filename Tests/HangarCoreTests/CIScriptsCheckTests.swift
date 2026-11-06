import Testing

@testable import HangarCore

@Suite struct CIScriptsCheckTests {
    /// BatFi's scripts, as they broke on 5 Nov: an unquoted path and Sentry settings Hangar did not define.
    static let postClone = """
        #!/bin/sh
        # Writes the analytics DSN for $SOMETHING_IN_A_COMMENT
        CLIENTS_PATH=$CI_PRIMARY_REPOSITORY_PATH/BatFiKit/Sources/Clients
        cd ${CLIENTS_PATH}
        if [ ! -d ${CLIENTS_PATH} ]; then exit 1; fi
        echo "let analyticsDSN = \\"$SENTRY_DSN\\"" > AnalyticsDSN.swift
        echo 'literal $NOT_EXPANDED' and \\$ESCAPED
        echo "${OPTIONAL:-fallback} ${HOME} $TMPDIR $1 $# $?"
        for FILE in *.swift; do echo "$FILE"; done
        read -r FIRST SECOND < /dev/null
        export BUILT_HERE=1
        echo "$BUILT_HERE $FIRST $SECOND $lowercase"
        """

    static let postXcodebuild = """
        #!/bin/zsh
        set -e
        if [[ -n $CI_ARCHIVE_PATH ]]; then
          sentry-cli --auth-token $SENTRY_AUTH_TOKEN upload-dif --org ${SENTRY_ORG} $CI_ARCHIVE_PATH
        fi
        echo "$CLIENTS_PATH"  # assigned by the other script
        """

    @Test func findsVariablesNothingDefines() {
        let warnings = CIScriptsCheck.check(
            [
                CIScript(name: "ci_post_clone.sh", text: Self.postClone, executable: false),
                CIScript(name: "ci_post_xcodebuild.sh", text: Self.postXcodebuild, executable: true),
                CIScript(name: "helper.sh", text: "echo $SENTRY_ORG", executable: false),
            ],
            definedNames: ["SENTRY_ORG"])
        #expect(warnings.undefined == [
            "ci_post_clone.sh": ["SENTRY_DSN"],
            "ci_post_xcodebuild.sh": ["SENTRY_AUTH_TOKEN"],
        ])
        // Only hooks must be executable; a helper the hooks source need not be.
        #expect(warnings.notExecutable == ["ci_post_clone.sh"])
    }

    @Test func sentencesNameTheScriptAndTheFix() {
        let lines = CIScriptsCheck.sentences(
            CIScriptsCheck.Warnings(
                undefined: ["ci_post_xcodebuild.sh": ["SENTRY_AUTH_TOKEN", "SENTRY_DSN"], "ci_post_clone.sh": ["SENTRY_DSN"]],
                notExecutable: ["ci_post_clone.sh"]),
            directory: "App/ci_scripts")
        #expect(lines == [
            "App/ci_scripts/ci_post_clone.sh uses $SENTRY_DSN, which isn’t defined in Hangar: add it under Variables, or the script sees it empty.",
            "App/ci_scripts/ci_post_xcodebuild.sh uses $SENTRY_AUTH_TOKEN and $SENTRY_DSN, which aren’t defined in Hangar: add them under Variables, or the script sees them empty.",
            "App/ci_scripts/ci_post_clone.sh isn’t executable: Hangar runs it with /bin/sh, but Xcode Cloud requires chmod +x (commit the mode with git update-index --chmod=+x).",
        ])
    }

    @Test func scanSkipsCommentsQuotesDefaultsAndLowerCase() {
        let scan = CIScriptsCheck.scan(Self.postClone)
        #expect(!scan.referenced.contains("SOMETHING_IN_A_COMMENT"))
        #expect(!scan.referenced.contains("NOT_EXPANDED"))
        #expect(!scan.referenced.contains("ESCAPED"))
        #expect(!scan.referenced.contains("OPTIONAL"))
        #expect(!scan.referenced.contains("lowercase"))
        #expect(scan.referenced.isSuperset(of: ["SENTRY_DSN", "CLIENTS_PATH", "CI_PRIMARY_REPOSITORY_PATH", "HOME"]))
        #expect(scan.assigned.isSuperset(of: ["CLIENTS_PATH", "FILE", "FIRST", "SECOND", "BUILT_HERE"]))
    }

    @Test func namesSetForOtherWorkflowsSaySo() {
        let lines = CIScriptsCheck.sentences(
            CIScriptsCheck.Warnings(undefined: ["ci_post_xcodebuild.sh": ["SENTRY_AUTH_TOKEN", "SENTRY_DSN"]], notExecutable: []),
            onlyFor: ["SENTRY_DSN": ["Beta", "Release"]])
        #expect(lines == [
            "ci_scripts/ci_post_xcodebuild.sh uses $SENTRY_AUTH_TOKEN and $SENTRY_DSN, which aren’t defined in Hangar for this workflow ($SENTRY_DSN only for “Beta” and “Release”): add them for this workflow too, or the script sees them empty.",
        ])
    }
}

@Suite struct CIScriptsCheckNotReceivedTests {
    @Test func aGlobalSecretTheAppDoesNotReceiveIsNamedAsSuch() {
        let warnings = CIScriptsCheck.Warnings(undefined: ["ci_post_clone.sh": ["SENTRY_AUTH_TOKEN", "OTHER"]], notExecutable: [])
        let lines = CIScriptsCheck.sentences(warnings, notReceived: ["SENTRY_AUTH_TOKEN"])
        #expect(lines == [
            "ci_scripts/ci_post_clone.sh uses $SENTRY_AUTH_TOKEN, a global secret this app doesn’t receive: choose it under Global Secrets on the app’s page, or the script sees it empty.",
            "ci_scripts/ci_post_clone.sh uses $OTHER, which isn’t defined in Hangar: add it under Variables, or the script sees it empty.",
        ])
    }
}
