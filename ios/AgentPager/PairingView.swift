import SwiftUI

struct PairingView: View {
    let model: AppModel
    @State private var pastedText = ""
    @State private var isScanning = false
    @State private var isPairing = false

    var body: some View {
        Form {
            Section {
                Text("在 Mac 上打开 AgentPager Bridge，找到配对二维码，用这台设备扫描；也可以点“复制配对文本”后粘贴到下方。两台设备需要在同一个局域网。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    model.clearPairingError()
                    isScanning = true
                } label: {
                    Label("扫描二维码", systemImage: "qrcode.viewfinder")
                }
            }

            Section("粘贴配对文本") {
                TextEditor(text: $pastedText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 96)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("使用配对文本") {
                    pair(pastedText)
                }
                .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPairing)
            }

            if let error = model.pairingError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("配对 Mac")
        .fullScreenCover(isPresented: $isScanning) {
            ScannerSheet { code in
                isScanning = false
                pair(code)
            } onCancel: {
                isScanning = false
            }
        }
    }

    private func pair(_ text: String) {
        isPairing = true
        Task {
            _ = await model.pair(with: text)
            isPairing = false
        }
    }
}

private struct ScannerSheet: View {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScannerView(onCode: onCode)
                .ignoresSafeArea()
            Button("取消", action: onCancel)
                .buttonStyle(.borderedProminent)
                .padding()
        }
    }
}
