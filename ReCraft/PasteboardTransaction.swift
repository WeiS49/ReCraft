import AppKit
import Foundation

@MainActor
final class PasteboardTransaction {
    static let operationMarkerType = NSPasteboard.PasteboardType(
        "com.local.recraftclipboardspike.operation-token"
    )

    struct Representation: Equatable {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    struct Item: Equatable {
        let representations: [Representation]
    }

    struct Snapshot: Equatable {
        let items: [Item]
        fileprivate let sourceChangeCount: Int

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.items == rhs.items
        }
    }

    struct Ownership: Equatable {
        let token: Data
        let changeCount: Int
        let expectedText: String?
    }

    struct CopiedText: Equatable {
        let value: String
        fileprivate let changeCount: Int
    }

    enum OwnershipState: Equatable {
        case owned
        case lost
    }

    enum SnapshotError: Error, Equatable {
        case itemsUnavailable
        case changedWhileReading
        case incomplete
    }

    enum StageResult: Equatable {
        case staged(Ownership)
        case sourceChanged
        case writeFailed
    }

    enum RestorationResult: Equatable {
        case restored
        case ownershipLost
        case writeFailed
    }

    private let pasteboard: NSPasteboard
    private let pasteboardItemsReader: () -> [NSPasteboardItem]?

    init(
        pasteboard: NSPasteboard = .general,
        pasteboardItemsReader: (() -> [NSPasteboardItem]?)? = nil
    ) {
        self.pasteboard = pasteboard
        self.pasteboardItemsReader = pasteboardItemsReader ?? {
            pasteboard.pasteboardItems
        }
    }

    func captureSnapshot() throws -> Snapshot {
        let changeCount = pasteboard.changeCount
        let pasteboardItems = pasteboardItemsReader()
        guard pasteboard.changeCount == changeCount else {
            throw SnapshotError.changedWhileReading
        }
        guard let pasteboardItems else {
            throw SnapshotError.itemsUnavailable
        }

        let items: [Item]
        do {
            items = try Self.snapshotItems(from: pasteboardItems)
        } catch {
            guard pasteboard.changeCount == changeCount else {
                throw SnapshotError.changedWhileReading
            }
            throw error
        }
        guard pasteboard.changeCount == changeCount else {
            throw SnapshotError.changedWhileReading
        }
        return Snapshot(items: items, sourceChangeCount: changeCount)
    }

    func stageCopyProbe(replacing snapshot: Snapshot) -> StageResult {
        stageOwnedItem(
            text: nil,
            expectedChangeCount: snapshot.sourceChangeCount,
            fallback: snapshot
        )
    }

    func copiedText(after probe: Ownership) -> CopiedText? {
        let changeCountBeforeRead = pasteboard.changeCount
        guard changeCountBeforeRead != probe.changeCount,
              pasteboard.data(forType: Self.operationMarkerType) != probe.token,
              let value = pasteboard.string(forType: .string),
              !value.isEmpty,
              pasteboard.changeCount == changeCountBeforeRead else {
            return nil
        }
        return CopiedText(value: value, changeCount: changeCountBeforeRead)
    }

    func stageReplacement(
        _ replacementText: String,
        replacing copiedText: CopiedText,
        original snapshot: Snapshot
    ) -> StageResult {
        guard pasteboard.changeCount == copiedText.changeCount,
              let currentText = pasteboard.string(forType: .string),
              ExactText.matches(currentText, copiedText.value),
              pasteboard.changeCount == copiedText.changeCount else {
            return .sourceChanged
        }

        return stageOwnedItem(
            text: replacementText,
            expectedChangeCount: copiedText.changeCount,
            fallback: snapshot
        )
    }

    func ownershipState(of ownership: Ownership) -> OwnershipState {
        let changeCount = pasteboard.changeCount
        let items = pasteboard.pasteboardItems
        let marker = items?.count == 1
            ? items?[0].data(forType: Self.operationMarkerType)
            : nil
        let visibleText = items?.count == 1
            ? items?[0].string(forType: .string)
            : nil

        return Self.classifyOwnership(
            currentChangeCount: pasteboard.changeCount,
            expectedChangeCount: ownership.changeCount,
            itemCount: items?.count,
            marker: marker,
            expectedToken: ownership.token,
            visibleText: visibleText,
            expectedText: ownership.expectedText,
            changeCountBeforeRead: changeCount
        )
    }

    static func classifyOwnership(
        currentChangeCount: Int,
        expectedChangeCount: Int,
        itemCount: Int?,
        marker: Data?,
        expectedToken: Data,
        visibleText: String?,
        expectedText: String?,
        changeCountBeforeRead: Int
    ) -> OwnershipState {
        guard changeCountBeforeRead == currentChangeCount,
              currentChangeCount == expectedChangeCount,
              itemCount == 1,
              marker == expectedToken else {
            return .lost
        }

        if let expectedText {
            guard let visibleText,
                  ExactText.matches(visibleText, expectedText) else {
                return .lost
            }
        }
        return .owned
    }

