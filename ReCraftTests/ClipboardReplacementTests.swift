import AppKit
import Security
import XCTest
@testable import ReCraft

@MainActor
private final class UnavailablePasteboardRepresentationProvider: NSObject,
    NSPasteboardItemDataProvider {
    private let onRequest: @MainActor () -> Void

    init(onRequest: @escaping @MainActor () -> Void = {}) {
        self.onRequest = onRequest
    }

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        MainActor.assumeIsolated {
            onRequest()
        }
    }
}

final class PasteboardTransactionTests: XCTestCase {
    @MainActor
    func testStagesReplacementAndRestoresAllOriginalRepresentations() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let binaryType = NSPasteboard.PasteboardType("test.recraft.binary")

        let firstItem = NSPasteboardItem()
        XCTAssertTrue(firstItem.setString("original", forType: .string))
        XCTAssertTrue(firstItem.setData(Data([0x00, 0x7f, 0xff]), forType: binaryType))
        let png = try syntheticPNGData()
        XCTAssertTrue(firstItem.setData(png, forType: .png))

        let secondItem = NSPasteboardItem()
        XCTAssertTrue(secondItem.setData(Data([0x10, 0x20]), forType: binaryType))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([firstItem, secondItem]))

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        let original = try transaction.captureSnapshot()
        let probe = try stageProbe(transaction, replacing: original)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("中文 🙂\nsecond line", forType: .string))
        let copiedText = try XCTUnwrap(transaction.copiedText(after: probe))
        XCTAssertEqual(copiedText.value, "中文 🙂\nsecond line")

        let replacement = try stageReplacement(
            transaction,
            text: "[ReCraft] 中文 🙂\nsecond line",
            replacing: copiedText,
            original: original
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "[ReCraft] 中文 🙂\nsecond line"
        )
        XCTAssertEqual(transaction.ownershipState(of: replacement), .owned)

        XCTAssertEqual(transaction.restore(original, ifOwnedBy: replacement), .restored)
        let restoredItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restoredItems.count, 2)
        XCTAssertEqual(
            pasteboardDataByType(restoredItems[0]),
            [
                NSPasteboard.PasteboardType.string.rawValue: Data("original".utf8),
                binaryType.rawValue: Data([0x00, 0x7f, 0xff]),
                NSPasteboard.PasteboardType.png.rawValue: png,
            ]
        )
        XCTAssertEqual(
            pasteboardDataByType(restoredItems[1]),
            [binaryType.rawValue: Data([0x10, 0x20])]
        )
    }

    @MainActor
    func testEmptySelectionRestoresOriginalClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        let original = try transaction.captureSnapshot()
        let probe = try stageProbe(transaction, replacing: original)

        XCTAssertNil(transaction.copiedText(after: probe))
        XCTAssertEqual(transaction.restore(original, ifOwnedBy: probe), .restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testCopiedSelectionCanRestoreOriginalClipboardBeforeGeneration() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        let original = try transaction.captureSnapshot()
        let probe = try stageProbe(transaction, replacing: original)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("selected text", forType: .string))
        let copiedText = try XCTUnwrap(transaction.copiedText(after: probe))

        XCTAssertEqual(
            transaction.restore(original, replacing: copiedText),
            .restored
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testCopiedSelectionDoesNotOverwriteNewerClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        let original = try transaction.captureSnapshot()
        let probe = try stageProbe(transaction, replacing: original)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("selected text", forType: .string))
        let copiedText = try XCTUnwrap(transaction.copiedText(after: probe))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("new user clipboard", forType: .string))

        XCTAssertEqual(
            transaction.restore(original, replacing: copiedText),
            .ownershipLost
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "new user clipboard")
    }

    @MainActor
    func testNewClipboardContentIsNotOverwrittenDuringRestore() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        let original = try transaction.captureSnapshot()
        let probe = try stageProbe(transaction, replacing: original)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("selected", forType: .string))
        let copiedText = try XCTUnwrap(transaction.copiedText(after: probe))
        let replacement = try stageReplacement(
            transaction,
            text: "[ReCraft] selected",
            replacing: copiedText,
            original: original
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("new user clipboard", forType: .string))

        XCTAssertEqual(
            transaction.restore(original, ifOwnedBy: replacement),
            .ownershipLost
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "new user clipboard")
    }

    @MainActor
    func testChangedClipboardCannotBeReplacedWithStaleCopiedText() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        let original = try transaction.captureSnapshot()
        let probe = try stageProbe(transaction, replacing: original)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("selected", forType: .string))
        let copiedText = try XCTUnwrap(transaction.copiedText(after: probe))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("new user clipboard", forType: .string))

        XCTAssertEqual(
            transaction.stageReplacement(
                "[ReCraft] selected",
                replacing: copiedText,
                original: original
            ),
            .sourceChanged
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "new user clipboard")
    }

    @MainActor
    func testEmptyClipboardCanBeCapturedAndRestored() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 0)

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        let original = try transaction.captureSnapshot()
        XCTAssertTrue(original.items.isEmpty)

        let probe = try stageProbe(transaction, replacing: original)
        XCTAssertEqual(transaction.restore(original, ifOwnedBy: probe), .restored)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    @MainActor
    func testNilItemsReaderFailsWithoutChangingClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("sentinel", forType: .string))
        let originalChangeCount = pasteboard.changeCount
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            pasteboardItemsReader: { nil }
        )

        XCTAssertThrowsError(try transaction.captureSnapshot()) { error in
            XCTAssertEqual(
                error as? PasteboardTransaction.SnapshotError,
                .itemsUnavailable
            )
        }
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "sentinel")
    }

    @MainActor
    func testIncompleteSnapshotDoesNotChangeClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("sentinel", forType: .string))
        let originalChangeCount = pasteboard.changeCount
        let provider = UnavailablePasteboardRepresentationProvider()
        let unavailableType = NSPasteboard.PasteboardType(
            "test.recraft.unavailable-representation"
        )
        let unreadableItem = NSPasteboardItem()
        XCTAssertTrue(unreadableItem.setDataProvider(provider, forTypes: [unavailableType]))
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            pasteboardItemsReader: { [unreadableItem] }
        )

        XCTAssertThrowsError(try transaction.captureSnapshot()) { error in
            XCTAssertEqual(
                error as? PasteboardTransaction.SnapshotError,
                .incomplete
            )
        }
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "sentinel")
        _ = provider
    }

    @MainActor
    func testChangedClipboardTakesPriorityOverIncompleteSnapshot() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("sentinel", forType: .string))
        let provider = UnavailablePasteboardRepresentationProvider {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString("newer", forType: .string))
        }
        let unavailableType = NSPasteboard.PasteboardType(
            "test.recraft.concurrent-unavailable-representation"
        )
        let unreadableItem = NSPasteboardItem()
        XCTAssertTrue(unreadableItem.setDataProvider(provider, forTypes: [unavailableType]))
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            pasteboardItemsReader: { [unreadableItem] }
        )

        XCTAssertThrowsError(try transaction.captureSnapshot()) { error in
            XCTAssertEqual(
                error as? PasteboardTransaction.SnapshotError,
                .changedWhileReading
            )
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
        _ = provider
    }

    @MainActor
    func testChangedClipboardDiscardsOtherwiseCompleteSnapshot() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("sentinel", forType: .string))
        let capturedItem = NSPasteboardItem()
        XCTAssertTrue(capturedItem.setString("captured", forType: .string))
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            pasteboardItemsReader: {
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("newer", forType: .string))
                return [capturedItem]
            }
        )

        XCTAssertThrowsError(try transaction.captureSnapshot()) { error in
            XCTAssertEqual(
                error as? PasteboardTransaction.SnapshotError,
                .changedWhileReading
            )
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
    }

    @MainActor
    func testFailedStageDoesNotRestoreWhenItemsReadIsUnavailable() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let snapshot = try PasteboardTransaction(pasteboard: pasteboard).captureSnapshot()
        pasteboard.clearContents()
        let failedStageChangeCount = pasteboard.changeCount
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            pasteboardItemsReader: { nil }
        )

        transaction.restoreAfterFailedStageForTesting(
            snapshot,
            expectedChangeCount: failedStageChangeCount
        )

        XCTAssertEqual(pasteboard.changeCount, failedStageChangeCount)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    @MainActor
    func testFailedStageDoesNotOverwriteNonemptyClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        let snapshot = try transaction.captureSnapshot()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("newer", forType: .string))
        let newerChangeCount = pasteboard.changeCount

        transaction.restoreAfterFailedStageForTesting(
            snapshot,
            expectedChangeCount: newerChangeCount
        )

        XCTAssertEqual(pasteboard.changeCount, newerChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
    }

    @MainActor
    func testFailedStageDoesNotRestoreFromEmptyClipboardAtStaleChangeCount() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        let snapshot = try transaction.captureSnapshot()
        let staleChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        let currentChangeCount = pasteboard.changeCount
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 0)

        transaction.restoreAfterFailedStageForTesting(
            snapshot,
            expectedChangeCount: staleChangeCount
        )

        XCTAssertEqual(pasteboard.changeCount, currentChangeCount)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 0)
    }

    @MainActor
    func testFailedStagePreservesChangeDuringFinalEmptyRead() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let snapshot = try PasteboardTransaction(pasteboard: pasteboard).captureSnapshot()
        pasteboard.clearContents()
        let failedStageChangeCount = pasteboard.changeCount
        var readCount = 0
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            pasteboardItemsReader: {
                readCount += 1
                if readCount == 2 {
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("newer", forType: .string))
                }
                return []
            }
        )

        transaction.restoreAfterFailedStageForTesting(
            snapshot,
            expectedChangeCount: failedStageChangeCount
        )

        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
    }

    @MainActor
    func testFailedStageRestoresOnlyFromStableExplicitEmptyClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        let snapshot = try transaction.captureSnapshot()
        pasteboard.clearContents()
        let failedStageChangeCount = pasteboard.changeCount

        transaction.restoreAfterFailedStageForTesting(
            snapshot,
            expectedChangeCount: failedStageChangeCount
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testOwnershipRequiresSameChangeCountMarkerAndText() {
        let token = Data("token".utf8)

        XCTAssertEqual(
            PasteboardTransaction.classifyOwnership(
                currentChangeCount: 10,
                expectedChangeCount: 10,
                itemCount: 1,
                marker: token,
                expectedToken: token,
                visibleText: "replacement",
                expectedText: "replacement",
                changeCountBeforeRead: 10
            ),
            .owned
        )
        XCTAssertEqual(
            PasteboardTransaction.classifyOwnership(
                currentChangeCount: 11,
                expectedChangeCount: 10,
                itemCount: 1,
                marker: token,
                expectedToken: token,
                visibleText: "replacement",
                expectedText: "replacement",
                changeCountBeforeRead: 11
            ),
            .lost
        )
        XCTAssertEqual(
            PasteboardTransaction.classifyOwnership(
                currentChangeCount: 10,
                expectedChangeCount: 10,
                itemCount: 1,
                marker: Data("other".utf8),
                expectedToken: token,
                visibleText: "replacement",
                expectedText: "replacement",
                changeCountBeforeRead: 10
            ),
            .lost
        )
    }

    @MainActor
    private func stageProbe(
        _ transaction: PasteboardTransaction,
        replacing snapshot: PasteboardTransaction.Snapshot
    ) throws -> PasteboardTransaction.Ownership {
        guard case let .staged(ownership) = transaction.stageCopyProbe(
            replacing: snapshot
        ) else {
            throw TestError.stagingFailed
        }
        return ownership
    }

    @MainActor
    private func stageReplacement(
        _ transaction: PasteboardTransaction,
        text: String,
        replacing copiedText: PasteboardTransaction.CopiedText,
        original snapshot: PasteboardTransaction.Snapshot
    ) throws -> PasteboardTransaction.Ownership {
        guard case let .staged(ownership) = transaction.stageReplacement(
            text,
            replacing: copiedText,
            original: snapshot
        ) else {
            throw TestError.stagingFailed
        }
        return ownership
    }

    private func pasteboardDataByType(_ item: NSPasteboardItem) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
            item.data(forType: type).map { (type.rawValue, $0) }
        })
    }

    private func syntheticPNGData() throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 4,
                bitsPerPixel: 32
            )
        )
        bitmap.bitmapData?.initialize(repeating: 0, count: 4)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private enum TestError: Error {
        case stagingFailed
    }
}

