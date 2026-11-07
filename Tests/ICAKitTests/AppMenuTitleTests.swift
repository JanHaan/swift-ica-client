import Foundation
import Testing
@testable import ICAKit

@Suite struct AppMenuTitleTests {
    private func resources(_ json: String) throws -> [StoreClient.Resource] {
        struct List: Decodable { let resources: [StoreClient.Resource] }
        return try JSONDecoder().decode(List.self, from: Data(json.utf8)).resources
    }

    @Test func prefersTheResourceName() throws {
        let list = try resources(#"{"resources":[{"id":"a","name":"Sound Demo"},{"id":"b","name":"Notepad"}]}"#)
        #expect(AppMenuTitle.name(resources: list, candidates: ["notepad.exe", "x"]) == "Notepad")
        #expect(AppMenuTitle.name(resources: list, candidates: ["Unknown", " sound  demo "]) == "Sound Demo")
    }

    @Test func fallsBackToTheAppName() throws {
        let list = try resources(#"{"resources":[{"id":"a","name":"Sound Demo"}]}"#)
        #expect(AppMenuTitle.name(resources: list, candidates: ["", "  Calc  "]) == "Calc")
        #expect(AppMenuTitle.name(resources: [], candidates: ["Calc"]) == "Calc")
        #expect(AppMenuTitle.name(resources: list, candidates: []) == nil)
        #expect(AppMenuTitle.name(resources: list, candidates: ["", "  "]) == nil)
    }

    @Test func skipsDisabledResources() throws {
        let list = try resources(#"{"resources":[{"id":"a","name":"Calc Pro","disabled":true}]}"#)
        #expect(AppMenuTitle.name(resources: list, candidates: ["calc pro"]) == "calc pro")
    }

    @Test func clampsLongTitles() {
        #expect(AppMenuTitle.clamped("Notepad") == "Notepad")
        #expect(AppMenuTitle.clamped("  Two\nlines ") == "Two lines")
        let long = String(repeating: "a", count: 60)
        let out = AppMenuTitle.clamped(long, limit: 10)
        #expect(out == String(repeating: "a", count: 9) + "…")
    }
}
