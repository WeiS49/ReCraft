import AppKit
import XCTest

@MainActor
final class AppKitEditabilityCapabilityTests: XCTestCase {
    func testDetachedSyntheticControlsRecordBlockedCapabilityMatrix() throws {
        let rows = makeFixtures().map(probe)
        let candidates = rows.map(evaluateCandidate)
        let matrix = CapabilityMatrix(
            schemaVersion: 1,
            scope: "detached-in-process-appkit-controls",
            candidateRuleStatus: "blocked-no-separating-ax-evidence",
            rows: rows,
            candidates: candidates,
            counterexamples: [
                Evidence(
                    signal: "AXEnabled",
                    result: "insufficient",
                    witness: Fixture.readOnlySelectable.rawValue
                ),
                Evidence(
                    signal: "AXRole",
                    result: "unavailable-in-detached-fixtures",
                    witness: nil
                ),
                Evidence(
                    signal: "copy-success",
                    result: "not-probed-by-design-and-insufficient-alone",
                    witness: nil
                ),
                Evidence(
                    signal: "single-settable-attribute",
                    result: "unavailable-in-detached-fixtures-and-insufficient-alone",
                    witness: nil
                ),
            ],
            unknowns: [
                "focused-field-editor-behavior",
                "off-process-ax-parity",
                "copy-and-paste-delivery",
                "exact-mutation-and-native-undo",
                "non-appkit-editor-behavior",
                "secure-field-ax-metadata-when-detached",
            ]
        )
        addAttachment(matrix)

        XCTAssertEqual(rows.map(\.fixture), Fixture.allCases)
        XCTAssertEqual(Set(rows.map(\.controlClass)).count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.copyObservation == "not-probed" })

        let editable = try row(.editable, in: rows)
        let readOnly = try row(.readOnlySelectable, in: rows)
        let disabled = try row(.disabled, in: rows)
        let secure = try row(.secure, in: rows)

        XCTAssertTrue(editable.configuredEditable)
        XCTAssertTrue(editable.configuredSelectable)
        XCTAssertTrue(editable.axEnabled)
        XCTAssertFalse(readOnly.configuredEditable)
        XCTAssertTrue(readOnly.configuredSelectable)
        XCTAssertTrue(readOnly.axEnabled)
        XCTAssertTrue(disabled.configuredEditable)
        XCTAssertFalse(disabled.axEnabled)
        XCTAssertTrue(secure.configuredEditable)
        XCTAssertTrue(secure.axEnabled)
        XCTAssertFalse(secure.axProtectedContent)
        XCTAssertNil(secure.axSubrole)

        XCTAssertEqual(editable.axRole, NSAccessibility.Role.unknown.rawValue)
        XCTAssertEqual(readOnly.axRole, editable.axRole)
        XCTAssertEqual(disabled.axRole, editable.axRole)
        XCTAssertEqual(secure.axRole, editable.axRole)
        XCTAssertTrue(rows.allSatisfy { row in
            row.settable.values.allSatisfy { $0 == .unavailable }
        })
        XCTAssertEqual(editable.settable, readOnly.settable)