    func restore(
        _ snapshot: Snapshot,
        ifOwnedBy ownership: Ownership
    ) -> RestorationResult {
        guard ownershipState(of: ownership) == .owned,
              pasteboard.changeCount == ownership.changeCount else {
            return .ownershipLost
        }
        guard let items = makePasteboardItems(snapshot.items) else {
            return .writeFailed
        }
        guard ownershipState(of: ownership) == .owned,
              pasteboard.changeCount == ownership.changeCount else {
            return .ownershipLost
        }

        pasteboard.clearContents()
        guard items.isEmpty || pasteboard.writeObjects(items) else {
            return .writeFailed
        }
        return .restored
    }

    func restore(
        _ snapshot: Snapshot,
        replacing copiedText: CopiedText
    ) -> RestorationResult {
        let changeCountBeforeRead = pasteboard.changeCount
        guard changeCountBeforeRead == copiedText.changeCount,
              let currentText = pasteboard.string(forType: .string),
              ExactText.matches(currentText, copiedText.value),
              pasteboard.changeCount == changeCountBeforeRead else {
            return .ownershipLost
        }
        guard let items = makePasteboardItems(snapshot.items) else {
            return .writeFailed
        }
        let finalChangeCount = pasteboard.changeCount
        guard finalChangeCount == copiedText.changeCount,
              let finalText = pasteboard.string(forType: .string),
              ExactText.matches(finalText, copiedText.value),
              pasteboard.changeCount == finalChangeCount else {
            return .ownershipLost
        }

        pasteboard.clearContents()
        guard items.isEmpty || pasteboard.writeObjects(items) else {
            return .writeFailed
        }
        return .restored
    }

    static func snapshotItems(
        from pasteboardItems: [NSPasteboardItem]
    ) throws -> [Item] {
        try pasteboardItems.map { item in
            let representations = try item.types.map { type in
                guard let data = item.data(forType: type) else {
                    throw SnapshotError.incomplete
                }
                return Representation(type: type, data: data)
            }
            return Item(representations: representations)
        }
    }

    private func stageOwnedItem(
        text: String?,
        expectedChangeCount: Int,
        fallback snapshot: Snapshot
    ) -> StageResult {
        let token = Data(UUID().uuidString.utf8)
        let item = NSPasteboardItem()
        guard item.setData(token, forType: Self.operationMarkerType),
              text.map({ item.setString($0, forType: .string) }) ?? true else {
            return .writeFailed
        }
        guard pasteboard.changeCount == expectedChangeCount else {
            return .sourceChanged
        }

        let clearedChangeCount = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            restoreAfterFailedStage(snapshot, expectedChangeCount: clearedChangeCount)
            return .writeFailed
        }

        let ownership = Ownership(
            token: token,
            changeCount: pasteboard.changeCount,
            expectedText: text
        )
        guard ownershipState(of: ownership) == .owned else {
            return .writeFailed
        }
        return .staged(ownership)
    }

    private func makePasteboardItems(_ items: [Item]) -> [NSPasteboardItem]? {
        var pasteboardItems: [NSPasteboardItem] = []
        pasteboardItems.reserveCapacity(items.count)

        for item in items {
            let pasteboardItem = NSPasteboardItem()
            for representation in item.representations {
                guard pasteboardItem.setData(
                    representation.data,
                    forType: representation.type
                ) else {
                    return nil
                }
            }
            pasteboardItems.append(pasteboardItem)
        }
        return pasteboardItems
    }

    private func restoreAfterFailedStage(
        _ snapshot: Snapshot,
        expectedChangeCount: Int
    ) {
        guard pasteboardIsStableAndExplicitlyEmpty(
                  expectedChangeCount: expectedChangeCount
              ),
              let items = makePasteboardItems(snapshot.items),
              pasteboardIsStableAndExplicitlyEmpty(
                  expectedChangeCount: expectedChangeCount
              ) else {
            return
        }
        pasteboard.clearContents()
        if !items.isEmpty {
            _ = pasteboard.writeObjects(items)
        }
    }

    private func pasteboardIsStableAndExplicitlyEmpty(
        expectedChangeCount: Int
    ) -> Bool {
        let changeCountBeforeRead = pasteboard.changeCount
        guard changeCountBeforeRead == expectedChangeCount,
              let items = pasteboardItemsReader(),
              items.isEmpty else {
            return false
        }
        return pasteboard.changeCount == changeCountBeforeRead
    }

    #if DEBUG
    func restoreAfterFailedStageForTesting(
        _ snapshot: Snapshot,
        expectedChangeCount: Int
    ) {
        restoreAfterFailedStage(snapshot, expectedChangeCount: expectedChangeCount)
    }
    #endif
}
