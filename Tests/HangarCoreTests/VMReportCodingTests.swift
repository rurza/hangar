import Foundation
import Testing
import HangarCore

/// A VM report's checklist round-trips, and an older worker's report (no checklist) still decodes.
struct VMReportCodingTests {
    @Test func theChecklistRoundTrips() throws {
        let report = VMReport(
            slots: 0, configuredSlots: 1, freeSlots: 0, storageFreeGB: 120, networkFilter: false,
            problem: "the VM network filter is not installed",
            checks: [VMCheck(id: "networkFilter", title: "Network filter", ok: false, detail: "not installed", command: "sudo x vm setup")],
            imageBuildCommand: "x vm image build")
        let data = try JSONCoding.encoder.encode(report)
        #expect(try JSONCoding.decoder.decode(VMReport.self, from: data) == report)
    }

    @Test func anOlderWorkersReportHasNoChecklist() throws {
        let json = #"{"slots": 0, "problem": "no VM image with Xcode yet"}"#
        let report = try JSONCoding.decoder.decode(VMReport.self, from: Data(json.utf8))
        #expect(report.checks.isEmpty && report.imageBuildCommand == nil)
        #expect(report.problem == "no VM image with Xcode yet")
    }
}