final class PasteDispatchGateTests: XCTestCase {
    @MainActor
    func testFocusChangePreventsPaste() {
        var pasteWasSent = false

        let result = PasteDispatchGate.dispatch(
            revalidateTarget: { false },
            clipboardStillOwned: { true },
            send: {
                pasteWasSent = true
                return true
            }
        )

        XCTAssertEqual(result, .targetChanged)
        XCTAssertFalse(pasteWasSent)
    }

    @MainActor
    func testStableFocusSendsPasteOnce() {
        var sendCount = 0

        let result = PasteDispatchGate.dispatch(
            revalidateTarget: { true },
            clipboardStillOwned: { true },
            send: {
                sendCount += 1
                return true
            }
        )

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(sendCount, 1)
    }

    @MainActor
    func testClipboardChangePreventsPaste() {
        var pasteWasSent = false

        let result = PasteDispatchGate.dispatch(
            revalidateTarget: { true },
            clipboardStillOwned: { false },
            send: {
                pasteWasSent = true
                return true
            }
        )

        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertFalse(pasteWasSent)
    }
}

final class ClipboardSnapshotCaptureTests: XCTestCase {
    @MainActor
    func testSnapshotFailureMessageStatesSafeStopAndRecovery() {
        XCTAssertEqual(
            ClipboardTextReplacementService.SafeRefusal
                .clipboardSnapshotUnavailable.message,
            "Stopped safely; clipboard unchanged — try again"
        )
    }

