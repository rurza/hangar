import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite struct SimulatorCatalogTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// Several runtimes and families; device order in each runtime is shuffled on purpose.
    static let several = Data("""
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
            {"udid": "OLD-17-PRO", "isAvailable": true, "name": "iPhone 17 Pro",
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
            {"udid": "IPAD", "isAvailable": true, "name": "iPad Air 13-inch (M4)",
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M4"},
            {"udid": "16E", "isAvailable": true, "name": "iPhone 16e",
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16e"},
            {"udid": "18-PRO", "isAvailable": true, "name": "iPhone 18 Pro",
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"},
            {"udid": "GONE", "isAvailable": false, "name": "iPhone 19",
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-19"}
          ],
          "com.apple.CoreSimulator.SimRuntime.xrOS-27-1": [
            {"udid": "AVP", "isAvailable": true, "name": "Apple Vision Pro",
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K"}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [],
          "something.unexpected": [{"name": 3}]
        }}
        """.utf8)

    @Test func parsesTheRealListOfThisMac() throws {
        let devices = SimulatorCatalog.devices(fromJSON: try Self.fixture("simctl-devices"))
        #expect(devices.count == 3)
        #expect(Set(devices.map(\.runtime)) == ["iOS 27.2"])
        #expect(SimulatorCatalog.runtimeNames(devices) == ["iOS 27.2"])
        // The iPhone Duo's own runtime has the same version; the numbered iPhone wins.
        let chosen = try #require(SimulatorCatalog.select(platform: .iOS, destination: nil, from: devices))
        #expect(chosen.name == "iPhone 17")
        #expect(chosen.udid == "98DAE3C9-6916-4BC4-89CD-DB0A8BC793CD")
        #expect(chosen.testDestination == TestDestination(
            xcodebuildDestination: "platform=iOS Simulator,id=98DAE3C9-6916-4BC4-89CD-DB0A8BC793CD",
            deviceType: "iPhone 17", runtime: "iOS 27.2"))
    }

    @Test func recommendedIsTheNewestRuntimeAndItsNewestIPhone() throws {
        let devices = SimulatorCatalog.devices(fromJSON: Self.several)
        #expect(SimulatorCatalog.runtimeNames(devices) == ["iOS 26.4", "iOS 27.2", "visionOS 27.1"])
        #expect(SimulatorCatalog.select(platform: .iOS, destination: nil, from: devices)?.udid == "18-PRO")
        #expect(SimulatorCatalog.select(platform: .visionOS, destination: nil, from: devices)?.udid == "AVP")
        #expect(SimulatorCatalog.select(platform: .watchOS, destination: nil, from: devices) == nil)
        #expect(SimulatorCatalog.select(platform: .tvOS, destination: nil, from: devices) == nil)
    }

    @Test func namedDestinationMatchesCaseInsensitivelyOnTheNewestRuntimeThatHasIt() {
        let devices = SimulatorCatalog.devices(fromJSON: Self.several)
        #expect(SimulatorCatalog.select(platform: .iOS, destination: "iphone 17 pro", from: devices)?.udid == "OLD-17-PRO")
        #expect(SimulatorCatalog.select(platform: .iOS, destination: "iPad Air 13-inch (M4)", from: devices)?.udid == "IPAD")
        #expect(SimulatorCatalog.select(platform: .iOS, destination: "iPhone 19", from: devices) == nil)
        #expect(SimulatorCatalog.select(platform: .visionOS, destination: "iPhone 18 Pro", from: devices) == nil)
    }

    static let noise = "objc[123]: Class SimServiceContext is implemented in both A and B. One of the two will be used."

    @Test func readsTheJSONPastNoiseOnOtherLines() throws {
        let text = Self.noise + "\n" + String(decoding: try Self.fixture("simctl-devices"), as: UTF8.self) + "\nwarning: trailing"
        let devices = try #require(SimulatorCatalog.list(fromJSON: Data(text.utf8)))
        #expect(devices.count == 3)
        #expect(SimulatorCatalog.list(fromJSON: Data("no json at all".utf8)) == nil)
        #expect(SimulatorCatalog.list(fromJSON: Data(#"{"devices": {}}"#.utf8)) == [])
    }

    @Test func toleratesGarbage() {
        #expect(SimulatorCatalog.devices(fromJSON: Data()).isEmpty)
        #expect(SimulatorCatalog.devices(fromJSON: Data("[1]".utf8)).isEmpty)
        #expect(SimulatorCatalog.devices(fromJSON: Data(#"{"devices": 3}"#.utf8)).isEmpty)
    }
}

