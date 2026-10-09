import XCTest
@testable import DirectorCore

final class TransientToolInputTests: XCTestCase {
    func testReadSurvivesOutputCallback() {
        let input = """
        const results = await Promise.allSettled([
          tools.exec_command({cmd: 'cat sample-agent/agent.md'})
        ]);
        results.forEach((result, index) => text({index, ...result}));
        """

        XCTAssertEqual(TransientToolInput.literalCalls(input)?.map(\.name), ["exec_command"])
    }

    func testReadSurvivesCatalogFormatting() {
        let input = """
        text(await tools.exec_command({cmd: 'cat sample-skill/SKILL.md'}));
        text(ALL_TOOLS.filter(x => /sample/.test(x.name)).map(x => ({name:x.name})));
        """

        XCTAssertEqual(TransientToolInput.literalCalls(input)?.count, 1)
    }

    func testStrictAllToolsCatalogOutputBeforeBatchKeepsLaterLiteralReads() {
        let input = """
        text(ALL_TOOLS.filter(x => /sample/.test(x.name + ' ' + x.description)).map(x => ({name: x.name, description: x.description.slice(0, 120)})));
        const results = await Promise.allSettled([
          tools.exec_command({cmd: 'cat sample-a/agent.md'}),
          tools.exec_command({cmd: 'cat sample-b/agent.md'}),
          tools.exec_command({cmd: 'cat sample-c/agent.md'}),
          tools.exec_command({cmd: 'cat sample-d/agent.md'})
        ]);
        results.forEach((result, index) => text({index, ...result}));
        """

        let extraction = TransientToolInput.extractLiteralCalls(input)
        XCTAssertEqual(extraction.calls.map(\.name), Array(repeating: "exec_command", count: 4))
        XCTAssertTrue(extraction.wasLimited)
    }

    func testStrictAllToolsCatalogOutputBeforeDirectReadsKeepsLaterLiterals() {
        let input = """
        text(ALL_TOOLS.filter(x => /sample(one|two|three)/.test(x.name)));
        text(await tools.exec_command({cmd: 'cat sample-a/SKILL.md', max_output_tokens: 5000}));
        text(await tools.exec_command({cmd: 'cat sample-b/SKILL.md', max_output_tokens: 5000}));
        text(await tools.exec_command({cmd: 'cat sample-c/SKILL.md', max_output_tokens: 5000}));
        """

        let extraction = TransientToolInput.extractLiteralCalls(input)
        XCTAssertEqual(extraction.calls.map(\.name), Array(repeating: "exec_command", count: 3))
        XCTAssertTrue(extraction.wasLimited)
    }

    func testAllToolsCatalogWhitelistRejectsRebindingAndExecutableCallbacks() {
        let suffix = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        let inputs = [
            "const ALL_TOOLS = fake; text(ALL_TOOLS.filter(x => /sample/.test(x.name))); \(suffix)",
            "const Promise = fake; text(ALL_TOOLS.filter(x => /sample/.test(x.name))); \(suffix)",
            "const text = fake; text(ALL_TOOLS.filter(x => /sample/.test(x.name))); \(suffix)",
            "text(ALL_TOOLS.filter(x => tools.exec_command({cmd: 'cat hidden/SKILL.md'}))); \(suffix)",
            "text(ALL_TOOLS.filter(x => unknown(x.name))); \(suffix)",
            "text(ALL_TOOLS.filter(x => (Promise.all = fake, /sample/.test(x.name)))); \(suffix)",
            "text(unknown()); \(suffix)",
        ]

        for input in inputs {
            let extraction = TransientToolInput.extractLiteralCalls(input)
            XCTAssertTrue(extraction.calls.isEmpty, input)
            XCTAssertTrue(extraction.wasLimited, input)
        }
    }

    func testAllToolsCatalogStateMachineRejectsMalformedAndExecutableNearMisses() {
        let suffix = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        let inputs = [
            "text(ALL_TOOLS.filter(x => /[z-a]/.test(x.name))); \(suffix)",
            "text(ALL_TOOLS.filter(x => /sample/.test(x.name) + test)); \(suffix)",
            "text(ALL_TOOLS.filter(x => /sample/.test(x.name) + x.name++)); \(suffix)",
            "text(ALL_TOOLS.filter(x => /sample/.test(x.name)).map(x => ({name: x.name, description: x.description.slice(0, test)}))); \(suffix)",
            "text(ALL_TOOLS.filter(x => /sample/.test(x.name)).map(x => ({name: x.name description: x.description}))); \(suffix)",
        ]

        for input in inputs {
            let extraction = TransientToolInput.extractLiteralCalls(input)
            XCTAssertTrue(extraction.calls.isEmpty, input)
            XCTAssertTrue(extraction.wasLimited, input)
        }

        let positive = "text(ALL_TOOLS.filter(item => /sample(one|two)/.test(item.name + ' ' + item.description)).map(item => ({name: item.name, description: item.description.slice(0, 120)}))); \(suffix)"
        let extraction = TransientToolInput.extractLiteralCalls(positive)
        XCTAssertEqual(extraction.calls.map(\.name), ["exec_command"])
        XCTAssertTrue(extraction.wasLimited)
    }