    @MainActor
    func testMapsEverySnapshotFailureByCaptureStageAndCategory() {
        typealias Service = ClipboardTextReplacementService
        let cases: [(
            stage: Service.SnapshotCaptureStage,
            error: PasteboardTransaction.SnapshotError,
            expected: Service.SafeRefusal,
            category: String
        )] = [
            (
                .sourceCapture,
                .itemsUnavailable,
                .sourceCaptureItemsUnavailable,
                "itemsUnavailable"
            ),
            (
                .sourceCapture,
                .incomplete,
                .sourceCaptureIncomplete,
                "incomplete"
            ),
            (
                .sourceCapture,
                .changedWhileReading,
                .sourceCaptureChangedWhileReading,
                "changedWhileReading"
            ),
            (
                .deliveryCapture,
                .itemsUnavailable,
                .deliveryCaptureItemsUnavailable,
                "itemsUnavailable"
            ),
            (
                .deliveryCapture,
                .incomplete,
                .deliveryCaptureIncomplete,
                "incomplete"
            ),
            (
                .deliveryCapture,
                .changedWhileReading,
                .deliveryCaptureChangedWhileReading,
                "changedWhileReading"
            ),
        ]

        for testCase in cases {
            let result = Service.captureClipboardSnapshot(stage: testCase.stage) {
                throw testCase.error
            }
            guard case let .refused(reason) = result else {
                XCTFail("Expected snapshot capture refusal")
                continue
            }
            XCTAssertEqual(reason, testCase.expected)
            XCTAssertEqual(reason.logStage, testCase.stage.rawValue)
            XCTAssertEqual(reason.logCategory, testCase.category)
            let messageWidth = (reason.message as NSString).size(
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                ]
            ).width
            XCTAssertLessThanOrEqual(messageWidth, 420)
            if testCase.category == "changedWhileReading" {
                XCTAssertTrue(reason.message.contains("copying stops"))
            } else {
                XCTAssertTrue(reason.message.contains("copy plain text"))
            }
            if testCase.stage == .deliveryCapture {
                XCTAssertTrue(reason.message.contains("after rewrite"))
            } else {
                XCTAssertTrue(reason.message.contains("Stopped safely"))
            }
        }
    }

    @MainActor
    func testSourceCaptureFailureStopsBothEntrypointsBeforeCommandsOrModel() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let originalChangeCount = pasteboard.changeCount
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            pasteboardItemsReader: { nil }
        )
        let apiKeyStore = InMemoryAPIKeyStore()
        var copyCount = 0
        var pasteCount = 0
        var modelCount = 0
        let service = ClipboardTextReplacementService(
            pasteboardTransaction: transaction,
            apiKeyStore: apiKeyStore,
            testHooks: makeHooks(
                sendCommand: { command in
                    switch command {
                    case .copy:
                        copyCount += 1
                    case .paste:
                        pasteCount += 1
                    }
                    return true
                },
                rewrite: { _, _ in
                    modelCount += 1
                    return "rewritten"
                }
            )
        )

        let deterministicOutcome = await service.replaceSelection()
        XCTAssertEqual(
            refusal(from: deterministicOutcome),
            .sourceCaptureItemsUnavailable
        )
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        let remoteOutcome = await service.rewriteSelection(
            using: RewriteTaskCatalog.initial.tasks[0]
        )
        XCTAssertEqual(
            refusal(from: remoteOutcome),
            .sourceCaptureItemsUnavailable
        )

        XCTAssertEqual(copyCount, 0)
        XCTAssertEqual(pasteCount, 0)
        XCTAssertEqual(modelCount, 0)
        let sourceLoadCount = await apiKeyStore.loadCount
        XCTAssertEqual(sourceLoadCount, 0)
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testDeliveryCaptureFailureStopsBeforeSecondCopyAndPaste() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var snapshotReadCount = 0
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            pasteboardItemsReader: {
                snapshotReadCount += 1
                return snapshotReadCount == 1 ? pasteboard.pasteboardItems : nil
            }
        )
        let apiKeyStore = InMemoryAPIKeyStore()
        var copyCount = 0
        var pasteCount = 0
        var modelCount = 0
        let service = ClipboardTextReplacementService(
            pasteboardTransaction: transaction,
            apiKeyStore: apiKeyStore,
            testHooks: makeHooks(
                sendCommand: { command in
                    switch command {
                    case .copy:
                        copyCount += 1
                        pasteboard.clearContents()
                        XCTAssertTrue(
                            pasteboard.setString("selected", forType: .string)
                        )
                    case .paste:
                        pasteCount += 1
                    }
                    return true
                },
                rewrite: { selectedText, taskPrompt in
                    modelCount += 1
                    XCTAssertEqual(selectedText, "selected")
                    XCTAssertFalse(taskPrompt.isEmpty)
                    return "rewritten"
                }
            )
        )

        let outcome = await service.rewriteSelection(
            using: RewriteTaskCatalog.initial.tasks[0]
        )

        XCTAssertEqual(refusal(from: outcome), .deliveryCaptureItemsUnavailable)
        XCTAssertEqual(snapshotReadCount, 2)
        XCTAssertEqual(modelCount, 1)
        XCTAssertEqual(copyCount, 1)
        XCTAssertEqual(pasteCount, 0)
        let deliveryLoadCount = await apiKeyStore.loadCount
        XCTAssertEqual(deliveryLoadCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    private func makeHooks(
        sendCommand: @escaping @MainActor (CGKeyCommandSender.Command) -> Bool,
        rewrite: @escaping @MainActor (String, String) async throws -> String
    ) -> ClipboardTextReplacementService.TestHooks {
        ClipboardTextReplacementService.TestHooks(
            accessibilityTrusted: true,
            targetContext: ClipboardTextReplacementService.Context(
                applicationName: "Synthetic",
                bundleIdentifier: "test.recraft.synthetic",
                role: "AXTextArea",
                subrole: nil
            ),
            processIdentifier: 1,
            modifiersReleased: { true },
            targetStillMatches: { true },
            sendCommand: sendCommand,
            rewrite: rewrite
        )
    }

    @MainActor
    private func refusal(
        from outcome: ClipboardTextReplacementService.Outcome
    ) -> ClipboardTextReplacementService.SafeRefusal? {
        guard case let .refused(reason, _) = outcome else {
            return nil
        }
        return reason
    }
}

