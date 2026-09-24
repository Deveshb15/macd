import XCTest
@testable import Macd

final class AnalyzeDecoderTests: XCTestCase {
    func testRealFixtureDecodesAndSumsToTotal() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mole-analyze-1.49.2", withExtension: "json"))
        let listing = try AnalyzeDecoder.decode(Data(contentsOf: url))
        XCTAssertFalse(listing.entries.isEmpty)
        XCTAssertEqual(listing.totalSize, listing.entries.reduce(0) { $0 + $1.size })
    }

    func testEntriesSortLargestFirstThenByName() throws {
        let json = """
        {"path":"/x","entries":[
          {"name":"b","path":"/x/b","size":10,"is_dir":true},
          {"name":"big","path":"/x/big","size":99,"is_dir":false},
          {"name":"a","path":"/x/a","size":10,"is_dir":true}
        ],"total_size":119}
        """
        let listing = try AnalyzeDecoder.decode(Data(json.utf8))
        XCTAssertEqual(listing.entries.map(\.name), ["big", "a", "b"])
    }

    func testEmptyFolder() throws {
        let listing = try AnalyzeDecoder.decode(Data(#"{"path":"/x","entries":[],"total_size":0}"#.utf8))
        XCTAssertTrue(listing.entries.isEmpty)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try AnalyzeDecoder.decode(Data("{not json".utf8)))
        XCTAssertThrowsError(try AnalyzeDecoder.decode(lines: ["no json here"]))
    }

    func testLeadingNoiseBeforeJSONIsIgnored() throws {
        let listing = try AnalyzeDecoder.decode(lines: ["warning: something", #"{"path":"/x","entries":[],"total_size":0}"#])
        XCTAssertEqual(listing.path, "/x")
    }

    func testDrillDownRequestsSubfolder() async throws {
        let runner = FakeMoleRunner()
        runner.responses["analyze -json /x"] = .success([#"{"path":"/x","entries":[{"name":"a","path":"/x/a","size":5,"is_dir":true}],"total_size":5}"#])
        runner.responses["analyze -json /x/a"] = .success([#"{"path":"/x/a","entries":[],"total_size":0}"#])
        let model = AnalyzeModel(runner: runner)

        model.start(at: "/x")
        try await waitForLoaded(model)
        guard case .loaded(let root) = model.state else { return XCTFail() }
        model.open(root.entries[0])
        try await waitForLoaded(model, path: "/x/a")

        XCTAssertEqual(model.trail, ["/x", "/x/a"])
        model.goBack(to: 0)
        XCTAssertEqual(model.trail, ["/x"])
        XCTAssertEqual(model.state, .loaded(root), "going back uses the cached listing")
        XCTAssertEqual(runner.calls.count, 2)
    }

    private func waitForLoaded(_ model: AnalyzeModel, path: String? = nil) async throws {
        for _ in 0..<500 {
            if case .loaded(let listing) = model.state, path == nil || listing.path == path { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("never loaded, state \(model.state)")
    }
}