    func testInterpolatedAndTaggedTemplatesAreUnknownExecutionBarriers() {
        let suffix = "await tools.exec_command({cmd: 'cat later/SKILL.md'});"
        let inputs = [
            "`${unknown()}`; \(suffix)",
            "`${tools.exec_command({cmd: 'cat hidden/SKILL.md'})}`; \(suffix)",
            "unknown`literal`; \(suffix)",
        ]

        for input in inputs {
            let extraction = TransientToolInput.extractLiteralCalls(input)
            XCTAssertTrue(extraction.calls.isEmpty, input)
            XCTAssertTrue(extraction.wasLimited, input)
        }

        let prefix = "await tools.exec_command({cmd: 'cat prior/SKILL.md'}); `${unknown()}`; \(suffix)"
        let extraction = TransientToolInput.extractLiteralCalls(prefix)
        XCTAssertTrue(extraction.calls.isEmpty)
        XCTAssertTrue(extraction.wasLimited)

        let taggedAfterPrefix = TransientToolInput.extractLiteralCalls(
            "await tools.exec_command({cmd: 'cat prior/SKILL.md'}); unknown`literal`; \(suffix)"
        )
        XCTAssertEqual(taggedAfterPrefix.calls.map(\.name), ["exec_command"])
        XCTAssertTrue(taggedAfterPrefix.wasLimited)

        let literal = "`plain literal`; \(suffix)"
        XCTAssertEqual(TransientToolInput.extractLiteralCalls(literal).calls.map(\.name), ["exec_command"])
    }

    func testInvalidIdentifierFormsRejectWholeWrapperBeforeOrAfterRead() {
        let read = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        let invalid = [
            "const 1 = missingValue;",
            "const if = missingValue;",
            "for (const 1 of result.output) { text(1); }",
            "results.forEach((1) => text(1));",
            "results.forEach((item, item) => text(item));",
            "1foo;",
            "default;",
            "new;",
            "this = missingValue;",
            "result.1;",
            "result.1 = missingValue;",
            "result.1();",
        ]

        for statement in invalid {
            for input in ["\(statement) \(read)", "\(read) \(statement)"] {
                let extraction = TransientToolInput.extractLiteralCalls(input)
                XCTAssertTrue(extraction.calls.isEmpty, input)
                XCTAssertTrue(extraction.wasLimited, input)
            }
        }

        for barrier in ["const value_1$ = missingValue;", "result.default;", "result.default();"] {
            let extraction = TransientToolInput.extractLiteralCalls("\(read) \(barrier)")
            XCTAssertEqual(extraction.calls.map(\.name), ["exec_command"], barrier)
            XCTAssertTrue(extraction.wasLimited, barrier)
        }
    }

    func testRawNewlineInQuotedStringRejectsWholeWrapperButEscapedNewlineRemainsValid() {
        let read = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        for quote in ["'", "\""] {
            let malformed = "text(\(quote)broken\nstring\(quote));"
            for input in ["\(malformed) \(read)", "\(read) \(malformed)"] {
                let extraction = TransientToolInput.extractLiteralCalls(input)
                XCTAssertTrue(extraction.calls.isEmpty, input)
                XCTAssertTrue(extraction.wasLimited, input)
            }
        }

        let escaped = TransientToolInput.extractLiteralCalls("text('line\\nfeed'); \(read)")
        XCTAssertEqual(escaped.calls.map(\.name), ["exec_command"])
        XCTAssertFalse(escaped.wasLimited)
    }

