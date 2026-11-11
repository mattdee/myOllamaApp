import SwiftUI
import AppKit

@main
struct OllamaChatApp: App {
    var body: some Scene {
        Window("Ollama Chat", id: "main") { ContentView() }
            .defaultSize(width: 1040, height: 760)
    }
}

struct Conversation: Codable, Identifiable {
    var id = UUID()
    var title = "New conversation"
    var messages: [ChatMessage] = []
}

@MainActor
@Observable
final class ChatStore {
    var conversations: [Conversation] = []
    var selected: UUID?
    var models: [String] = []
    var model = UserDefaults.standard.string(forKey: "model") ?? ""
    var endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? "http://localhost:11434/api/chat"
    var draft = ""
    var error: String?
    var status = "Connecting…"
    var running = false
    var refreshing = false
    var task: Task<Void, Never>?
    private let client = OllamaClient()
    private var file: URL {
        URL.applicationSupportDirectory.appendingPathComponent("OllamaChat/conversations.json")
    }
    var current: Conversation? { conversations.first { $0.id == selected } }

    init() {
        do { conversations = try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: file)) }
        catch { if FileManager.default.fileExists(atPath: file.path) { self.error = "Saved conversations could not be read: \(error.localizedDescription)" } }
        if conversations.isEmpty { newChat() } else { selected = conversations.first?.id }
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(conversations).write(to: file, options: .atomic)
        } catch { self.error = "Could not save conversations: \(error.localizedDescription)" }
    }
    func newChat() {
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        selected = conversation.id
        draft = ""
        save()
    }
    func deleteCurrent() {
        guard !running else { return }
        conversations.removeAll { $0.id == selected }
        selected = conversations.first?.id
        if conversations.isEmpty { newChat() }
        save()
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        UserDefaults.standard.set(endpoint, forKey: "endpoint")
        do {
            models = try await client.models(endpoint: endpoint)
            if !models.contains(model) { model = models.first ?? "" }
            status = models.isEmpty ? "No models installed" : "Ollama connected"
            if models.isEmpty { error = "Install a model in Terminal, for example: ollama pull llama3.2. Then refresh the model list." }
        } catch {
            status = "Ollama unavailable"
            self.error = "Could not connect to Ollama. Start the Ollama app or run ‘ollama serve’, then refresh. \(error.localizedDescription)"
        }
    }
    func stop() { task?.cancel() }
    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running, !prompt.isEmpty, !model.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == selected }) else { return }
        error = nil
        draft = ""
        UserDefaults.standard.set(model, forKey: "model")
        UserDefaults.standard.set(endpoint, forKey: "endpoint")
        if conversations[index].messages.isEmpty { conversations[index].title = String(prompt.prefix(48)) }
        conversations[index].messages.append(ChatMessage(role: "user", content: prompt))
        let history = conversations[index].messages.filter { !$0.content.isEmpty }
        let conversationID = conversations[index].id
        let reply = ChatMessage(role: "assistant", content: "")
        conversations[index].messages.append(reply)
        running = true
        save()
        let endpoint = endpoint, model = model
        task = Task {
            defer { running = false; task = nil; save() }
            do {
                try await client.stream(endpoint: endpoint, model: model, messages: history) { chunk in
                    guard let i = self.conversations.firstIndex(where: { $0.id == conversationID }),
                          let j = self.conversations[i].messages.firstIndex(where: { $0.id == reply.id }) else { return }
                    self.conversations[i].messages[j].content += chunk.message?.content ?? ""
                    if let thinking = chunk.message?.thinking {
                        self.conversations[i].messages[j].thinking = (self.conversations[i].messages[j].thinking ?? "") + thinking
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

struct ContentView: View {
    @State private var store = ChatStore()
    @State private var showSettings = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Ollama Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.title2.bold()).padding(.horizontal).padding(.top, 20)
                Button(action: store.newChat) { Label("New conversation", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).padding(.horizontal).disabled(store.running)
                    .keyboardShortcut("n", modifiers: .command)
                List(selection: $store.selected) {
                    ForEach(store.conversations) { chat in
                        Label(chat.title, systemImage: "bubble.left").lineLimit(1).tag(chat.id)
                    }
                }.listStyle(.sidebar).disabled(store.running)
                HStack {
                    Circle().fill(store.status == "Ollama connected" ? .green : .orange).frame(width: 7, height: 7)
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Connection settings")
                }.padding()
            }.navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.current?.title ?? "New conversation").font(.headline).lineLimit(1)
                        Text("Your local AI workspace").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Model", selection: $store.model) {
                        if store.models.isEmpty { Text("Select a model").tag("") }
                        ForEach(store.models, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 240).disabled(store.running)
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(store.refreshing || store.running).help("Refresh models")
                }.padding(20)
                Divider()
                if let error = store.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.font(.callout).padding().background(.orange.opacity(0.12))
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            if store.current?.messages.isEmpty != false {
                                VStack(spacing: 14) {
                                    Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.teal)
                                    Text("A little curiosity goes a long way.").font(.title2.bold())
                                    Text("Choose a local model and start a conversation.").foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.top, 110)
                            }
                            ForEach(store.current?.messages ?? []) { message in
                                MessageView(message: message)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(28).frame(maxWidth: 900).frame(maxWidth: .infinity)
                    }
                    .onChange(of: store.current?.messages.last?.content) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: store.current?.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                VStack(spacing: 10) {
                    HStack(alignment: .bottom, spacing: 12) {
                        TextField("Message your local model…", text: $store.draft, axis: .vertical)
                            .textFieldStyle(.plain).lineLimit(1...8)
                            .onSubmit { store.send() }
                            .disabled(store.running)
                        if store.running {
                            Button(action: store.stop) { Label("Stop", systemImage: "stop.fill") }.buttonStyle(.bordered)
                        } else {
                            Button(action: store.send) { Image(systemName: "arrow.up").fontWeight(.bold).padding(5) }
                                .buttonStyle(.borderedProminent).tint(.teal)
                                .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.model.isEmpty)
                                .keyboardShortcut(.return, modifiers: .command)
                        }
                    }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.12)))
                    Text(store.running ? "Generating locally…" : "Return to send · Shift-Return for a new line · Chats saved on this Mac")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                Button(role: .destructive, action: store.deleteCurrent) { Label("Delete conversation", systemImage: "trash") }.disabled(store.running)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .task { await store.refresh() }
        .sheet(isPresented: $showSettings) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connection settings").font(.title2.bold())
                Text("Ollama chat endpoint").font(.headline)
                TextField("http://localhost:11434/api/chat", text: $store.endpoint).textFieldStyle(.roundedBorder)
                Text("Start Ollama on your Mac. Installed models are discovered through /api/tags on the same server.")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("Save & reconnect") { showSettings = false; Task { await store.refresh() } }.buttonStyle(.borderedProminent) }
            }.padding(28).frame(width: 470)
        }
    }
}

struct MessageView: View {
    let message: ChatMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(message.role == "user" ? "You" : "Ollama", systemImage: message.role == "user" ? "person.crop.circle" : "sparkles")
                    .font(.callout.bold()).foregroundStyle(message.role == "user" ? Color.secondary : .teal)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Copy message")
            }
            if let thinking = message.thinking, !thinking.isEmpty {
                DisclosureGroup("Thinking") { Text(thinking).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if message.content.isEmpty {
                Text("…").foregroundStyle(.secondary)
            } else {
                Text(.init(message.content)).textSelection(.enabled).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(18).background(message.role == "user" ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 14))
    }
}
