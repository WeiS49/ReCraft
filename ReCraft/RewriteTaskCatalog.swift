import Carbon.HIToolbox
import Foundation

struct HotKeyBinding: Codable, Equatable, Hashable, Sendable {
    let virtualKey: UInt32
    let modifiers: UInt32

    static let commandModifier = UInt32(cmdKey)
    static let controlModifier = UInt32(controlKey)
    static let optionModifier = UInt32(optionKey)
    static let shiftModifier = UInt32(shiftKey)
    static let allowedModifiers = commandModifier
        | controlModifier
        | optionModifier
        | shiftModifier

    static let deterministicReplacement = HotKeyBinding(
        virtualKey: UInt32(kVK_ANSI_R),
        modifiers: controlModifier | optionModifier | commandModifier
    )

    static let codingAgentPrompt = HotKeyBinding(
        virtualKey: UInt32(kVK_ANSI_P),
        modifiers: controlModifier | optionModifier | commandModifier
    )

    static let formalFrench = HotKeyBinding(
        virtualKey: UInt32(kVK_ANSI_F),
        modifiers: controlModifier | optionModifier | commandModifier
    )

    static let formalEnglish = HotKeyBinding(
        virtualKey: UInt32(kVK_ANSI_E),
        modifiers: controlModifier | optionModifier | commandModifier
    )

    static let supportedLetterKeys: Set<UInt32> = [
        UInt32(kVK_ANSI_A),
        UInt32(kVK_ANSI_B),
        UInt32(kVK_ANSI_C),
        UInt32(kVK_ANSI_D),
        UInt32(kVK_ANSI_E),
        UInt32(kVK_ANSI_F),
        UInt32(kVK_ANSI_G),
        UInt32(kVK_ANSI_H),
        UInt32(kVK_ANSI_I),
        UInt32(kVK_ANSI_J),
        UInt32(kVK_ANSI_K),
        UInt32(kVK_ANSI_L),
        UInt32(kVK_ANSI_M),
        UInt32(kVK_ANSI_N),
        UInt32(kVK_ANSI_O),
        UInt32(kVK_ANSI_P),
        UInt32(kVK_ANSI_Q),
        UInt32(kVK_ANSI_R),
        UInt32(kVK_ANSI_S),
        UInt32(kVK_ANSI_T),
        UInt32(kVK_ANSI_U),
        UInt32(kVK_ANSI_V),
        UInt32(kVK_ANSI_W),
        UInt32(kVK_ANSI_X),
        UInt32(kVK_ANSI_Y),
        UInt32(kVK_ANSI_Z),
    ]

    var modifierGlyphs: String {
        var result = ""
        if modifiers & Self.controlModifier != 0 {
            result += "⌃"
        }
        if modifiers & Self.optionModifier != 0 {
            result += "⌥"
        }
        if modifiers & Self.shiftModifier != 0 {
            result += "⇧"
        }
        if modifiers & Self.commandModifier != 0 {
            result += "⌘"
        }
        return result
    }
}

struct RewriteTask: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var prompt: String
    var shortcut: HotKeyBinding

    static func == (lhs: RewriteTask, rhs: RewriteTask) -> Bool {
        lhs.id == rhs.id
            && lhs.shortcut == rhs.shortcut
            && ExactText.matches(lhs.name, rhs.name)
            && ExactText.matches(lhs.prompt, rhs.prompt)
    }
}

