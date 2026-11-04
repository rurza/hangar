import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Numbers: HangarCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show an app's build numbers, or raise the next one.",
        discussion: "The next number is one more than the highest known in Hangar, App Store Connect and Xcode Cloud.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The app's slug or ID.") var app: String
    @Option(help: "Make this the next build number; it must be higher than the current next.") var bump: Int?

    func run(_ cli: CLI) async throws {
        let report = if let bump {
            try await cli.api.bumpNumber(app: app, next: bump)
        } else {
            try await cli.api.numbers(app: app)
        }
        if cli.json { return try cli.printJSON(report) }
        cli.print(Self.render(report))
    }

    static func render(_ report: NumbersReport) -> String {
        func number(_ value: Int?) -> String { value.map(String.init) ?? "-" }
        return Table.keyValue([
            ("Next build number", "\(report.next)"),
            ("Highest in Hangar", number(report.highestHangar)),
            ("Highest in App Store Connect", number(report.highestAppStoreConnect)),
            ("Last Xcode Cloud run", number(report.lastXcodeCloudRun)),
            ("Build in flight", report.inFlight ? "yes" : "no"),
        ])
    }
}
