import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var number = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(.tvoiceBlue)
                Text("Tvoice")
                    .font(.largeTitle.bold())
                Text("Один логин для FreePBX, чата и видеозвонков")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 14) {
                    TextField("SIP-номер", text: $number)
                        .keyboardType(.phonePad)
                        .textContentType(.username)
                    SecureField("Пароль", text: $password)
                        .textContentType(.password)
                }
                .textFieldStyle(.roundedBorder)

                Button {
                    Task { await model.login(number: number, password: password) }
                } label: {
                    HStack {
                        if model.isBusy { ProgressView().tint(.white) }
                        Text("Войти").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || number.isEmpty || password.isEmpty)
                Spacer()
            }
            .padding(24)
        }
    }
}
