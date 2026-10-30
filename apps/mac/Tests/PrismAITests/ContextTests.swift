import Foundation
import Testing
@testable import PrismAI

/// Ported from `ai_context.rs`: long conversations keep the original archive and send a bounded, compacted context.
struct ContextTests {
    func conversation(_ pairs: Int) -> [AIMessage] {
        var messages: [AIMessage] = []
        for index in 0..<pairs {
            messages.append(Fixture.message("user", "Question \(index): " + String(repeating: "Context detail. ", count: 50)))
            messages.append(Fixture.message("assistant", "Answer \(index): " + String(repeating: "Confirmed result. ", count: 50)))
        }
        messages.append(Fixture.message("user", "Continue the conversation."))
        return messages
    }

    var budget: AIContext.Budget { AIContext.Budget(window: 8192, modelOutput: nil, requestedOutput: 2048) }

    @Test func shortHistoryNeedsNoSummary() async throws {
        var messages: [AIMessage] = []
        for _ in 0..<30 { messages += [Fixture.message("user", "Hi"), Fixture.message("assistant", "Hello")] }
        messages.append(Fixture.message("user", "Continue"))
        let result = try await AIContext.prepare(messages, compaction: nil, budget: budget, summarize: { _, _ in
            Issue.record("no summary call"); return ""
        }, progress: { Issue.record("no progress") })
        #expect(result.messages.count == 61)
        #expect(result.compaction == nil)
    }

    @Test func summaryChunksBudgetForRoleLabelsOnManySmallMessages() async throws {
        var messages: [AIMessage] = []
        for _ in 0..<1000 { messages += [Fixture.message("user", "Hi"), Fixture.message("assistant", "Hello")] }
        messages.append(Fixture.message("user", "Continue"))
        let budget = budget
        let result = try await AIContext.prepare(messages, compaction: nil, budget: budget, summarize: { input, _ in
            #expect(AIContext.tokens(input) + 16 * input.count + AIContext.textTokens(AIContext.summaryInstruction) + 32 <= budget.input)
            return "Conversation goals."
        }, progress: {})
        #expect(result.compaction != nil)
    }

    @Test func compactsInBoundedChunksAndKeepsRecentTurnsAndArchive() async throws {
        let messages = conversation(80)
        let original = messages
        let budget = budget
        var calls = 0
        let result = try await AIContext.prepare(messages, compaction: nil, budget: budget, summarize: { input, _ in
            #expect(AIContext.tokens(input) + AIContext.textTokens(AIContext.summaryInstruction) < budget.input)
            calls += 1
            return "Constraints, decisions, and unresolved questions."
        }, progress: {})
        let compaction = try #require(result.compaction)
        #expect(compaction.through > 0 && compaction.through % 2 == 0)
        #expect(messages == original)
        #expect(result.messages.last?.content == messages.last?.content)
        #expect(AIContext.tokens(result.messages) <= budget.input)
        #expect(calls > 1)
        // The next request reuses the checkpoint instead of paying to summarize the archive again.
        let again = try await AIContext.prepare(messages, compaction: compaction, budget: budget, summarize: { _, _ in
            Issue.record("checkpoint should be reused"); return ""
        }, progress: {})
        #expect(again.compaction == compaction)
    }

    @Test func retrievesExactOldKoreanDetailsInAdditionToSummary() async throws {
        var messages = conversation(10)
        messages[0].content = "배포 승인코드는 PRISM-7264이고 승인 담당자는 김민수입니다."
        messages[messages.count - 1].content = "승인코드를 다시 알려줘"
        let result = try await AIContext.prepare(messages, compaction: ChatCompaction(summary: "Discussed deployment.", through: 18), budget: budget,
                                                 summarize: { _, _ in Issue.record("already compacted"); return "" }, progress: {})
        #expect(result.messages[0].content.contains("PRISM-7264"))
        #expect(result.messages[0].content.contains("archived_message number=\"1\""))
    }

