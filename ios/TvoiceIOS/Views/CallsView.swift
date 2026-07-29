import SwiftUI

struct CallsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var number = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Номер абонента", text: $number)
                    .keyboardType(.phonePad)
                    .font(.title2.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                    ForEach(["1","2","3","4","5","6","7","8","9","*","0","#"], id: \.self) { digit in
                        Button(digit) { number.append(digit) }
                            .font(.title2)
                            .frame(width: 64, height: 54)
                            .buttonStyle(.bordered)
                    }
                }
                HStack(spacing: 28) {
                    Button {
                        model.errorMessage = "SIP-аудиодвижок iOS подключается на следующем этапе"
                    } label: {
                        Image(systemName: "phone.fill")
                            .frame(width: 58, height: 58)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    Button {
                        Task { await model.startVideoCall(peer: number) }
                    } label: {
                        Image(systemName: "video.fill")
                            .frame(width: 58, height: 58)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Звонки")
        }
    }
}
