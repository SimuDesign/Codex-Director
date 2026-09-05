import XCTest
@testable import DirectorUI
@testable import DirectorCore

final class CapabilityPurposeLocalizationTests: XCTestCase {
    func testLocalizationRequiresStableIdentityKindNameAndSourceSignature() {
        let sourcePurpose = "Inspect local assets."
        let entry = CapabilityPurposeLocalizationEntry(
            resourceID: "skill:global:test:one",
            kind: .skill,
            sourceName: "same-skill",
            sourcePurpose: sourcePurpose,
            chinesePurpose: "检查本地素材。"
        )
        let catalog = [entry]

        XCTAssertEqual(
            CapabilityPurposeLocalization.localizedSummary(
                for: resource(
                    id: entry.resourceID,
                    kind: .skill,
                    name: entry.sourceName,
                    summary: sourcePurpose
                ),
                language: .simplifiedChinese,
                catalog: catalog
            ),
            entry.chinesePurpose
        )
        XCTAssertEqual(
            CapabilityPurposeLocalization.localizedSummary(
                for: resource(
                    id: "skill:global:test:two",
                    kind: .skill,
                    name: entry.sourceName,
                    summary: sourcePurpose
                ),
                language: .simplifiedChinese,
                catalog: catalog
            ),
            sourcePurpose
        )
        XCTAssertEqual(
            CapabilityPurposeLocalization.localizedSummary(
                for: resource(
                    id: entry.resourceID,
                    kind: .agent,
                    name: entry.sourceName,
                    summary: sourcePurpose
                ),
                language: .simplifiedChinese,
                catalog: catalog
            ),
            sourcePurpose
        )
        XCTAssertEqual(
            CapabilityPurposeLocalization.localizedSummary(
                for: resource(
                    id: entry.resourceID,
                    kind: .skill,
                    name: "renamed-skill",
                    summary: sourcePurpose
                ),
                language: .simplifiedChinese,
                catalog: catalog
            ),
            sourcePurpose
        )
        XCTAssertEqual(
            CapabilityPurposeLocalization.localizedSummary(
                for: resource(
                    id: entry.resourceID,
                    kind: .skill,
                    name: entry.sourceName,
                    summary: "Inspect changed assets."
                ),
                language: .simplifiedChinese,
                catalog: catalog
            ),
            "Inspect changed assets."
        )
    }

    func testEnglishChineseSourceAndInvalidSummaryFallbacks() {
        let sourcePurpose = "Review a bounded change."
        let entry = CapabilityPurposeLocalizationEntry(
            resourceID: "agent:global:test:one",
            kind: .agent,
            sourceName: "Test Agent",
            sourcePurpose: sourcePurpose,
            chinesePurpose: "评审限定范围的变更。"
        )
        let translated = resource(
            id: entry.resourceID,
            kind: .agent,
            name: entry.sourceName,
            summary: sourcePurpose
        )
        XCTAssertEqual(
            CapabilityPurposeLocalization.localizedSummary(
                for: translated,
                language: .english,
                catalog: [entry]
            ),
            sourcePurpose
        )

        let chineseSource = resource(
            id: "skill:global:test:chinese",
            kind: .skill,
            name: "chinese-source",
            summary: "读取并整理本地资料。"
        )
        XCTAssertEqual(
            CapabilityPurposeLocalization.localizedSummary(
                for: chineseSource,
                language: .simplifiedChinese,
                catalog: []
            ),
            chineseSource.summary
        )

        for invalid in [nil, "", "   ", ">", ">-", "|", "|-"] as [String?] {
            XCTAssertNil(
                CapabilityPurposeLocalization.localizedSummary(
                    for: resource(
                        id: "skill:global:test:invalid",
                        kind: .skill,
                        name: "invalid-source",
                        summary: invalid
                    ),
                    language: .simplifiedChinese,
                    catalog: []
                )
            )
        }
    }

    func testSearchTermsContainNameSourceAndLocalizedPurpose() {
        let sourcePurpose = "Search local assets."
        let entry = CapabilityPurposeLocalizationEntry(
            resourceID: "skill:global:test:search",
            kind: .skill,
            sourceName: "asset-search",
            sourcePurpose: sourcePurpose,
            chinesePurpose: "搜索本地素材。"
        )
        let subject = resource(
            id: entry.resourceID,
            kind: entry.kind,
            name: entry.sourceName,
            summary: sourcePurpose
        )

        XCTAssertEqual(
            CapabilityPurposeLocalization.searchTerms(
                for: subject,
                language: .simplifiedChinese,
                catalog: [entry]
            ),
            [entry.sourceName, sourcePurpose, entry.chinesePurpose]
        )
        XCTAssertEqual(
            CapabilityPurposeLocalization.searchTerms(
                for: subject,
                language: .english,
                catalog: [entry]
            ),
            [entry.sourceName, sourcePurpose, sourcePurpose]
        )
    }

