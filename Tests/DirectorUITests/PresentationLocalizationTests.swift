import XCTest
import Foundation
import DirectorCore
@testable import DirectorUI

/// Presentation contracts for the Tasks, Review, and data/usage surfaces.
/// These tests exercise the same key shapes used by the views while keeping
/// raw source identifiers and evidence outside the localization boundary.
@MainActor
final class PresentationLocalizationTests: XCTestCase {
    func testTimelineStatusAndConfidenceLabelsResolveInBothLanguages() {
        let english = DirectorLocalizer(language: .english)
        let chinese = DirectorLocalizer(language: .simplifiedChinese)

        let status = LocalizedEnumValue(key: InvocationTimelineView.localizationKey(for: InvocationStatus.failed), fallback: "Failed")
        let confidence = LocalizedEnumValue(key: InvocationTimelineView.localizationKey(for: EvidenceConfidence.inferred), fallback: "Inferred")

        XCTAssertEqual(english.enumLabel(status), "Failed")
        XCTAssertEqual(english.enumLabel(confidence), "Inferred")
        XCTAssertEqual(chinese.enumLabel(status), "失败")
        XCTAssertEqual(chinese.enumLabel(confidence), "推断")
    }

    func testReviewRuleSummaryUsesRuleIDAndKeepsRawEvidenceVerbatim() {
        let english = DirectorLocalizer(language: .english)
        let chinese = DirectorLocalizer(language: .simplifiedChinese)
        let rawEvidence = "fixture-root/session.jsonl does not exist"

        XCTAssertEqual(
            english.text("review.rule.rule.missing-source.summary", fallback: "Declared source is missing or unavailable"),
            "Declared source is missing or unavailable"
        )
        XCTAssertEqual(
            chinese.text("review.rule.rule.missing-source.summary", fallback: "Declared source is missing or unavailable"),
            "声明的来源缺失或不可用"
        )
        XCTAssertEqual(chinese.text(rawEvidence, fallback: rawEvidence), rawEvidence)
    }

    func testTaskAndEvidenceFormattingIsLocalizedWithoutChangingRawValues() {
        let english = DirectorLocalizer(language: .english)
        let chinese = DirectorLocalizer(language: .simplifiedChinese)
        let taskID = "session:validation-0"
        let evidence = "agent:validation-global ended with status failed"

        XCTAssertEqual(english.format("Task · %@", fallback: "Task · %@", taskID), "Task · session:validation-0")
        XCTAssertEqual(chinese.format("Task · %@", fallback: "Task · %@", taskID), "任务 · session:validation-0")
        let finding = ReviewFinding(
            id: "finding:raw",
            ruleID: "rule.unmatched-result",
            resourceID: nil,
            sessionID: "session:raw",
            severity: .warning,
            confidence: .exact,
            summary: "Invocation has no matching result",
            evidenceSummary: evidence,
            coverage: .complete,
            createdAt: Date(timeIntervalSince1970: 1_754_000_000),
            remediationStatus: .open
        )
        XCTAssertEqual(ReviewInspector.originalEvidenceText(for: finding), evidence)
    }

    func testTimestampPresentationRetainsTimeInBothLanguages() {
        let date = Date(timeIntervalSince1970: 1_754_000_000)
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        let dateOnlyStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)