final class AXSecureFieldCheckTests: XCTestCase {
    func testAllowsExplicitlyClearOrUnsupportedProtectedContent() {
        XCTAssertEqual(
            AXSecureFieldCheck.protectedContentStatus(
                error: .success,
                value: kCFBooleanFalse
            ),
            .clear
        )
        XCTAssertEqual(
            AXSecureFieldCheck.protectedContentStatus(
                error: .attributeUnsupported,
                value: nil
            ),
            .unsupported
        )
        XCTAssertEqual(
            AXSecureFieldCheck.decision(
                role: "AXTextArea",
                subrole: nil,
                protectedContentStatus: .unsupported
            ),
            .allowed
        )
    }

    func testRejectsSecureRoleOrProtectedContent() {
        XCTAssertEqual(
            AXSecureFieldCheck.decision(
                role: "AXSecureTextField",
                subrole: nil,
                protectedContentStatus: .unsupported
            ),
            .secure
        )
        XCTAssertEqual(
            AXSecureFieldCheck.protectedContentStatus(
                error: .success,
                value: kCFBooleanTrue
            ),
            .protected
        )
        XCTAssertEqual(
            AXSecureFieldCheck.decision(
                role: "AXTextField",
                subrole: nil,
                protectedContentStatus: .protected
            ),
            .secure
        )
    }

