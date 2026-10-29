import Security
import SwiftUI

/// Where the app's choices are kept.
enum FinderSettings {
    /// Whether the last video was searched with Claude, which the next one starts with.
    static let useClaudeKey = "useClaude"
    static let modelKey = "claudeModel"
}

/// The Claude API key, kept in the Keychain rather than in settings or the code.
nonisolated enum APIKeyStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ClaudeAPIKey"]
    }

    static var key: String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty key removes it.
    static func save(_ key: String) {
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        // Readable while the phone is locked, so a run in the background can still use it.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FinderSettings.modelKey) private var model = ClaudeExtractor.Model.haiku.rawValue
    @State private var apiKey = APIKeyStore.key ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Model", selection: $model) {
                        ForEach(ClaudeExtractor.Model.allCases) { model in
                            VStack(alignment: .leading) {
                                Text(model.name)
                                Text(model.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(model.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Claude model")
                } footer: {
                    Text("Used when you pick Claude for a video. Only the video's transcript and screen text are sent to Anthropic; the video and its audio stay on your iPhone.")
                }

                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API key")
                } footer: {
                    Text("Create a key at console.anthropic.com. API use is billed there, separately from a Claude subscription. The key is stored in your iPhone's Keychain.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
            // Saved however the sheet is closed, including by swiping it down.
            .onDisappear {
                APIKeyStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