    func testInterpolatedTemplateAndInvalidToolObjectSyntaxRejectWholeWrapper() {
        let read = "await tools.exec_command({cmd: 'cat prior/SKILL.md'});"
        let invalid = [
            "`${1 = 2}`;",
            "await tools.exec_command({cmd: `${1 = 2}`});",
            "await tools.exec_command({cmd: 'cat sample/SKILL.md', timeout: @});",
            "await tools.exec_command({cmd: @});",
            "await Promise.allSettled([tools.exec_command({cmd: 'cat sample/SKILL.md'}), tools.exec_command({cmd: 'cat other/SKILL.md', timeout: @})]);",
        ]

        for statement in invalid {
            for input in [statement, "\(read) \(statement)"] {
                let extraction = TransientToolInput.extractLiteralCalls(input)
                XCTAssertTrue(extraction.calls.isEmpty, input)
                XCTAssertTrue(extraction.wasLimited, input)
            }
        }

        let validDynamic = TransientToolInput.extractLiteralCalls(
            "await tools.exec_command({cmd: 'cat sample/SKILL.md', timeout: dynamicTimeout});"
        )
        XCTAssertTrue(validDynamic.calls.isEmpty)
        XCTAssertTrue(validDynamic.wasLimited)

        let priorThenDynamic = TransientToolInput.extractLiteralCalls(
            "\(read) await tools.exec_command({cmd: 'cat sample/SKILL.md', timeout: unknownWork()});"
        )
        XCTAssertEqual(priorThenDynamic.calls.map(\.name), ["exec_command"])
        XCTAssertTrue(priorThenDynamic.wasLimited)
    }

    func testStrictIdentifierBindingAndMutationRulesRejectWholeWrapper() {
        let read = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        let invalid = [
            "const value = 1; const value = 2;",
            "let value = 1; const value = 2;",
            "const eval = missingValue;",
            "const arguments = missingValue;",
            "eval = missingValue;",
            "arguments++;",
            "delete value;",
        ]

        for statement in invalid {
            for input in ["\(statement) \(read)", "\(read) \(statement)"] {
                let extraction = TransientToolInput.extractLiteralCalls(input)
                XCTAssertTrue(extraction.calls.isEmpty, input)
                XCTAssertTrue(extraction.wasLimited, input)
            }
        }

        for barrier in ["delete value.member;", "delete value['member'];"] {
            let extraction = TransientToolInput.extractLiteralCalls("\(read) \(barrier)")
            XCTAssertEqual(extraction.calls.map(\.name), ["exec_command"], barrier)
            XCTAssertTrue(extraction.wasLimited, barrier)
        }
    }

    func testOnlyFiniteASCIIDecimalIntegersAreAdmitted() {
        let read = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        let invalid = [
            "012;",
            "١;",
            "text(ALL_TOOLS.filter(x => /sample/.test(x.name)).map(x => ({name: x.name, description: x.description.slice(00, 120)})));",
            "text(ALL_TOOLS.filter(x => /sample/.test(x.name)).map(x => ({name: x.name, description: x.description.slice(٠, 120)})));",
        ]

        for statement in invalid {
            for input in ["\(statement) \(read)", "\(read) \(statement)"] {
                let extraction = TransientToolInput.extractLiteralCalls(input)
                XCTAssertTrue(extraction.calls.isEmpty, input)
                XCTAssertTrue(extraction.wasLimited, input)
            }
        }

        let valid = TransientToolInput.extractLiteralCalls(
            "0; text(ALL_TOOLS.filter(x => /sample/.test(x.name)).map(x => ({name: x.name, description: x.description.slice(0, 120)}))); \(read)"
        )
        XCTAssertEqual(valid.calls.map(\.name), ["exec_command"])
        XCTAssertTrue(valid.wasLimited)
    }

    func testUnverifiedTemplateEscapesRejectWholeWrapper() {
        let read = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        for statement in ["`bad\\xZ`;", "tag`bad\\xZ`;", "`line\\n`;" ] {
            for input in ["\(statement) \(read)", "\(read) \(statement)"] {
                let extraction = TransientToolInput.extractLiteralCalls(input)
                XCTAssertTrue(extraction.calls.isEmpty, input)
                XCTAssertTrue(extraction.wasLimited, input)
            }
        }

        let plain = TransientToolInput.extractLiteralCalls("`plain literal`; \(read)")
        XCTAssertEqual(plain.calls.map(\.name), ["exec_command"])
        XCTAssertFalse(plain.wasLimited)
    }

    func testOperatorsAndLineTerminatorsCannotBeRecombined() {
        let read = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        let invalid = [
            "throw\nmissingValue;",
            "result\n++;",
            "result + = 1;",
            "result +/*split*/= 1;",
            "result + +;",
            "result +/*split*/+;",
        ]
        for statement in invalid {
            for input in ["\(statement) \(read)", "\(read) \(statement)"] {
                let extraction = TransientToolInput.extractLiteralCalls(input)
                XCTAssertTrue(extraction.calls.isEmpty, input)
                XCTAssertTrue(extraction.wasLimited, input)
            }
        }

        for separator in ["\u{2028}", "\u{2029}"] {
            let input = "\(read) result\(separator)++;"
            let extraction = TransientToolInput.extractLiteralCalls(input)
            XCTAssertTrue(extraction.calls.isEmpty, input)
            XCTAssertTrue(extraction.wasLimited, input)

            let quoted = TransientToolInput.extractLiteralCalls("text('left\(separator)right'); \(read)")
            XCTAssertEqual(quoted.calls.map(\.name), ["exec_command"], input)
            XCTAssertFalse(quoted.wasLimited, input)
        }
    }