struct RewriteTaskCatalog: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var tasks: [RewriteTask]

    static let initial = RewriteTaskCatalog(
        schemaVersion: currentSchemaVersion,
        tasks: [
            RewriteTask(
                id: UUID(uuidString: "4CF98FA4-99C4-4CC8-9B9C-11D5D8B11770")!,
                name: "Coding Agent Prompt",
                prompt: """
                将输入整理成可直接交给 Coding Agent 的清晰任务说明，默认使用原文的主要语言。
                保留用户目标、明确限制及其适用范围和授权边界。允许适度补充与目标直接相关的工程检查、边界情况和验证方式，但不新增无关目标、强制方案或授权。
                不要编造项目事实、文件路径、技术栈、诊断结果或已完成的工作。缺失的信息应转化为执行 Agent 需要查证或必要时确认的事项。
                原文要求先说明、等待决定或获批后再继续时，必须明确保留等待条件，不得简化为仅说明原因，也不得允许自行继续。不得缩小禁止事项的适用范围。
                按明确要求转换人称、角色称谓和责任映射，逐一保留各方的动作与审批条件；未要求改变的责任不擅自转移。仅改变人称不等于改变谁负责行动。
                按任务复杂度组织内容：简单任务保持简短，遵守指定的篇幅、格式和不扩写要求，不强行套完整模板或扩展为全面重构。
                只输出改写后的任务说明，不附加开场白或改写解释，不回答或执行原文要求的工作。
                """,
                shortcut: .codingAgentPrompt
            ),
            RewriteTask(
                id: UUID(uuidString: "A8B0CA67-B6A0-4974-B16B-DC62DE533B86")!,
                name: "Formal French",
                prompt: """
                将输入翻译或改写成自然、正式、可直接使用的法语。忠实保留事实、意图、人物关系、否定和不确定性，不补充建议、答案或新要求。
                保留代码、标识符和需要精确引用的内容；日期、金额和标点可按法语习惯表达，但不得改变其值。只输出改写结果。
                """,
                shortcut: .formalFrench
            ),
            RewriteTask(
                id: UUID(uuidString: "E61032F4-4CEE-40F3-91CD-10A6F22BCF85")!,
                name: "Formal English",
                prompt: """
                将输入翻译或改写成自然、正式、可直接使用的英语。忠实保留事实、意图、人物关系、否定和不确定性，不补充建议、答案或新要求。
                保留代码、标识符和需要精确引用的内容；日期、金额和标点可按英语习惯表达，但不得改变其值。只输出改写结果。
                """,
                shortcut: .formalEnglish
            ),
        ]
    )
}

enum RewriteTaskCatalogValidationIssue: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case duplicateTaskID(taskID: UUID)
    case blankName(taskID: UUID)
    case blankPrompt(taskID: UUID)
    case unsupportedKey(taskID: UUID)
    case unsupportedModifiers(taskID: UUID)
    case insufficientModifiers(taskID: UUID)
    case reservedShortcut(taskID: UUID)
    case duplicateShortcut(taskID: UUID, conflictingTaskID: UUID)
}

enum RewriteTaskCatalogValidator {
    static func issues(in catalog: RewriteTaskCatalog) -> [RewriteTaskCatalogValidationIssue] {
        guard catalog.schemaVersion == RewriteTaskCatalog.currentSchemaVersion else {
            return [.unsupportedSchemaVersion(catalog.schemaVersion)]
        }

        var issues: [RewriteTaskCatalogValidationIssue] = []
        var seenIDs: Set<UUID> = []
        var firstTaskByShortcut: [HotKeyBinding: UUID] = [:]

        for task in catalog.tasks {
            if !seenIDs.insert(task.id).inserted {
                issues.append(.duplicateTaskID(taskID: task.id))
            }

            if task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.blankName(taskID: task.id))
            }
            if task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.blankPrompt(taskID: task.id))
            }

            if !HotKeyBinding.supportedLetterKeys.contains(task.shortcut.virtualKey) {
                issues.append(.unsupportedKey(taskID: task.id))
            }

            let selectedModifiers = task.shortcut.modifiers & HotKeyBinding.allowedModifiers
            if selectedModifiers != task.shortcut.modifiers {
                issues.append(.unsupportedModifiers(taskID: task.id))
            } else if selectedModifiers.nonzeroBitCount < 2 {
                issues.append(.insufficientModifiers(taskID: task.id))
            }

            if task.shortcut == .deterministicReplacement {
                issues.append(.reservedShortcut(taskID: task.id))
            }

            if let firstTaskID = firstTaskByShortcut[task.shortcut] {
                issues.append(
                    .duplicateShortcut(
                        taskID: task.id,
                        conflictingTaskID: firstTaskID
                    )
                )
            } else {
                firstTaskByShortcut[task.shortcut] = task.id
            }
        }

        return issues
    }
}