        for language in [AppLanguage.english, .simplifiedChinese] {
            let localizer = DirectorLocalizer(language: language)
            XCTAssertFalse(localizer.date(date).isEmpty)
            XCTAssertFalse(localizer.date(date, style: style).isEmpty)
            XCTAssertNotEqual(localizer.date(date), localizer.date(date, style: dateOnlyStyle))
        }
    }

    func testTaskTitleThatMatchesLocalizationKeyRemainsRaw() {
        let task = TaskSummary(
            id: "session:raw-title",
            projectID: nil,
            startedAt: nil,
            endedAt: nil,
            status: .completed,
            coverage: .complete,
            parserVersion: "fixture",
            sourceFileID: "fixture",
            title: "Home"
        )
        XCTAssertEqual(TaskRow(task: task, callCount: 0, failureCount: 0, totalTokens: nil).displayTitle, "Home")
    }

    func testDataStatusCategoriesAndFirstRunCopyResolveInBothLanguages() {
        let english = DirectorLocalizer(language: .english)
        let chinese = DirectorLocalizer(language: .simplifiedChinese)

        XCTAssertEqual(english.text("source.category.skills", fallback: "Skills"), "Skills")
        XCTAssertEqual(chinese.text("source.category.skills", fallback: "Skills"), "Skill")
        XCTAssertEqual(chinese.text("source.category.agents", fallback: "Agents"), "Agent")
        XCTAssertEqual(english.text("source.category.projects", fallback: "Projects"), "Projects")
        XCTAssertEqual(chinese.text("source.category.projects", fallback: "Projects"), "项目")

        let firstRun = "Codex Director runs entirely on this Mac. It reads resources and Session logs read-only and builds a local derived index; nothing is uploaded, and no prompt, response, argument, or output text is stored."
        XCTAssertEqual(english.text(firstRun, fallback: firstRun), firstRun)
        XCTAssertTrue(chinese.text(firstRun, fallback: firstRun).contains("会话"))
    }

    func testLanguageSwitchPreservesCapabilityTerminologyAndSourceIdentity() {
        let store = AppLanguageStore(memoryLanguage: .english)
        let taskID = "session:validation-0"
        let resourceID = "agent:validation-global"
        let kind = ResourceKind.mcp
        let scope = ResourceScope.project
        let labels: [(ResourceKind, String, String)] = [
            (.agent, "Agent", "Agent"),
            (.skill, "Skill", "Skill"),
            (.mcp, "MCP", "MCP"),
            (.workflow, "Workflow", "工作流"),
            (.plugin, "Plugin", "插件"),
            (.tool, "Tool", "工具")
        ]

        for language in [AppLanguage.english, .simplifiedChinese] {
            store.setLanguage(language)
            for (kind, english, chinese) in labels {
                let value = LocalizedEnumValue(key: "enum.\(kind.rawValue)", fallback: english)
                XCTAssertEqual(store.localizer.enumLabel(value), language == .english ? english : chinese)
            }
            XCTAssertEqual(kind.rawValue, "mcp")
            XCTAssertEqual(scope.rawValue, "project")
            XCTAssertEqual(taskID, "session:validation-0")
            XCTAssertEqual(resourceID, "agent:validation-global")
        }
    }

    func testModelPlaceholderLocalizationUsesIdentityMetadataNotDisplayNameCollision() {
        let unknown = ModelTokenRow(
            modelID: nil,
            modelName: "a raw model name",
            totalTokens: 1,
            taskCount: 1,
            coverage: .complete,
            attributionConfidence: .unknown
        )
        let redacted = ModelTokenRow(
            modelID: ModelIdentity.redactedID,
            modelName: "a raw redacted label",
            totalTokens: 1,
            taskCount: 1,
            coverage: .partial,
            attributionConfidence: .unknown
        )
        let collision = ModelTokenRow(
            modelID: "model:real",
            modelName: "Unknown model",
            totalTokens: 1,
            taskCount: 1,
            coverage: .complete,
            attributionConfidence: .exact
        )

        let english = DirectorLocalizer(language: .english)
        let chinese = DirectorLocalizer(language: .simplifiedChinese)
        XCTAssertEqual(TaskTokenBreakdownView.modelDisplayName(unknown, localizer: english), "Unknown model")
        XCTAssertEqual(TaskTokenBreakdownView.modelDisplayName(unknown, localizer: chinese), "未知模型")
        XCTAssertEqual(TaskTokenBreakdownView.modelDisplayName(redacted, localizer: chinese), "已隐藏模型")
        XCTAssertEqual(TaskTokenBreakdownView.modelDisplayName(collision, localizer: chinese), "Unknown model")
    }

    func testAllowancePlaceholderLocalizationDoesNotTranslateRawSourceNameCollision() {
        let english = DirectorLocalizer(language: .english)
        let chinese = DirectorLocalizer(language: .simplifiedChinese)
        XCTAssertEqual(
            AllowanceSummaryView.displaySourceName("Unknown limit source", isPlaceholder: true, localizer: chinese),
            "未知额度来源"
        )
        XCTAssertEqual(
            AllowanceSummaryView.displaySourceName("Unknown limit source", isPlaceholder: false, localizer: chinese),
            "Unknown limit source"
        )
        XCTAssertEqual(
            AllowanceSummaryView.displaySourceName("provider:literal", isPlaceholder: false, localizer: english),
            "provider:literal"
        )
    }

    func testVisibleCountsUsePluralResourcesInBothLanguages() {
        let english = DirectorLocalizer(language: .english)
        let chinese = DirectorLocalizer(language: .simplifiedChinese)

        XCTAssertEqual(english.plural("task.callCount", count: 1, fallback: "%lld calls"), "1 call")
        XCTAssertEqual(english.plural("task.callCount", count: 2, fallback: "%lld calls"), "2 calls")
        XCTAssertEqual(chinese.plural("task.callCount", count: 1, fallback: "%lld calls"), "1 个调用")
        XCTAssertEqual(chinese.plural("task.callCount", count: 2, fallback: "%lld calls"), "2 个调用")
        XCTAssertEqual(english.plural("data.sessionCount", count: 1, fallback: "%lld sessions"), "1 session")
        XCTAssertEqual(chinese.plural("data.sessionCount", count: 2, fallback: "%lld sessions"), "2 个会话")
    }

    func testRelationshipLabelsLocalizeWhileIdentifiersRemainUnchanged() {
        let english = DirectorLocalizer(language: .english)
        let chinese = DirectorLocalizer(language: .simplifiedChinese)
        let sourceID = "agent:validation-global"
        let targetID = "skill:validation"

        XCTAssertEqual(english.text("relation.kind.uses", fallback: "Uses"), "Uses")
        XCTAssertEqual(chinese.text("relation.kind.uses", fallback: "Uses"), "使用")
        XCTAssertEqual(
            chinese.format("%@ %@ %@, confidence %@", fallback: "%@ %@ %@, confidence %@", sourceID, chinese.text("relation.kind.uses", fallback: "Uses"), targetID, chinese.enumLabel(.init(key: "confidence.inferred", fallback: "Inferred"))),
            "agent:validation-global 使用 skill:validation，置信度：推断"
        )
        XCTAssertEqual(chinese.text("Redacted", fallback: "Redacted"), "已隐藏")
    }
}