    func testToolObjectCommaProtoAndDynamicFieldRules() {
        let read = "await tools.exec_command({cmd: 'cat prior/SKILL.md'});"
        let invalid = [
            "await tools.exec_command({cmd: 'cat sample/SKILL.md',,});",
            "await tools.exec_command({,cmd: 'cat sample/SKILL.md'});",
            "await tools.exec_command({default});",
            "await tools.exec_command({__proto__: 'a', __proto__: 'b', cmd: 'cat sample/SKILL.md'});",
        ]
        for statement in invalid {
            for input in [statement, "\(read) \(statement)"] {
                let extraction = TransientToolInput.extractLiteralCalls(input)
                XCTAssertTrue(extraction.calls.isEmpty, input)
                XCTAssertTrue(extraction.wasLimited, input)
            }
        }

        for dynamic in [
            "await tools.exec_command({cmd: 'cat sample/SKILL.md', ...options});",
            "await tools.exec_command({cmd: 'cat sample/SKILL.md', [optionName]: optionValue});",
            "await tools.exec_command({cmd: 'first', cmd: 'second'});",
        ] {
            let direct = TransientToolInput.extractLiteralCalls(dynamic)
            XCTAssertTrue(direct.calls.isEmpty, dynamic)
            XCTAssertTrue(direct.wasLimited, dynamic)
            let after = TransientToolInput.extractLiteralCalls("\(read) \(dynamic)")
            XCTAssertEqual(after.calls.map(\.name), ["exec_command"], dynamic)
            XCTAssertTrue(after.wasLimited, dynamic)
        }

        let trailingComma = TransientToolInput.extractLiteralCalls(
            "await tools.exec_command({cmd: 'cat sample/SKILL.md',});"
        )
        XCTAssertEqual(trailingComma.calls.map(\.name), ["exec_command"])
        XCTAssertFalse(trailingComma.wasLimited)
    }

    func testDuplicateProtoSetterInOutputObjectRejectsWholeWrapper() {
        let read = "await tools.exec_command({cmd: 'cat prior/SKILL.md'});"
        let invalid = "results.forEach((result) => text({__proto__: result, __proto__: result}));"
        for input in ["\(invalid) \(read)", "\(read) \(invalid)"] {
            let extraction = TransientToolInput.extractLiteralCalls(input)
            XCTAssertTrue(extraction.calls.isEmpty, input)
            XCTAssertTrue(extraction.wasLimited, input)
        }
    }

    func testIndexedOutputForLoopIsAValidatedBarrierAfterLiteralBatch() {
        let input = """
        const results = await Promise.allSettled([
          tools.exec_command({cmd: 'cat sample-a/SKILL.md'}),
          tools.exec_command({cmd: 'cat sample-b/SKILL.md'}),
          tools.exec_command({cmd: 'cat sample-c/SKILL.md'}),
          tools.exec_command({cmd: 'cat sample-d/SKILL.md'})
        ]);
        for (let i = 0; i < results.length; i++) text({i, v: results[i]});
        """

        let extraction = TransientToolInput.extractLiteralCalls(input)
        XCTAssertEqual(extraction.calls.map(\.name), Array(repeating: "exec_command", count: 4))
        XCTAssertTrue(extraction.wasLimited)
    }

    func testUnknownTopLevelStatementsStopTheAllowlistedDispatcher() {
        let suffix = "await tools.exec_command({cmd: 'cat later/SKILL.md'});"
        let inputs = [
            "text(missingValue); \(suffix)",
            "text(missingValue.name); \(suffix)",
            "missingValue; \(suffix)",
            "const value = missingValue; \(suffix)",
            "1 = 2; \(suffix)",
        ]

        for input in inputs {
            let extraction = TransientToolInput.extractLiteralCalls(input)
            XCTAssertTrue(extraction.calls.isEmpty, input)
            XCTAssertTrue(extraction.wasLimited, input)
        }

        let prefix = "await tools.exec_command({cmd: 'cat prior/SKILL.md'}); text(missingValue); \(suffix)"
        let extraction = TransientToolInput.extractLiteralCalls(prefix)
        XCTAssertEqual(extraction.calls.map(\.name), ["exec_command"])
        XCTAssertTrue(extraction.wasLimited)
    }