    func testCurrentAgentCatalogIsCompleteAndDeterministic() {
        assertCatalog(kind: .agent, expectedIDs: expectedCurrentAgentIDs)
    }

    func testCurrentCustomSkillCatalogIsComplete() {
        assertCatalog(kind: .skill, expectedIDs: expectedCurrentCustomSkillIDs)
    }

    func testCurrentInstalledSkillCatalogIsComplete() {
        assertCatalog(kind: .skill, expectedIDs: expectedCurrentInstalledSkillIDs)
    }

    func testCurrentCatalogContractIsUniqueAndNonempty() {
        let entries = CapabilityPurposeLocalization.entries
        XCTAssertEqual(entries.count, 176)
        XCTAssertEqual(Set(entries.map(\.resourceID)).count, entries.count)
        XCTAssertTrue(entries.allSatisfy { !$0.resourceID.isEmpty })
        XCTAssertTrue(entries.allSatisfy { !$0.sourceName.isEmpty })
        XCTAssertTrue(entries.allSatisfy { $0.sourcePurposeSignature.count == 64 })
        XCTAssertTrue(entries.allSatisfy { !$0.chinesePurpose.isEmpty })
        XCTAssertTrue(entries.allSatisfy { $0.kind == .agent || $0.kind == .skill })
        XCTAssertTrue(entries.allSatisfy { $0.chinesePurpose.range(of: #"[\u{4E00}-\u{9FFF}]"#, options: .regularExpression) != nil })
    }

    private func assertCatalog(kind: ResourceKind, expectedIDs: Set<String>) {
        let actual = Set(
            CapabilityPurposeLocalization.entries
                .filter { $0.kind == kind && expectedIDs.contains($0.resourceID) }
                .map(\.resourceID)
        )
        XCTAssertEqual(actual, expectedIDs)
        for id in expectedIDs {
            XCTAssertEqual(CapabilityPurposeLocalization.entries.filter { $0.resourceID == id }.count, 1, id)
        }
    }

    private var expectedCurrentAgentIDs: Set<String> {
        ids(#"""
        agent:global:global-agents:005fe8b42f8d78be
        agent:global:global-agents:0f56ad5024229d8c
        agent:global:global-agents:34eb03cdfce4f098
        agent:global:global-agents:36da62306a140d2d
        agent:global:global-agents:38b337fa16919f2f
        agent:global:global-agents:5c33474e3591565b
        agent:global:global-agents:5cd2335f3fc509c7
        agent:global:global-agents:6d95b8b9e7fb3749
        agent:global:global-agents:7bc1b0a338b527af
        agent:global:global-agents:7cba69d1271dd812
        agent:global:global-agents:93170d050e07312f
        agent:global:global-agents:a4809254566eae2b
        agent:global:global-agents:a7376591387f46ff
        agent:global:global-agents:b415f3307d309089
        agent:global:global-agents:b8faa42908c49695
        agent:global:global-agents:be990744a95fa19f
        agent:global:global-agents:e6ec0d0fd8489086
        agent:global:global-agents:fafe06c492e25001
        agent:project:project-03d84e40d3db5911:08bbf322fa31a17a
        agent:project:project-03d84e40d3db5911:18c652ae3cc8e2a4
        agent:project:project-03d84e40d3db5911:1e057b0a2f30fe4b
        agent:project:project-03d84e40d3db5911:2000cead2e389e03
        agent:project:project-03d84e40d3db5911:2eeccea066c83f2d
        agent:project:project-03d84e40d3db5911:348dcefa2e51fd88
        agent:project:project-03d84e40d3db5911:37134f5f15b1b9d4
        agent:project:project-03d84e40d3db5911:48384927b6a7befb
        agent:project:project-03d84e40d3db5911:5c882ed92ad8dda1
        agent:project:project-03d84e40d3db5911:63371b41e762c03d
        agent:project:project-03d84e40d3db5911:6996404c504ac5d4
        agent:project:project-03d84e40d3db5911:72cb6e1280436775
        agent:project:project-03d84e40d3db5911:89edc5fec6e12166
        agent:project:project-03d84e40d3db5911:970b1f0034637442
        agent:project:project-03d84e40d3db5911:a0e1c4c44cbd2b2e
        agent:project:project-03d84e40d3db5911:a19146745655712d
        agent:project:project-03d84e40d3db5911:ac12e189a36dca05
        agent:project:project-03d84e40d3db5911:c6ba3a3145b2e27e
        agent:project:project-03d84e40d3db5911:cb841022077753ee
        agent:project:project-03d84e40d3db5911:ddbe28b7c9e1912f
        agent:project:project-03d84e40d3db5911:dfc049444a2f1682
        agent:project:project-03d84e40d3db5911:f03d50aea19fb5b2
        agent:project:project-b22d22ea4c868e2f:37134f5f15b1b9d4
        agent:project:project-b22d22ea4c868e2f:9c69a7146f37dc11
        agent:project:project-b22d22ea4c868e2f:dfc049444a2f1682
        agent:project:project-b22d22ea4c868e2f:f03d50aea19fb5b2
        agent:project:project-b22d22ea4c868e2f:f56b1820f3ec6e83
        """#)
    }

    private var expectedCurrentCustomSkillIDs: Set<String> {
        ids(#"""
        skill:global:global-skills:1cf31f68ee13014c
        skill:global:global-skills:3e27c7b418697ce4
        skill:global:global-skills:63618a17962140bb
        skill:global:global-skills:75f33d2367bdb1fa
        skill:global:global-skills:a6f8d53089d0d5b4
        skill:global:global-skills:c0f81ed87f0458a5
        skill:global:global-skills:caae29468d7f1d96
        skill:global:global-skills:ea7b964cf6c182c7
        skill:project:project-03d84e40d3db5911:03df2828bb6f74ad
        skill:project:project-03d84e40d3db5911:08cfc5de5d92d50b
        skill:project:project-03d84e40d3db5911:08e0663a223cd716
        skill:project:project-03d84e40d3db5911:131c5b6b59fd5fe1
        skill:project:project-03d84e40d3db5911:153473cf10358dc5
        skill:project:project-03d84e40d3db5911:18a32218e58356c8
        skill:project:project-03d84e40d3db5911:1e73f813ad201cb7
        skill:project:project-03d84e40d3db5911:28da95aa18b79601
        skill:project:project-03d84e40d3db5911:32b6e4d495d458be
        skill:project:project-03d84e40d3db5911:46102678ad809cb7
        skill:project:project-03d84e40d3db5911:504ba03fdb303e05
        skill:project:project-03d84e40d3db5911:5469006bb6356c70
        skill:project:project-03d84e40d3db5911:57f896d25da67644
        skill:project:project-03d84e40d3db5911:6e68bb24f1121cf9
        skill:project:project-03d84e40d3db5911:82a71ba3ec89fa8c
        skill:project:project-03d84e40d3db5911:868344b78464634c
        skill:project:project-03d84e40d3db5911:8b30bc43db9fd7de
        skill:project:project-03d84e40d3db5911:9ae88c0f452c821d
        skill:project:project-03d84e40d3db5911:a5b72480b4b251da
        skill:project:project-03d84e40d3db5911:b4e746e2995858f8
        skill:project:project-03d84e40d3db5911:b5845ad0180f5e15
        skill:project:project-03d84e40d3db5911:bd902cb65cb1ec36
        skill:project:project-03d84e40d3db5911:c10bca8e0c46662c
        skill:project:project-03d84e40d3db5911:c5e3e09fc83f53ba
        skill:project:project-03d84e40d3db5911:c5ec505f1301a952
        skill:project:project-03d84e40d3db5911:c6fd485cc748f3b7
        skill:project:project-03d84e40d3db5911:c83907950e7d0145
        skill:project:project-03d84e40d3db5911:d18eb3eb4870f976
        skill:project:project-03d84e40d3db5911:d1f52728ca7b01cd
        skill:project:project-03d84e40d3db5911:e07f4953d38cc896
        skill:project:project-03d84e40d3db5911:ebf847bc5a254530
        skill:project:project-03d84e40d3db5911:ec2b05657e9b541e
        skill:project:project-03d84e40d3db5911:efc70fe4eecb9b16
        skill:project:project-03d84e40d3db5911:f3fdf927d6a0ec34
        skill:project:project-03d84e40d3db5911:fbf97cd56bc4ec58
        skill:project:project-3305511c4dc8568a:6b73b391233a2df5
        skill:project:project-b22d22ea4c868e2f:13502f1551ed7b54
        skill:project:project-b22d22ea4c868e2f:1c131c4f15363f99
        skill:project:project-b22d22ea4c868e2f:45c27c245fbe7069
        skill:project:project-b22d22ea4c868e2f:56708c02c306583c
        skill:project:project-b22d22ea4c868e2f:8737e9d8fde3aa24
        skill:project:project-b22d22ea4c868e2f:f7cc4e56223d30b4
        """#)
    }

    private var expectedCurrentInstalledSkillIDs: Set<String> {
        ids(#"""
        skill:global:agent-skills:09153b0506ae014c
        skill:global:agent-skills:0d13eb2b5370fbe1
        skill:global:agent-skills:106d720663d556f6
        skill:global:agent-skills:12aac2c6b314206b
        skill:global:agent-skills:12c68c473ebd4036
        skill:global:agent-skills:1456c1fcc466a42d
        skill:global:agent-skills:16260e15cdc96897
        skill:global:agent-skills:1ecc08dcfc180592
        skill:global:agent-skills:25a1edbcab610d18
        skill:global:agent-skills:298b26cf107c1ac4
        skill:global:agent-skills:388997eb9fb90276
        skill:global:agent-skills:3c5775d45dc9111f
        skill:global:agent-skills:45fb4d0930e77027
        skill:global:agent-skills:48dc8dba403945be
        skill:global:agent-skills:52149907e3304bcf
        skill:global:agent-skills:54bdde3cea7ea4e2
        skill:global:agent-skills:61d28027430e81b3
        skill:global:agent-skills:6351d17ab6be2b77
        skill:global:agent-skills:6f09d3fdba9b7f57
        skill:global:agent-skills:72aec36d76171f0e
        skill:global:agent-skills:7405492d00ef5799
        skill:global:agent-skills:745d7d0e33c5846b
        skill:global:agent-skills:7c0de57d0dea1e7d
        skill:global:agent-skills:855abd6d56620ad0
        skill:global:agent-skills:8a358c058705d465
        skill:global:agent-skills:8c24ce0c5a830802
        skill:global:agent-skills:92263610e98122ee
        skill:global:agent-skills:99786c5d7120879f
        skill:global:agent-skills:9b0d641d53faaca2
        skill:global:agent-skills:9c80485595d9e698
        skill:global:agent-skills:a1bab28dbaab8392
        skill:global:agent-skills:a61b81c27ca217d8
        skill:global:agent-skills:ac5bd3039b53dcbe
        skill:global:agent-skills:b233b2aa8aad6340
        skill:global:agent-skills:b8009eff3629c682
        skill:global:agent-skills:ba7a78347ae2415c
        skill:global:agent-skills:c6f4f6cad0da7e73
        skill:global:agent-skills:d4e9328c7627896c
        skill:global:agent-skills:dc77a3c33ca34cd9
        skill:global:agent-skills:ed51a30e335ec0b7
        skill:global:agent-skills:f8c5000c065bfd4d
        skill:global:global-skills:070f347a7750b818
        skill:global:global-skills:073e334d0f6521b4
        skill:global:global-skills:3f04236490192df6
        skill:global:global-skills:81cab9b8d9a6b89d
        skill:global:global-skills:87db48e1e88f6afc
        skill:global:global-skills:91fb01dc3c7f0843
        skill:global:global-skills:9b9b2f63651ddf0d
        skill:global:global-skills:ac2c08e0120713fe
        skill:global:global-skills:c29e732b339c0a3f
        skill:global:global-skills:ccd4f3a344a7bb32
        skill:runtime:077a10dc49b3570d
        skill:runtime:27f857181c51e88b
        skill:runtime:366ceaebe088dc51
        skill:runtime:39858ce1c14896dd
        skill:runtime:428caa78170225b6
        skill:runtime:44eda7665f87b1db
        skill:runtime:46a60f47499c1603
        skill:runtime:67711496298cceef
        skill:runtime:67b5ab0bb2c582c9
        skill:runtime:70bb9b1c64b0ea21
        skill:runtime:717f3b4ea8a37aed
        skill:runtime:75f6094867116fcf
        skill:runtime:79e4c97425e78f31
        skill:runtime:7adc4cc2b8f6d1ef
        skill:runtime:8305ac37928fb98d
        skill:runtime:86cb495908447e73
        skill:runtime:87fe67c23da732d5
        skill:runtime:8e1baebe588dcc9f
        skill:runtime:99def032608da483
        skill:runtime:a20a002e1de8f44b
        skill:runtime:c5a84ad456d92a4f
        skill:runtime:c8cfff8452b41d1f
        skill:runtime:cc1a086c36edf484
        skill:runtime:d2e2476754c03336
        skill:runtime:d4efb3b6331547e7
        skill:runtime:dab9f4f60b411c74
        skill:runtime:db24fcac7b1d88b4
        skill:runtime:e01a6ceeeba9ad76
        skill:runtime:e9e600b6ca29eecf
        skill:runtime:ffab4a8bb71c08fb
        """#)
    }

    private func ids(_ raw: String) -> Set<String> {
        Set(raw.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private func resource(
        id: String,
        kind: ResourceKind,
        name: String,
        summary: String?
    ) -> CapabilityResource {
        CapabilityResource(
            id: id,
            name: name,
            kind: kind,
            status: .success,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: summary,
            sourceRootID: "test",
            relativeSourcePath: nil,
            sourcePathHash: nil,
            lastSeenAt: Date(),
            ownership: kind == .agent ? .userOwned : .installed,
            origin: .local
        )
    }
}