    func testRejectsUnverifiableProtectedContentStatus() {
        XCTAssertEqual(
            AXSecureFieldCheck.protectedContentStatus(
                error: .cannotComplete,
                value: nil
            ),
            .unavailable
        )
        XCTAssertEqual(
            AXSecureFieldCheck.decision(
                role: "AXTextField",
                subrole: nil,
                protectedContentStatus: .unavailable
            ),
            .unverifiable
        )
    }
}

final class TargetCaptureRetryTests: XCTestCase {
    func testTreatsMissingProtectedContentValueAsUnsupported() {
        // WeChat's message field answers kAXErrorNoValue for the protected
        // content flag; that is not a failed read.
        XCTAssertEqual(
            AXSecureFieldCheck.protectedContentStatus(error: .noValue, value: nil),
            .unsupported
        )
        XCTAssertEqual(
            AXSecureFieldCheck.decision(
                role: "AXSecureTextField",
                subrole: nil,
                protectedContentStatus: .unsupported
            ),
            .secure
        )
    }

    func testOnlyRecognizedSecureControlIsNotRetried() {
        XCTAssertTrue(TargetCaptureFailure.focusedApplicationUnavailable(.noValue).isTransient)
        XCTAssertTrue(TargetCaptureFailure.focusedApplicationMismatch.isTransient)
        XCTAssertTrue(TargetCaptureFailure.focusedElementUnavailable(.cannotComplete).isTransient)
        XCTAssertTrue(TargetCaptureFailure.roleUnavailable(.cannotComplete).isTransient)
        XCTAssertTrue(TargetCaptureFailure.secureStatusUnavailable.isTransient)
        XCTAssertFalse(TargetCaptureFailure.secureControl.isTransient)
    }

    func testOnlyFailedReadsAreRetriedDuringRevalidation() {
        XCTAssertTrue(TargetMatchStatus.readFailed(.cannotComplete).isTransient)
        XCTAssertFalse(TargetMatchStatus.matches.isTransient)
        XCTAssertFalse(TargetMatchStatus.applicationChanged.isTransient)
        XCTAssertFalse(TargetMatchStatus.elementChanged.isTransient)
        XCTAssertFalse(TargetMatchStatus.secure.isTransient)
    }

    @MainActor
    func testRetryRecoversFromTransientFailure() async {
        var results = [false, false, true]
        let outcome = await BoundedRetry.run(
            maximumAttempts: 5,
            interval: .milliseconds(1),
            attempt: { results.removeFirst() },
            shouldRetry: { !$0 }
        )
        XCTAssertTrue(outcome.value)
        XCTAssertEqual(outcome.attempts, 3)
    }

    @MainActor
    func testRetryStopsAtMaximumAttempts() async {
        var calls = 0
        let outcome = await BoundedRetry.run(
            maximumAttempts: 4,
            interval: .milliseconds(1),
            attempt: { calls += 1; return false },
            shouldRetry: { !$0 }
        )
        XCTAssertFalse(outcome.value)
        XCTAssertEqual(outcome.attempts, 4)
        XCTAssertEqual(calls, 4)
    }

