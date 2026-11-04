import Testing
@testable import HangarCore

struct XcodeVersionTests {
    @Test func prefixMatchIsComponentWise() {
        #expect(XcodeVersion.matches(requested: "27.2", installed: "27.2"))
        #expect(XcodeVersion.matches(requested: "27.2", installed: "27.2.1"))
        #expect(XcodeVersion.matches(requested: "27", installed: "27.2.1"))
        #expect(!XcodeVersion.matches(requested: "27.2", installed: "27.20"))
        #expect(!XcodeVersion.matches(requested: "27.2.1", installed: "27.2"))
    }

    @Test func bestPicksHighest() {
        let installed = [
            InstalledXcode(version: "27.2", build: "a", path: "/a"),
            InstalledXcode(version: "27.10", build: "b", path: "/b"),
            InstalledXcode(version: "27.2.1", build: "c", path: "/c"),
            InstalledXcode(version: "26.4", build: "d", path: "/d"),
        ]
        #expect(XcodeVersion.best(installed, requested: "27.2")?.path == "/c")
        #expect(XcodeVersion.best(installed, requested: "27")?.path == "/b")
        #expect(XcodeVersion.best(installed, requested: "25") == nil)
    }
}