        XCTAssertEqual(
            try candidate(.editable, in: candidates).disposition,
            .unknown
        )
        XCTAssertEqual(
            try candidate(.readOnlySelectable, in: candidates).disposition,
            .unknown
        )
        XCTAssertEqual(
            try candidate(.disabled, in: candidates).disposition,
            .reject
        )
        XCTAssertEqual(
            try candidate(.secure, in: candidates).disposition,
            .unknown
        )
        XCTAssertFalse(candidates.contains { $0.disposition == .candidate })
        XCTAssertEqual(
            matrix.candidateRuleStatus,
            "blocked-no-separating-ax-evidence"
        )
    }

    private func makeFixtures() -> [ControlFixture] {
        [
            ControlFixture(
                kind: .editable,
                control: makeTextField(editable: true, selectable: true, enabled: true)
            ),
            ControlFixture(
                kind: .readOnlySelectable,
                control: makeTextField(editable: false, selectable: true, enabled: true)
            ),
            ControlFixture(
                kind: .disabled,
                control: makeTextField(editable: true, selectable: true, enabled: false)
            ),
            ControlFixture(kind: .secure, control: makeSecureTextField()),
        ]
    }

    private func makeTextField(
        editable: Bool,
        selectable: Bool,
        enabled: Bool
    ) -> NSTextField {
        let control = NSTextField(frame: .zero)
        configure(
            control,
            editable: editable,
            selectable: selectable,
            enabled: enabled
        )
        return control
    }

    private func makeSecureTextField() -> NSSecureTextField {
        let control = NSSecureTextField(frame: .zero)
        configure(control, editable: true, selectable: true, enabled: true)
        return control
    }

    private func configure(
        _ control: NSTextField,
        editable: Bool,
        selectable: Bool,
        enabled: Bool
    ) {
        control.stringValue = "Synthetic AppKit capability fixture"
        control.isEditable = editable
        control.isSelectable = selectable
        control.isEnabled = enabled
    }

    private func probe(_ fixture: ControlFixture) -> CapabilityRow {
        let advertisedAttributes = Set(
            fixture.control.accessibilityAttributeNames().map(\.rawValue)
        )
        let attributes: [NSAccessibility.Attribute] = [
            .value,
            .selectedText,
            .selectedTextRange,
            .visibleCharacterRange,
        ]
        let settable = Dictionary(uniqueKeysWithValues: attributes.map { attribute in
            (attribute.rawValue, settableState(
                attribute,
                on: fixture.control,
                advertisedAttributes: advertisedAttributes
            ))
        })

        return CapabilityRow(
            fixture: fixture.kind,
            controlClass: NSStringFromClass(type(of: fixture.control)),
            configuredEditable: fixture.control.isEditable,
            configuredSelectable: fixture.control.isSelectable,
            axRole: fixture.control.accessibilityRole()?.rawValue,
            axSubrole: fixture.control.accessibilitySubrole()?.rawValue,
            axEnabled: fixture.control.isAccessibilityEnabled(),
            axProtectedContent: fixture.control.isAccessibilityProtectedContent(),
            settable: settable,
            copyObservation: "not-probed"
        )
    }

    private func settableState(
        _ attribute: NSAccessibility.Attribute,
        on control: NSTextField,
        advertisedAttributes: Set<String>
    ) -> SettableState {
        guard advertisedAttributes.contains(attribute.rawValue) else {
            return .unavailable
        }

        // The generic API is deprecated, but it answers the exact metadata
        // question under investigation without reading attribute values.
        return control.accessibilityIsAttributeSettable(attribute)
            ? .settable
            : .readOnly
    }

    private func evaluateCandidate(_ row: CapabilityRow) -> CandidateResult {
        guard row.axEnabled else {
            return CandidateResult(
                fixture: row.fixture,
                disposition: .reject,
                reason: "disabled"
            )
        }
        if row.axProtectedContent
            || row.axSubrole == NSAccessibility.Subrole.secureTextField.rawValue {
            return CandidateResult(
                fixture: row.fixture,
                disposition: .reject,
                reason: "protected-or-secure"
            )
        }
        guard row.axRole == NSAccessibility.Role.textField.rawValue
            || row.axRole == NSAccessibility.Role.textArea.rawValue else {
            return CandidateResult(
                fixture: row.fixture,
                disposition: .unknown,
                reason: "text-role-unavailable"
            )
        }
        guard row.settable.values.contains(.settable) else {
            return CandidateResult(
                fixture: row.fixture,
                disposition: .unknown,
                reason: "mutation-metadata-unavailable"
            )
        }
        return CandidateResult(
            fixture: row.fixture,
            disposition: .candidate,
            reason: "metadata-screen-only"
        )
    }

    private func addAttachment(_ matrix: CapabilityMatrix) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(matrix) else {
            XCTFail("capability-matrix-encoding-failed")
            return
        }

        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "appkit-editability-capability-matrix.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func row(
        _ fixture: Fixture,
        in rows: [CapabilityRow]
    ) throws -> CapabilityRow {
        try XCTUnwrap(rows.first { $0.fixture == fixture })
    }

    private func candidate(
        _ fixture: Fixture,
        in candidates: [CandidateResult]
    ) throws -> CandidateResult {
        try XCTUnwrap(candidates.first { $0.fixture == fixture })
    }
}

private struct ControlFixture {
    let kind: Fixture
    let control: NSTextField
}

private struct CapabilityMatrix: Codable {
    let schemaVersion: Int
    let scope: String
    let candidateRuleStatus: String
    let rows: [CapabilityRow]
    let candidates: [CandidateResult]
    let counterexamples: [Evidence]
    let unknowns: [String]
}

private struct CapabilityRow: Codable {
    let fixture: Fixture
    let controlClass: String
    let configuredEditable: Bool
    let configuredSelectable: Bool
    let axRole: String?
    let axSubrole: String?
    let axEnabled: Bool
    let axProtectedContent: Bool
    let settable: [String: SettableState]
    let copyObservation: String
}

private struct CandidateResult: Codable {
    let fixture: Fixture
    let disposition: CandidateDisposition
    let reason: String
}

private struct Evidence: Codable {
    let signal: String
    let result: String
    let witness: String?
}

private enum Fixture: String, Codable, CaseIterable {
    case editable
    case readOnlySelectable
    case disabled
    case secure
}

private enum SettableState: String, Codable {
    case settable
    case readOnly
    case unavailable
}

private enum CandidateDisposition: String, Codable {
    case candidate
    case reject
    case unknown
}
