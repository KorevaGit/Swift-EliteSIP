import Foundation
import XCTest
@testable import PanelLink

final class MachineConfigLinesTests: XCTestCase {

    func testSingleNumberBecomesOneLine() {
        let config = MachineConfig(installationID: "a", revision: 1, issuedAt: Date(), employee: "Смирнов",
                                   number: "101", sipPassword: "p", workFormat: "office",
                                   presetID: "x", presetName: "М", adminPassword: "")
        XCTAssertEqual(config.effectiveLines,
                       [MachineConfig.Line(id: "main", number: "101", sipPassword: "p", label: "Смирнов")])
    }

    func testStoredConfigWithoutLinesStillDecodes() throws {
        let config = MachineConfig(installationID: "a", revision: 2, issuedAt: Date(timeIntervalSince1970: 0),
                                   employee: "С", number: "101", sipPassword: "p", workFormat: "office",
                                   presetID: "x", presetName: "М", adminPassword: "",
                                   lines: [.init(id: "main", number: "101", sipPassword: "p", label: "С"),
                                           .init(id: "line-7", number: "102", sipPassword: "q", label: "Линия 2")])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
        XCTAssertEqual(try JSONDecoder().decode(MachineConfig.self, from: JSONEncoder().encode(config)), config)
        json.removeValue(forKey: "lines")
        let old = try JSONDecoder().decode(MachineConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.lines, [])
        XCTAssertEqual(old.effectiveLines.count, 1)
    }
}
