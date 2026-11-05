import Testing

@testable import HangarWorker

@Suite struct FailureCauseTests {
    static func cause(_ lines: [String], fallback: Bool = false) -> String? {
        var finder = FailureCause()
        lines.forEach { finder.consume($0) }
        return finder.line(fallbackToLastLine: fallback)
    }

    @Test func firstCompilerErrorWinsAndLosesItsDirectory() {
        #expect(Self.cause([
            "warning: something",
            "/a/b/File.swift:1:2: error: first",
            "/a/b/Other.swift:1:2: error: second",
        ]) == "File.swift:1:2: error: first")
    }

    @Test func aToolErrorBeatsAnEarlierShellError() {
        #expect(Self.cause(["cd: /x: No such file or directory", "error: cannot find 'x' in scope"])
            == "error: cannot find 'x' in scope")
    }

    @Test func missingDWARFFilesAreExplained() {
        #expect(Self.cause([
            "lipo: warning: file not found '/tmp/j/tmp/dsym-b57f48.dwarf'",
            "lipo: no eligible inputs found",
            "error: lipo:",
            "** ARCHIVE FAILED **",
        ]) == "dSYM generation failed: lipo could not find the temporary DWARF files dsymutil writes to TMPDIR")
    }

    @Test func failedBuildCommandIsACandidate() {
        #expect(Self.cause([
            "The following build commands failed:",
            "\tGenerateDSYMFile /x/LegiloShare.appex.dSYM (in target 'LegiloShare')",
            "(1 failure)",
        ]) == "GenerateDSYMFile /x/LegiloShare.appex.dSYM (in target 'LegiloShare')")
    }

    @Test func scriptsFallBackToTheirLastLine() {
        let lines = ["⚙️ Generating project...", "Couldn't find current username"]
        #expect(Self.cause(lines) == "Couldn't find current username")
        #expect(Self.cause(["Stamping 84", "it broke"]) == nil)
        #expect(Self.cause(["Stamping 84", "it broke", "** ARCHIVE FAILED **"], fallback: true) == "it broke")
    }

    @Test func longLinesAreCut() {
        let line = "error: " + String(repeating: "x", count: 400)
        let cut = Self.cause([line])
        #expect(cut?.count == FailureCause.maxLength)
        #expect(cut?.hasSuffix("…") == true)
    }
}
