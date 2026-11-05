import Testing

@testable import HangarServer

/// Query parameters read as the browser's URLSearchParams writes them.
@Suite struct FormQueryTests {
    @Test func plusIsASpaceAndEscapedPlusIsAPlus() {
        let query = FormQuery("workflow=UX+Review+Keep&tag=A%2BB&both=a+%2B+b")
        #expect(query.get("workflow") == "UX Review Keep")
        #expect(query.get("tag") == "A+B")
        #expect(query.get("both") == "a + b")
    }

    @Test func escapedSeparatorsAndNonASCIIDecode() {
        let query = FormQuery("name=R%26D%3D1&city=%C5%81%C3%B3d%C5%BA&raw=%20x%20")
        #expect(query.get("name") == "R&D=1")
        #expect(query.get("city") == "Łódź")
        #expect(query.get("raw") == " x ")
    }

    @Test func absentEmptyRepeatedAndMalformed() {
        let query = FormQuery("a=&b&c=1&c=2&bad=%zz&my+key=v")
        #expect(query.get("a") == "")
        #expect(query.get("b") == "")
        #expect(query.get("c") == "1")
        #expect(query.get("bad") == "%zz")
        #expect(query.get("my key") == "v")
        #expect(query.get("missing") == nil)
        #expect(FormQuery(nil).get("a") == nil)
    }
}