    func testMalformedTopLevelStatementRejectsWholeWrapperBeforeOrAfterRead() {
        let read = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        for malformed in ["1 = 2;", "const = 1;", "text(,);", "@;"] {
            for input in ["\(malformed) \(read)", "\(read) \(malformed)"] {
                let extraction = TransientToolInput.extractLiteralCalls(input)
                XCTAssertTrue(extraction.calls.isEmpty, input)
                XCTAssertTrue(extraction.wasLimited, input)
            }
        }

        for input in [
            "\(read) unknownWork(); @;",
            "unknownWork(); @; \(read)",
        ] {
            let extraction = TransientToolInput.extractLiteralCalls(input)
            XCTAssertTrue(extraction.calls.isEmpty, input)
            XCTAssertTrue(extraction.wasLimited, input)
        }
    }

    func testSyntacticallyValidUnknownBarrierPreservesOnlyPriorProof() {
        let read = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        let barriers = [
            "undefined();",
            "await unknownWork;",
            "text(missingValue.name);",
            "const value = missingValue;",
            "results.forEach((result, index) => text({index, ...result}));",
            "for (const item of result.output) { text(item); }",
        ]

        for barrier in barriers {
            let before = TransientToolInput.extractLiteralCalls("\(barrier) \(read)")
            XCTAssertTrue(before.calls.isEmpty, barrier)
            XCTAssertTrue(before.wasLimited, barrier)

            let after = TransientToolInput.extractLiteralCalls("\(read) \(barrier)")
            XCTAssertEqual(after.calls.map(\.name), ["exec_command"], barrier)
            XCTAssertTrue(after.wasLimited, barrier)
        }
    }

    func testExtractionValuesSurviveTheInternalAutoreleasePool() throws {
        let extraction = TransientToolInput.extractLiteralCalls(
            "await tools.exec_command({cmd: 'cat sample/SKILL.md', workdir: '/fixture/project'});"
        )

        XCTAssertFalse(extraction.wasLimited)
        let call = try XCTUnwrap(extraction.calls.first)
        XCTAssertEqual(call.name, "exec_command")
        XCTAssertEqual(extraction.calls.count, 1)
        switch call.resultBinding {
        case .direct:
            break
        case .aggregate, .unbound:
            XCTFail("direct result binding must survive the pool boundary")
        }
        let arguments = try XCTUnwrap(TransientToolInput.arguments(call.input))
        XCTAssertEqual(arguments["cmd"] as? String, "cat sample/SKILL.md")
        XCTAssertEqual(arguments["workdir"] as? String, "/fixture/project")
    }

