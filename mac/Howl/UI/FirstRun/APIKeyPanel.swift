import SwiftUI
import HowlCore

struct APIKeyPanel: View {
    let secrets: any SecretStore
    let onComplete: () -> Void
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill").font(.system(size: 60))
            Text("Anthropic API Key").font(.title)
            Text("Paste your API key. It's stored securely in the macOS Keychain.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            SecureField("sk-ant-...", text: $key)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            if let error = error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Link("Get one from console.anthropic.com",
                     destination: URL(string: "https://console.anthropic.com/")!)
                Spacer()
                Button("Save & Continue") {
                    do {
                        try secrets.setAPIKey(key, forProvider: "anthropic")
                        onComplete()
                    } catch let err {
                        error = "\(err)"
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!key.hasPrefix("sk-ant-"))
            }
        }
        .padding(40)
    }
}