    @Test func failsWithoutFabricatingWhenSummaryFails() async {
        do {
            _ = try await AIContext.prepare(conversation(20), compaction: nil, budget: budget, summarize: { _, _ in throw AIError("provider unavailable") }, progress: {})
            Issue.record("expected failure")
        } catch {
            #expect((error as? AIError)?.message == "provider unavailable")
        }
        for summary in ["", String(repeating: "x", count: 20_000)] {
            await #expect(throws: AIError.self) {
                _ = try await AIContext.prepare(conversation(20), compaction: nil, budget: budget, summarize: { _, _ in summary }, progress: {})
            }
        }
    }

    @Test func recompressesACheckpointAfterSwitchingToASmallerModel() async throws {
        var messages = conversation(10)
        messages[messages.count - 1].content = "Next"
        let budget = budget
        var calls = 0
        let result = try await AIContext.prepare(messages, compaction: ChatCompaction(summary: String(repeating: "이전 결정 사항과 제약 조건. ", count: 200), through: 20),
                                                 budget: budget, summarize: { input, _ in
            #expect(AIContext.tokens(input) + AIContext.textTokens(AIContext.summaryInstruction) < budget.input)
            calls += 1
            return "이전 결정 사항 유지."
        }, progress: {})
        #expect(calls > 1)
        #expect(result.compaction?.through == 20)
    }

    @Test func splittingPreservesLargeUnicodeMessagesExactly() throws {
        let original = Fixture.message("assistant", String(repeating: "한글🙂 and exact numbers 1234\n", count: 3000))
        let parts = try AIContext.pieces(original, limit: 1000)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { AIContext.tokens([$0]) <= 1000 })
        #expect(parts.map(\.content).joined() == original.content)
        #expect(AIContext.tokens([AIMessage(role: "user", content: "Explain the screen", image: Fixture.image())]) > 4096)
    }

    @Test func rejectsInvalidCheckpointsAndOversizedNewMessages() async {
        await #expect(throws: AIError.self) {
            _ = try await AIContext.prepare(conversation(2), compaction: ChatCompaction(summary: "Bad boundary", through: 3), budget: budget,
                                            summarize: { _, _ in Issue.record("invalid"); return "" }, progress: {})
        }
        await #expect(throws: AIError.self) {
            _ = try await AIContext.prepare([Fixture.message("user", String(repeating: "x", count: 60_000))], compaction: nil, budget: budget,
                                            summarize: { _, _ in Issue.record("oversized latest"); return "" }, progress: {})
        }
        #expect(AIContext.Budget(window: 4096, modelOutput: nil, requestedOutput: 32_768).output < 4096)
    }

    @Test func compactsOldImagesAndKeepsTheNewestCapture() async throws {
        var messages = conversation(8)
        for index in messages.indices where messages[index].role == "user" { messages[index].image = Fixture.image() }
        let result = try await AIContext.prepare(messages, compaction: nil, budget: AIContext.Budget(window: 128_000, modelOutput: nil, requestedOutput: 4096),
                                                 summarize: { input, _ in
            #expect(AIContext.imageCount(input) <= 4)
            return "Important screen observations."
        }, progress: {})
        #expect(AIContext.imageCount(result.messages) <= 4)
        #expect(result.messages.last?.image != nil)
        #expect(result.compaction != nil)
    }

    @Test func manyCompactionCyclesContinueTheSameArchive() async throws {
        var archive: [AIMessage] = []
        var compaction: ChatCompaction?
        var cycles = 0
        let budget = budget
        for turn in 0..<120 {
            archive.append(Fixture.message("user", "Turn \(turn). " + String(repeating: "Detailed current request. ", count: 30)))
            let previous = compaction?.through ?? 0
            let prepared = try await AIContext.prepare(archive, compaction: compaction, budget: budget,
                                                       summarize: { _, _ in "Keep the original goal and all confirmed decisions." }, progress: {})
            #expect(AIContext.tokens(prepared.messages) <= budget.input)
            compaction = prepared.compaction
            let through = compaction?.through ?? 0
            #expect(through >= previous)
            if through > previous { cycles += 1 }
            archive.append(Fixture.message("assistant", "Reply \(turn). " + String(repeating: "Verified outcome. ", count: 30)))
        }
        #expect(cycles > 5)
        #expect(archive.count == 240)
        #expect(archive[0].content.hasPrefix("Turn 0."))
    }
}
