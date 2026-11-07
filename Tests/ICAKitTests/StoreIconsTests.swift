import Foundation
import Testing
@testable import ICAKit

@Suite struct StoreIconsTests {
    private func resources(_ json: String) throws -> [StoreClient.Resource] {
        struct List: Decodable { let resources: [StoreClient.Resource] }
        return try JSONDecoder().decode(List.self, from: Data(json.utf8)).resources
    }

    @Test func normalisesNames() {
        #expect(StoreIconIndex.normalize("  Sound   Demo ") == "sound demo")
        #expect(StoreIconIndex.normalize("Notepad.EXE") == "notepad")
    }

    @Test func indexMatchesByName() throws {
        let list = try resources("""
        {"resources":[
          {"id":"a","name":"Sound Demo","iconurl":"Resources/Icon/a"},
          {"id":"b","name":"No Icon"},
          {"id":"c","name":"Sound Demo","iconurl":"Resources/Icon/c"}]}
        """)
        let index = StoreIconIndex.index(list)
        #expect(index.count == 1)
        #expect(StoreIconIndex.iconURL(in: index, names: ["Other", "sound demo"]) == "Resources/Icon/a")
        #expect(StoreIconIndex.iconURL(in: index, names: ["No Icon"]) == nil)
    }

    @Test func cacheNameIsStablePerStore() {
        let a = URL(string: "https://one.example/welcome/")!, b = URL(string: "https://two.example/welcome/")!
        let n = StoreIconIndex.cacheFileName(base: a, iconurl: "Resources/Icon/a")
        #expect(n == StoreIconIndex.cacheFileName(base: a, iconurl: "Resources/Icon/a"))
        #expect(n != StoreIconIndex.cacheFileName(base: b, iconurl: "Resources/Icon/a"))
        #expect(n.hasSuffix(".png") && n.count == 64 + 4)
    }
}