    @MainActor
    func testRetryDoesNotRepeatNonTransientResult() async {
        var calls = 0
        let outcome = await BoundedRetry.run(
            maximumAttempts: 4,
            interval: .milliseconds(1),
            attempt: { calls += 1; return TargetCaptureFailure.secureControl },
            shouldRetry: { $0.isTransient }
        )
        XCTAssertEqual(outcome.value, .secureControl)
        XCTAssertEqual(calls, 1)
    }
}

final class DeterministicTextTransformerTests: XCTestCase {
    func testPreservesMixedMultilineTextAfterPrefix() {
        let selected = "first line\n第二行 🙂\nthird line"
        XCTAssertTrue(
            ExactText.matches(
                DeterministicTextTransformer.transform(selected),
                "[ReCraft] first line\n第二行 🙂\nthird line"
            )
        )
    }
}

final class RewritePromptPolicyTests: XCTestCase {
    func testAcceptsNonemptyOutputWithoutChangingIt() {
        let output = "  Keep formatting\n```swift\nlet count = 7\n```  "
        XCTAssertEqual(RewritePromptPolicy.acceptedOutput(output), output)
    }

    func testRejectsWhitespaceOnlyOutput() {
        XCTAssertNil(RewritePromptPolicy.acceptedOutput(" \n\t "))
    }

    func testSelectionMustRemainExactlyUnchanged() {
        XCTAssertTrue(
            RewritePromptPolicy.selectionIsUnchanged(
                original: "中文 🙂\nlet count = 7",
                current: "中文 🙂\nlet count = 7"
            )
        )
        XCTAssertFalse(
            RewritePromptPolicy.selectionIsUnchanged(
                original: "中文 🙂\nlet count = 7",
                current: "中文 🙂\nlet count = 8"
            )
        )
    }
}

final class OpenAIResponsesClientTests: XCTestCase {
    func testNetworkSessionDoesNotPersistRequestsOrFollowRedirects() {
        let session = OpenAISessionFactory.makeSession()

        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertTrue(session.delegate is NoRedirectSessionDelegate)
        session.invalidateAndCancel()
    }

    func testRequestUsesApprovedModelPrivacyAndEffortConfiguration() throws {
        let selectedText = "中文 request 🙂\nlet count = 7"
        let instructions = "TASK-PROMPT-ONLY"
        let request = try OpenAIResponsesClient.makeRequest(
            selectedText: selectedText,
            instructions: instructions,
            apiKey: "test-api-key"
        )

        XCTAssertEqual(request.url, OpenAIResponsesClient.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-api-key"
        )

        let body = try jsonObject(from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(
            body["instructions"] as? String,
            instructions
        )
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2_400)
        XCTAssertEqual(body["service_tier"] as? String, "default")
        XCTAssertEqual(body["truncation"] as? String, "disabled")
        XCTAssertNil(body["previous_response_id"])

        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "none")
        XCTAssertEqual(reasoning["context"] as? String, "current_turn")

