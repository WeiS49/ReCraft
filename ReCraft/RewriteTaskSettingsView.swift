import SwiftUI

struct RewriteTaskSettingsView: View {
    @ObservedObject var model: RewriteTaskSettingsModel
    @ObservedObject var providerSettings: ProviderAPIKeySettingsModel
    @State private var pendingDeletionTaskID: UUID?
    @State private var isConfirmingReset = false
    @State private var isConfirmingGeneration = false

    var body: some View {
        Group {
            if model.isReadOnlyRecovery {
                recoveryView
            } else if model.isBlockingFailure {
                blockingFailureView
            } else {
                readyView
            }
        }
        .confirmationDialog(
            "Delete this rewrite task?",
            isPresented: isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Task", role: .destructive) {
                if let pendingDeletionTaskID {
                    model.deleteTaskAfterConfirmation(pendingDeletionTaskID)
                }
                pendingDeletionTaskID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletionTaskID = nil
            }
        } message: {
            Text("The deletion changes only the draft until the complete catalog is saved successfully.")
        }
        .confirmationDialog(
            "Reset rewrite tasks?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset Rewrite Tasks", role: .destructive) {
                model.resetAfterUserConfirmation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the stored task configuration and restores the three initial tasks. The API key is not changed.")
        }
        .confirmationDialog(
            "Replace the draft name and prompt?",
            isPresented: $isConfirmingGeneration,
            titleVisibility: .visible
        ) {
            Button("Generate and Replace") {
                Task {
                    await model.generatePrompt(confirmedReplacement: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The generated name and prompt replace this task’s current draft. Nothing is saved until you click Save.")
        }
    }

    private var readyView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 245)

                Divider()

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Rewrite Tasks")
                    .font(.headline)
                Spacer()
                Button {
                    model.addTask()
                } label: {
                    Label("Add Task", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("Add Task")
                .accessibilityLabel("Add rewrite task")

                Button {
                    pendingDeletionTaskID = model.selectedTaskID
                } label: {
                    Label("Delete Task", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .help("Delete Selected Task")
                .accessibilityLabel("Delete selected rewrite task")
                .disabled(model.selectedTaskID == nil)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if model.tasks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No Rewrite Tasks")
                        .font(.headline)
                    Text("Only the test replacement shortcut remains active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add Task") {
                        model.addTask()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
            } else {
                List(selection: selectedTaskBinding) {
                    ForEach(model.tasks) { task in
                        taskRow(task)
                            .tag(task.id)
                    }
                }
                .accessibilityLabel("Rewrite task list")
            }
        }
        .background(.background.secondary)
    }

    @ViewBuilder
    private var detail: some View {
        if let task = model.selectedTask {
            taskEditor(task)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.cursor")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(model.tasks.isEmpty ? "Add a task to begin" : "Select a rewrite task")
                    .font(.headline)
                if model.tasks.isEmpty {
                    Button("Add Task") {
                        model.addTask()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func taskEditor(_ task: RewriteTask) -> some View {
        let errors = model.fieldErrors[task.id] ?? RewriteTaskSettingsFieldErrors()

        return Form {
            Section("Task") {
                promptGenerationArea

                TextField("Name", text: taskNameBinding)
                    .accessibilityLabel("Task name")
                fieldError(errors.name)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Complete Prompt")
                    TextEditor(text: taskPromptBinding)
                        .font(.body)
                        .frame(minHeight: 150)
                        .padding(4)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator)
                        }
                        .accessibilityLabel("Complete task prompt")
                }
                fieldError(errors.prompt)
            }

            Section("Shortcut") {
                HStack {
                    ShortcutRecorder(
                        binding: task.shortcut,
                        isRecording: model.recordingTaskID == task.id,
                        isEnabled: !model.isSaving,
                        onBeginRecording: {
                            model.beginShortcutRecording(for: task.id)
                        },
                        onEndRecording: {
                            model.endShortcutRecording()
                        },
                        onCapture: { binding in
                            _ = model.captureUnregisteredShortcutFromFocusedRecorder(binding)
                        },
                        onRejectedInput: { message in
                            model.rejectRecorderInput(message, for: task.id)
                        }
                    )
                    .frame(width: 170)

                    Text("A–Z with at least two modifier keys")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                fieldError(errors.shortcut)
            }

            Section("Storage and API Use") {
                Text("Task names and prompts are stored as plaintext in ReCraft’s local preferences. They are not written to diagnostic logs.")
                Text(providerSettings.selectedProvider.taskPromptDisclosure)
                Text(providerSettings.selectedProvider.promptGenerationDisclosure)
                Text("ReCraft checks prompt structure, not the semantic quality of arbitrary user-authored prompts.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .formStyle(.grouped)
    }

    private var promptGenerationArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Describe the task")
            TextEditor(text: $model.generationDescription)
                .font(.body)
                .frame(minHeight: 54)
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator)
                }
                .accessibilityLabel("Task description for prompt generation")

            HStack(spacing: 8) {
                Button("Generate Prompt") {
                    requestPromptGeneration()
                }
                .disabled(!model.canGeneratePrompt)

                if model.isGeneratingPrompt {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating…")
                        .foregroundStyle(.secondary)
                }
            }

            if let notice = model.promptGenerationNotice {
                switch notice.tone {
                case .success:
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Prompt generation: \(notice.message)")
                case .failure:
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Prompt generation error: \(notice.message)")
                }
            }
        }
    }

    private func requestPromptGeneration() {
        if model.promptGenerationRequiresConfirmation {
            isConfirmingGeneration = true
        } else {
            Task {
                await model.generatePrompt()
            }
        }
    }

    private var footer: some View {
        HStack {
            if let statusMessage = model.statusMessage {
                switch model.statusTone {
                case .success, .neutral:
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Rewrite task status: \(statusMessage)")
                case .warning:
                    Text(statusMessage)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Rewrite task status: \(statusMessage)")
                case .failure:
                    Text(statusMessage)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Rewrite task status: \(statusMessage)")
                }
            } else if model.isDirty {
                Label("Unsaved changes", systemImage: "circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Text("All changes saved")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel") {
                model.cancel()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(!model.isDirty || model.isSaving)

            Button("Save") {
                model.save()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave)
        }
        .padding(12)
    }

    private var recoveryView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Rewrite Task Settings Unavailable")
                .font(.title2)
            Text(model.statusMessage ?? "The stored configuration could not be read and was left unchanged.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Text("Editing and remote task shortcuts remain disabled until the catalog is reset.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset Rewrite Tasks…", role: .destructive) {
                isConfirmingReset = true
            }
            .accessibilityHint("Requires confirmation and restores the three initial tasks")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var blockingFailureView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.octagon")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text("Rewrite Task Shortcuts Blocked")
                .font(.title2)
            Text(model.statusMessage ?? "Shortcut recovery failed.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Text("Remote task shortcuts are disabled for this process. Quit and relaunch ReCraft before using or editing rewrite tasks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskRow(_ task: RewriteTask) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name.isEmpty ? "Untitled Task" : task.name)
                    .lineLimit(1)
                Text(shortcutLabel(task.shortcut))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.fieldErrors[task.id] != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Task has an error")
            } else if model.isTaskModified(task.id) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Unsaved changes")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func fieldError(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Error: \(message)")
        }
    }

    private func shortcutLabel(_ binding: HotKeyBinding) -> String {
        guard HotKeyBinding.supportedLetterKeys.contains(binding.virtualKey),
              binding.modifiers.nonzeroBitCount >= 2 else {
            return "Shortcut not set"
        }
        return HotKeyDisplayLabel.make(for: binding)
    }

    private var selectedTaskBinding: Binding<UUID?> {
        Binding(
            get: { model.selectedTaskID },
            set: { model.selectTask($0) }
        )
    }

    private var taskNameBinding: Binding<String> {
        Binding(
            get: { model.selectedTask?.name ?? "" },
            set: { model.updateSelectedTaskName($0) }
        )
    }

    private var taskPromptBinding: Binding<String> {
        Binding(
            get: { model.selectedTask?.prompt ?? "" },
            set: { model.updateSelectedTaskPrompt($0) }
        )
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletionTaskID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletionTaskID = nil
                }
            }
        )
    }
}