@Suite struct TestSummaryTests {
    @Test func parsesFailuresFromARealSummary() throws {
        let summary = try #require(TestSummary.parse(try SimulatorCatalogTests.fixture("xcresult-summary-failed")))
        #expect(summary.passed == 1)
        #expect(summary.failed == 3)
        #expect(summary.skipped == 0)
        #expect(summary.expectedFailures == 0)
        #expect(summary.total == 4)
        #expect(summary.failures.count == 3)
        #expect(summary.failures[0] == TestFailure(
            name: "SwiftUIRecorderTests/testListeningStartedFromTheKeyboardIsNotEndedByTheView()",
            message: "XCTAssertTrue failed"))
        #expect(summary.line == "1 passed · 3 failed · 0 skipped")
    }

    @Test func readsACompactSummaryPastNoise() throws {
        let json = String(decoding: try SimulatorCatalogTests.fixture("xcresult-summary-passed"), as: UTF8.self)
        let summary = try #require(TestSummary.parse(Data((SimulatorCatalogTests.noise + "\n" + json + "\n").utf8)))
        #expect(summary.passed == 42)
    }

    @Test func prefersTheIdentifierAndFallsBackWhenItIsNull() throws {
        let json = #"{"failedTests": 1, "testFailures": [{"testIdentifierString": null, "testName": "named()", "failureText": "x"}]}"#
        #expect(TestSummary.parse(Data(json.utf8))?.failures == [TestFailure(name: "named()", message: "x")])
    }

    @Test func masksNamesAndMessagesBeforeEncoding() {
        var summary = TestSummary()
        summary.failures = [TestFailure(name: "T/p\"ss()", message: "got p\"ss\nnext")]
        let masked = summary.masked { $0.replacingOccurrences(of: "p\"ss", with: "[masked]") }
        #expect(masked.failures == [TestFailure(name: "T/[masked]()", message: "got [masked]\nnext")])
    }

    @Test func parsesARealPassingSummary() throws {
        let summary = try #require(TestSummary.parse(try SimulatorCatalogTests.fixture("xcresult-summary-passed")))
        #expect(summary.passed == 42 && summary.failed == 0 && summary.total == 42 && summary.failures.isEmpty)
        #expect(summary.outputs == [
            "test.passed": "42", "test.failed": "0", "test.skipped": "0", "test.total": "42", "test.failures": "[]",
        ])
    }

    @Test func keepsTheFirstMessagePerTestCapsTheListAndToleratesMissingFields() throws {
        var failures: [[String: Any]] = (0..<60).map { ["testIdentifierString": "T/t\($0)()", "failureText": "boom \($0)"] }
        failures.insert(["testIdentifierString": "T/t0()", "failureText": "second message"], at: 1)
        failures.append(["testName": "named()"])
        let json: [String: Any] = ["passedTests": 5, "failedTests": 61, "testFailures": failures]
        let summary = try #require(TestSummary.parse(try JSONSerialization.data(withJSONObject: json)))
        #expect(summary.total == 66)
        #expect(summary.skipped == 0)
        #expect(summary.failures.count == TestSummary.failureCap)
        #expect(summary.failures[0] == TestFailure(name: "T/t0()", message: "boom 0"))
        let decoded = try JSONDecoder().decode([TestFailure].self, from: Data(summary.outputs["test.failures"]!.utf8))
        #expect(decoded == summary.failures)
        #expect(TestSummary.parse(Data("not json".utf8)) == nil)
        #expect(TestSummary.parse(Data("[]".utf8)) == nil)
    }
}