        let text = try XCTUnwrap(body["text"] as? [String: Any])
        XCTAssertEqual(text["verbosity"] as? String, "low")
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "text")
        XCTAssertEqual((body["tools"] as? [Any])?.count, 0)

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[0]["text"] as? String, selectedText)

        let bodyString = try XCTUnwrap(String(data: request.httpBody!, encoding: .utf8))
        XCTAssertFalse(bodyString.contains("test-api-key"))
        XCTAssertFalse(bodyString.contains("TASK-NAME-SENTINEL"))
        XCTAssertFalse(bodyString.contains("TASK-ID-SENTINEL"))
        XCTAssertFalse(bodyString.contains("SHORTCUT-SENTINEL"))
        XCTAssertFalse(bodyString.contains("APPLICATION-SENTINEL"))
        XCTAssertFalse(bodyString.contains("CLIPBOARD-SENTINEL"))
        XCTAssertFalse(bodyString.contains("SURROUNDING-SENTINEL"))
        XCTAssertFalse(bodyString.contains("PRIOR-REQUEST-SENTINEL"))
    }

    func testParserIgnoresReasoningItemsAndCollectsOutputText() throws {
        let data = Data(
            """
            {
              "status": "completed",
              "output": [
                {"type": "reasoning"},
                {
                  "type": "message",
                  "content": [
                    {"type": "output_text", "text": "first line"},
                    {"type": "output_text", "text": "第二行 🙂"}
                  ]
                }
              ]
            }
            """.utf8
        )

        XCTAssertEqual(
            try OpenAIResponsesClient.parseResponse(
                data: data,
                response: httpResponse(statusCode: 200)
            ),
            "first line\n第二行 🙂"
        )
    }

    func testParserRejectsNonSuccessfulOrIncompleteResponses() throws {
        let completed = Data("{\"status\":\"completed\",\"output\":[]}".utf8)
        XCTAssertThrowsError(
            try OpenAIResponsesClient.parseResponse(
                data: completed,
                response: httpResponse(statusCode: 401)
            )
        ) { error in
            XCTAssertEqual(error as? CodingPromptRewriteError, .apiFailure)
        }

        let incomplete = Data("{\"status\":\"incomplete\",\"output\":[]}".utf8)
        XCTAssertThrowsError(
            try OpenAIResponsesClient.parseResponse(
                data: incomplete,
                response: httpResponse(statusCode: 200)
            )
        ) { error in
            XCTAssertEqual(error as? CodingPromptRewriteError, .apiFailure)
        }
    }

    func testParserReturnsAllowlistedUsageMetadata() throws {
        let data = Data(
            """
            {
              "status": "completed",
              "output": [
                {
                  "type": "message",
                  "content": [{"type": "output_text", "text": "rewritten"}]
                }
              ],
              "usage": {
                "input_tokens": 12,
                "input_tokens_details": {"cached_tokens": 3},
                "output_tokens": 7,
                "total_tokens": 19,
                "output_tokens_details": {"reasoning_tokens": 0}
              }
            }
            """.utf8
        )

        let result = try OpenAIResponsesClient.parseResult(
            data: data,
            response: httpResponse(statusCode: 200)
        )

        XCTAssertEqual(result.text, "rewritten")
        XCTAssertEqual(
            result.usage,
            OpenAIResponseUsage(
                inputTokens: 12,
                cachedInputTokens: 3,
                outputTokens: 7,
                reasoningTokens: 0,
                totalTokens: 19
            )
        )
    }

    func testParserRejectsWhitespaceOnlyOutput() throws {
        let data = Data(
            """
            {
              "status": "completed",
              "output": [
                {
                  "type": "message",
                  "content": [{"type": "output_text", "text": "  \\n"}]
                }
              ]
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try OpenAIResponsesClient.parseResponse(
                data: data,
                response: httpResponse(statusCode: 200)
            )
        ) { error in
            XCTAssertEqual(error as? CodingPromptRewriteError, .emptyResponse)
        }
    }

    func testParserRejectsMixedRefusalAndOutputText() throws {
        let data = Data(
            """
            {
              "status": "completed",
              "output": [
                {
                  "type": "message",
                  "content": [
                    {"type": "refusal", "refusal": "cannot comply"},
                    {"type": "output_text", "text": "partial text"}
                  ]
                }
              ]
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try OpenAIResponsesClient.parseResponse(
                data: data,
                response: httpResponse(statusCode: 200)
            )
        ) { error in
            XCTAssertEqual(error as? CodingPromptRewriteError, .refusal)
        }
    }

    func testNetworkFailureIsMappedWithoutRetrying() async throws {
        let counter = RequestCounter()
        let client = OpenAIResponsesClient { _ in
            await counter.increment()
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.rewrite(
                selectedText: "selected",
                instructions: "task instruction",
                apiKey: "test-api-key"
            )
            XCTFail("Expected the network request to fail")
        } catch {
            XCTAssertEqual(error as? CodingPromptRewriteError, .networkFailure)
        }
        let requestCount = await counter.value
        XCTAssertEqual(requestCount, 1)
    }

    func testMissingKeyStopsBeforeNetworkRequest() async throws {
        let store = InMemoryAPIKeyStore()
        let counter = RequestCounter()
        let client = OpenAIResponsesClient { _ in
            await counter.increment()
            throw URLError(.unknown)
        }
        let rewriter = CodingPromptRewriter(
            apiKeyStore: store,
            client: client
        )

        do {
            _ = try await rewriter.rewrite(
                "selected",
                taskPrompt: "task instruction"
            )
            XCTFail("Expected the missing key to stop the request")
        } catch {
            XCTAssertEqual(error as? CodingPromptRewriteError, .apiKeyMissing)
        }
        let requestCount = await counter.value
        XCTAssertEqual(requestCount, 0)
    }

    func testNormalRewriterForwardsNetworkFailureWithoutRetrying() async throws {
        let store = InMemoryAPIKeyStore(key: "test-api-key")
        let counter = RequestCounter()
        let client = OpenAIResponsesClient { _ in
            await counter.increment()
            throw URLError(.unknown)
        }
        let rewriter = CodingPromptRewriter(apiKeyStore: store, client: client)

        do {
            _ = try await rewriter.rewrite(
                "SELECTED_TEXT_SENTINEL",
                taskPrompt: "TASK_PROMPT_SENTINEL"
            )
            XCTFail("Expected the network request to fail")
        } catch {
            XCTAssertEqual(
                error as? CodingPromptRewriteError,
                .networkFailure
            )
        }

        let loadCount = await store.loadCount
        let containsCount = await store.containsCount
        let requestCount = await counter.value
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(containsCount, 0)
        XCTAssertEqual(requestCount, 1)
    }

    func testRewriteLoadsAPIKeyOnlyOnce() async throws {
        let store = InMemoryAPIKeyStore(key: "test-api-key")
        let responseData = Data(
            """
            {
              "status": "completed",
              "output": [
                {
                  "type": "message",
                  "content": [{"type": "output_text", "text": "rewritten"}]
                }
              ]
            }
            """.utf8
        )
        let client = OpenAIResponsesClient { _ in
            (
                responseData,
                HTTPURLResponse(
                    url: OpenAIResponsesClient.endpoint,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            )
        }
        let rewriter = CodingPromptRewriter(
            apiKeyStore: store,
            client: client
        )

        let result = try await rewriter.rewrite(
            "selected",
            taskPrompt: "task instruction"
        )

        XCTAssertEqual(result.text, "rewritten")
        let containsCount = await store.containsCount
        let loadCount = await store.loadCount
        XCTAssertEqual(containsCount, 0)
        XCTAssertEqual(loadCount, 1)
    }

    func testKeychainFailureStopsBeforeNetworkRequest() async throws {
        let store = InMemoryAPIKeyStore(shouldFail: true)
        let counter = RequestCounter()
        let client = OpenAIResponsesClient { _ in
            await counter.increment()
            throw URLError(.unknown)
        }
        let rewriter = CodingPromptRewriter(
            apiKeyStore: store,
            client: client
        )

        do {
            _ = try await rewriter.rewrite(
                "selected",
                taskPrompt: "task instruction"
            )
            XCTFail("Expected Keychain failure to stop the request")
        } catch {
            XCTAssertEqual(error as? CodingPromptRewriteError, .keychainUnavailable)
        }
        let requestCount = await counter.value
        XCTAssertEqual(requestCount, 0)
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func httpResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: OpenAIResponsesClient.endpoint,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

final class APIKeySettingsModelTests: XCTestCase {
    @MainActor
    func testSaveUpdateAndDeleteUseStoreWithoutRedisplayingKey() async throws {
        let store = InMemoryAPIKeyStore()
        let model = APIKeySettingsModel(store: store)

        await model.refresh()
        XCTAssertFalse(model.isConfigured)

        model.draftKey = "  first-key  "
        await model.save()
        XCTAssertTrue(model.isConfigured)
        XCTAssertEqual(model.draftKey, "")
        XCTAssertEqual(model.statusMessage, "API key saved")
        let firstStoredKey = try await store.loadKey()
        XCTAssertEqual(firstStoredKey, "first-key")

        model.draftKey = "second-key"
        await model.save()
        XCTAssertEqual(model.draftKey, "")
        let secondStoredKey = try await store.loadKey()
        XCTAssertEqual(secondStoredKey, "second-key")

        await model.delete()
        XCTAssertFalse(model.isConfigured)
        XCTAssertEqual(model.draftKey, "")
        XCTAssertEqual(model.statusMessage, "API key deleted")
        let deletedKey = try await store.loadKey()
        XCTAssertNil(deletedKey)
    }

    @MainActor
    func testWhitespaceKeyIsRejectedWithoutTouchingStore() async throws {
        let store = InMemoryAPIKeyStore()
        let model = APIKeySettingsModel(store: store)
        model.draftKey = " \n\t "

        await model.save()

        XCTAssertFalse(model.isConfigured)
        XCTAssertEqual(model.statusMessage, "Enter an API key")
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 0)
    }

    @MainActor
    func testClosingSettingsClearsUnsavedKeyMaterial() {
        let model = APIKeySettingsModel(store: InMemoryAPIKeyStore())
        model.draftKey = "unsaved-key"

        model.clearDraft()

        XCTAssertEqual(model.draftKey, "")
    }

    @MainActor
    func testKeychainFailureUsesGenericStatus() async {
        let store = InMemoryAPIKeyStore(shouldFail: true)
        let model = APIKeySettingsModel(store: store)

        await model.refresh()
        XCTAssertFalse(model.isConfigured)
        XCTAssertEqual(model.statusMessage, "Keychain unavailable")

        model.draftKey = "test-key"
        await model.save()
        XCTAssertEqual(model.statusMessage, "API key could not be saved")
        XCTAssertEqual(model.draftKey, "test-key")
    }
}

private actor RequestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor InMemoryAPIKeyStore: APIKeyStoring {
    private var key: String?
    private let shouldFail: Bool
    private(set) var saveCount = 0
    private(set) var containsCount = 0
    private(set) var loadCount = 0

    init(key: String? = nil, shouldFail: Bool = false) {
        self.key = key
        self.shouldFail = shouldFail
    }

    func containsKey() throws -> Bool {
        try checkFailure()
        containsCount += 1
        return key != nil
    }

    func loadKey() throws -> String? {
        try checkFailure()
        loadCount += 1
        return key
    }

    func saveKey(_ key: String) throws {
        try checkFailure()
        saveCount += 1
        self.key = key
    }

    func deleteKey() throws {
        try checkFailure()
        key = nil
    }

    private func checkFailure() throws {
        if shouldFail {
            throw APIKeyStoreError.unhandledStatus(errSecNotAvailable)
        }
    }
}

final class SingleOperationGateTests: XCTestCase {
    func testAllowsOnlyOneOperationUntilFinished() {
        var gate = SingleOperationGate()

        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.begin())

        gate.finish()
        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(gate.begin())
    }
}