    func testInvalidRegexSyntaxOrFlagsRejectTheWholeWrapper() {
        let inputs = [
            "text(ALL_TOOLS.filter(x => /(/.test(x.name))); await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "text(ALL_TOOLS.filter(x => /sample/zz.test(x.name))); await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "await tools.exec_command({cmd: 'cat sample/SKILL.md'}); text(/sample/ii);",
            "text(ALL_TOOLS.filter(x => /sample**/.test(x.name))); await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "text(ALL_TOOLS.filter(x => /sample{2,1}/.test(x.name))); await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "text(ALL_TOOLS.filter(x => /sample$more/.test(x.name))); await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "text(ALL_TOOLS.filter(x => /sample$$/.test(x.name))); await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "text(ALL_TOOLS.filter(x => /^sample^/.test(x.name))); await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "text(ALL_TOOLS.filter(x => /$sample/.test(x.name))); await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
        ]
        for input in inputs {
            let extraction = TransientToolInput.extractLiteralCalls(input)
            XCTAssertTrue(extraction.calls.isEmpty, input)
            XCTAssertTrue(extraction.wasLimited, input)
        }

        let positive = TransientToolInput.extractLiteralCalls(
            "text(ALL_TOOLS.filter(x => /sample(one|two)-agent_2/.test(x.name))); await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        )
        XCTAssertEqual(positive.calls.map(\.name), ["exec_command"])
        XCTAssertTrue(positive.wasLimited)

        let anchored = TransientToolInput.extractLiteralCalls(
            "text(ALL_TOOLS.filter(x => /sample_(one|two|three)$/.test(x.name))); text(await tools.exec_command({cmd: 'cat sample-a/SKILL.md'})); text(await tools.exec_command({cmd: 'cat sample-b/SKILL.md'})); text(await tools.exec_command({cmd: 'cat sample-c/SKILL.md'}));"
        )
        XCTAssertEqual(anchored.calls.map(\.name), Array(repeating: "exec_command", count: 3))
        XCTAssertTrue(anchored.wasLimited)
    }

    func testReadSurvivesOutputOnlyLoop() {
        let input = """
        const result = await tools.exec_command({cmd: 'cat sample-skill/SKILL.md'});
        for (const item of result.output) { text(item); }
        """

        XCTAssertEqual(TransientToolInput.literalCalls(input)?.map(\.name), ["exec_command"])
    }

    func testDynamicSiblingStopsAtTheLastPreviouslyProvenCall() {
        let input = """
        const results = await Promise.all([
          tools.exec_command({cmd: 'cat sample-a/SKILL.md'}),
          tools.read_file({path: 'sample-b/SKILL.md', limit: dynamicLimit}),
          tools.exec_command({cmd: dynamicCommand})
        ]);
        """

        let calls = TransientToolInput.literalCalls(input)
        XCTAssertEqual(calls?.map(\.name), ["exec_command"])
    }

    func testDynamicToolBarrierPreservesOnlyProvenEarlierCalls() {
        let input = """
        await tools.exec_command({cmd: 'cat sample-a/SKILL.md'});
        await tools.exec_command({cmd: dynamicCommand});
        await tools.exec_command({cmd: 'cat sample-b/SKILL.md'});
        """

        let extraction = TransientToolInput.extractLiteralCalls(input)
        XCTAssertEqual(extraction.calls.map(\.name), ["exec_command"])
        XCTAssertTrue(extraction.wasLimited)
    }

    func testDirectReadRepeatedReadAndLiteralWorkdirRemainLiteral() throws {
        let input = """
        text(await tools.exec_command({cmd: 'cat sample/SKILL.md', workdir: '/fixture/project'}));
        await tools.exec_command({cmd: 'cat sample/SKILL.md'});
        """

        let calls = try XCTUnwrap(TransientToolInput.literalCalls(input))
        XCTAssertEqual(calls.map(\.name), ["exec_command", "exec_command"])
        let arguments = try XCTUnwrap(TransientToolInput.arguments(calls[0].input))
        XCTAssertEqual(arguments["workdir"] as? String, "/fixture/project")
    }

    func testDeferredConditionalLoopAndObjectMethodCallsAreIgnored() {
        let inputs = [
            "const fn = () => tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "items.forEach(item => tools.exec_command({cmd: 'cat sample/SKILL.md'}));",
            "const fn = (value = tools.exec_command({cmd: 'cat sample/SKILL.md'})) => value;",
            "items.map((value = tools.exec_command({cmd: 'cat sample/SKILL.md'})) => value);",
            "if (enabled) { tools.exec_command({cmd: 'cat sample/SKILL.md'}); }",
            "while (enabled) tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "for (const item of items) { tools.exec_command({cmd: 'cat sample/SKILL.md'}); }",
            "const object = { read() { tools.exec_command({cmd: 'cat sample/SKILL.md'}); } };",
        ]

        for input in inputs {
            XCTAssertTrue(TransientToolInput.literalCalls(input)?.isEmpty ?? true, input)
        }
    }

    func testCommentsStringsRegexTemplatesAndComputedCallsAreIgnored() {
        let inputs = [
            "// tools.exec_command({cmd: 'cat sample/SKILL.md'})",
            "const value = \"tools.exec_command({cmd: 'cat sample/SKILL.md'})\";",
            "const pattern = /tools\\.exec_command\\(.*sample\\/SKILL\\.md/;",
            "const value = `tools.exec_command({cmd: 'cat ${path}/SKILL.md'})`;",
            "tools[name]({cmd: 'cat sample/SKILL.md'});",
            "tools.exec_command({cmd: `cat ${path}/SKILL.md`});",
            "tools.exec_command({cmd: 'cat sample/SKILL.md' + suffix});",
        ]

        for input in inputs {
            XCTAssertTrue(TransientToolInput.literalCalls(input)?.isEmpty ?? true, input)
        }
    }

    func testUnresolvedControlFlowBeforeCallDoesNotGuessExecution() {
        let inputs = [
            "enabled && tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "enabled ? tools.exec_command({cmd: 'cat sample/SKILL.md'}) : text('skip');",
            "enabled || tools.exec_command({cmd: 'cat sample/SKILL.md'});",
        ]

        for input in inputs {
            XCTAssertTrue(TransientToolInput.literalCalls(input)?.isEmpty ?? true, input)
        }
    }

    func testToolsShadowingReassignmentAndAbruptExitBlockLaterCalls() {
        let inputs = [
            "const tools = fakeTools; await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "let tools = fakeTools; await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "tools = fakeTools; await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "tools.exec_command = fakeCommand; await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "tools['exec_command'] = fakeCommand; await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "exit(); await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "throw failure; await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
        ]

        for input in inputs {
            XCTAssertTrue(TransientToolInput.extractLiteralCalls(input).calls.isEmpty, input)
        }
    }

    func testHoistedOrLexicalToolsBindingRejectsEarlierCanonicalReads() {
        let read = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        for declaration in [
            "const tools = fakeTools;",
            "let tools = fakeTools;",
            "var tools = fakeTools;",
            "const {tools} = fakeTools;",
            "let [tools] = fakeTools;",
        ] {
            let extraction = TransientToolInput.extractLiteralCalls("\(read) \(declaration)")
            XCTAssertTrue(extraction.calls.isEmpty, declaration)
            XCTAssertTrue(extraction.wasLimited, declaration)
        }


        for keyword in ["const", "var"] {
            let batchThenPromise = """
            const results = await Promise.allSettled([tools.exec_command({cmd: 'cat sample/SKILL.md'})]);
            \(keyword) Promise = fakePromise;
            """
            XCTAssertTrue(TransientToolInput.extractLiteralCalls(batchThenPromise).calls.isEmpty, keyword)

            let outputThenText = """
            text(await tools.exec_command({cmd: 'cat sample/SKILL.md'}));
            \(keyword) text = fakeText;
            """
            XCTAssertTrue(TransientToolInput.extractLiteralCalls(outputThenText).calls.isEmpty, keyword)

            let catalogThenAllTools = """
            text(ALL_TOOLS.filter(item => /sample/.test(item.name)));
            await tools.exec_command({cmd: 'cat sample/SKILL.md'});
            \(keyword) ALL_TOOLS = fakeCatalog;
            """
            XCTAssertTrue(TransientToolInput.extractLiteralCalls(catalogThenAllTools).calls.isEmpty, keyword)
        }

        let callbackLocal = """
        const results = await Promise.allSettled([tools.exec_command({cmd: 'cat sample/SKILL.md'})]);
        results.forEach((tools) => text(tools));
        """
        let callbackExtraction = TransientToolInput.extractLiteralCalls(callbackLocal)
        XCTAssertEqual(callbackExtraction.calls.map(\.name), ["exec_command"])
        XCTAssertTrue(callbackExtraction.wasLimited)
    }

    func testObjectDestructuringDeclarationOfToolsBlocksLaterBridgeCalls() {
        let extraction = TransientToolInput.extractLiteralCalls(
            "const {tools} = fake; await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        )
        XCTAssertTrue(extraction.calls.isEmpty)
        XCTAssertTrue(extraction.wasLimited)
    }

    func testArrayDestructuringDeclarationOfToolsBlocksLaterBridgeCalls() {
        let extraction = TransientToolInput.extractLiteralCalls(
            "const [tools] = fake; await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        )
        XCTAssertTrue(extraction.calls.isEmpty)
        XCTAssertTrue(extraction.wasLimited)
    }

    func testDestructuringAssignmentOfToolsBlocksLaterBridgeCalls() {
        let extraction = TransientToolInput.extractLiteralCalls(
            "({tools} = fake); await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        )
        XCTAssertTrue(extraction.calls.isEmpty)
        XCTAssertTrue(extraction.wasLimited)
    }

    func testCompoundMemberAssignmentBlocksLaterBridgeCallsButKeepsPriorProof() {
        for assignment in ["??=", "||=", "&&=", "+=", "-=", "*=", "%=", "&=", "|=", "^=", "<<=", ">>=", ">>>="] {
            let noPriorProof = TransientToolInput.extractLiteralCalls(
                "tools.exec_command \(assignment) fake; await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
            )
            XCTAssertTrue(noPriorProof.calls.isEmpty, assignment)
            XCTAssertTrue(noPriorProof.wasLimited, assignment)
        }

        let computedMember = TransientToolInput.extractLiteralCalls(
            "tools[memberName] ??= fake; await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        )
        XCTAssertTrue(computedMember.calls.isEmpty)
        XCTAssertTrue(computedMember.wasLimited)

        let priorProof = TransientToolInput.extractLiteralCalls("""
        await tools.exec_command({cmd: 'cat sample-a/SKILL.md'});
        tools.exec_command ??= fake;
        await tools.exec_command({cmd: 'cat sample-b/SKILL.md'});
        """)
        XCTAssertEqual(priorProof.calls.map(\.name), ["exec_command"])
        XCTAssertTrue(priorProof.wasLimited)
    }

    func testDeleteAndUpdateOfToolBridgeBlockLaterCallsButKeepPriorProof() {
        let mutations = [
            "delete tools.exec_command;",
            "tools.exec_command++;",
            "tools.exec_command--;",
            "++tools.exec_command;",
            "--tools.exec_command;",
            "delete tools[memberName];",
            "tools[memberName]++;",
        ]
        for mutation in mutations {
            let noPriorProof = TransientToolInput.extractLiteralCalls(
                "\(mutation) await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
            )
            XCTAssertTrue(noPriorProof.calls.isEmpty, mutation)
            XCTAssertTrue(noPriorProof.wasLimited, mutation)

            let priorProof = TransientToolInput.extractLiteralCalls("""
            await tools.exec_command({cmd: 'cat sample-a/SKILL.md'});
            \(mutation)
            await tools.exec_command({cmd: 'cat sample-b/SKILL.md'});
            """)
            XCTAssertEqual(priorProof.calls.map(\.name), ["exec_command"], mutation)
            XCTAssertTrue(priorProof.wasLimited, mutation)
        }
    }

    func testUnknownTopLevelWorkBlocksLaterBridgeCalls() {
        for input in [
            "await Promise.reject('stop'); await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "undefined(); await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
            "await unknownWork; await tools.exec_command({cmd: 'cat sample/SKILL.md'});",
        ] {
            let extraction = TransientToolInput.extractLiteralCalls(input)
            XCTAssertTrue(extraction.calls.isEmpty, input)
            XCTAssertTrue(extraction.wasLimited, input)
        }
    }

    func testUnknownTopLevelSuffixKeepsOnlyPriorProofAndMarksItLimited() {
        for suffix in ["undefined();", "await Promise.reject('stop');", "await unknownWork;"] {
            let extraction = TransientToolInput.extractLiteralCalls("""
            await tools.exec_command({cmd: 'cat sample/SKILL.md'});
            \(suffix)
            """)
            XCTAssertEqual(extraction.calls.map(\.name), ["exec_command"], suffix)
            XCTAssertTrue(extraction.wasLimited, suffix)
        }
    }

    func testAbruptExitAfterKnownCallRetainsOnlyPriorProof() {
        let input = """
        await tools.exec_command({cmd: 'cat sample-a/SKILL.md'});
        exit();
        await tools.exec_command({cmd: 'cat sample-b/SKILL.md'});
        """

        let extraction = TransientToolInput.extractLiteralCalls(input)
        XCTAssertEqual(extraction.calls.map(\.name), ["exec_command"])
        XCTAssertTrue(extraction.wasLimited)
    }

    func testMalformedPrefixOrSuffixFailsClosed() {
        let input = """
        await tools.exec_command({cmd: 'cat sample/SKILL.md'});
        results.forEach((item) => { text(item);
        """

        let extraction = TransientToolInput.extractLiteralCalls(input)
        XCTAssertTrue(extraction.calls.isEmpty)
        XCTAssertTrue(extraction.wasLimited)

        let malformedPrefix = ") await tools.exec_command({cmd: 'cat sample/SKILL.md'});"
        XCTAssertTrue(TransientToolInput.extractLiteralCalls(malformedPrefix).calls.isEmpty)

        let unterminatedQuote = "await tools.exec_command({cmd: 'cat sample/SKILL.md'}); text('output);"
        XCTAssertTrue(TransientToolInput.extractLiteralCalls(unterminatedQuote).calls.isEmpty)
    }

    func testDeepNestingAndOversizedInputsFailBoundedWithoutErasingPriorCall() {
        let deep = "await tools.exec_command({cmd: 'cat sample/SKILL.md'});" +
            String(repeating: "(", count: 65) + "text('output')" + String(repeating: ")", count: 65)
        let deepExtraction = TransientToolInput.extractLiteralCalls(deep)
        XCTAssertTrue(deepExtraction.calls.isEmpty)
        XCTAssertTrue(deepExtraction.wasLimited)

        let oversized = String(repeating: "x", count: 262_145)
        let oversizedExtraction = TransientToolInput.extractLiteralCalls(oversized)
        XCTAssertTrue(oversizedExtraction.calls.isEmpty)
        XCTAssertTrue(oversizedExtraction.wasLimited)
    }

    func testCallBudgetIsDeterministicAndLaterOutputCommentsStayNonEvidence() {
        let calls = (0..<65).map { index in
            "await tools.exec_command({cmd: 'cat sample-\(index)/SKILL.md'});"
        }.joined()
        let outputOnly = String(repeating: "/* output-only tools.fake({path:'ignored'}) */\n", count: 1_000)

        let extraction = TransientToolInput.extractLiteralCalls(calls + outputOnly)

        XCTAssertEqual(extraction.calls.count, 64)
        XCTAssertTrue(extraction.wasLimited)
        XCTAssertTrue(extraction.calls.allSatisfy { $0.name == "exec_command" })
    }
}
