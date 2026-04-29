import SwiftUI
import Foundation
import UIKit

enum AppConfig {
    static let licenseServerBaseURL = "https://rb-remote-server.rbremote-mariana.workers.dev"
    static let updateManifestURLString = ""
    static let currentVersionCode = 1
    static let currentVersionName = "1.0"
}

@main
struct RBRemoteApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var connection = ConnectionStore.load()
    @Published var license = LicenseStore.load()
    @Published var playbackInfo = PlaybackInfo.empty
    @Published var isConnected = false
    @Published var isLoading = false
    @Published var showLogin = false
    @Published var showTutorial = false
    @Published var showPremiumPrompt = false
    @Published var showPaymentEmail = false
    @Published var toastMessage = ""
    @Published var availableUpdate: UpdateInfo?
    @Published var showUpdateAlert = false

    private var refreshTimer: Timer?
    private let radioBoss = RadioBossClient()
    private let licenseClient = LicenseClient()
    private let updateClient = UpdateClient()

    var hasPremiumAccess: Bool {
        license?.isPremium == true
    }

    var loginText: String {
        license?.login ?? ""
    }

    var accountLabel: String {
        license?.displayLabel ?? "FREE"
    }

    var premiumDaysText: String? {
        guard let license, license.displayLabel == "PREMIUM" else { return nil }
        guard let date = ISO8601DateFormatter().date(from: license.premiumUntil), date > Date() else { return nil }
        let seconds = date.timeIntervalSince(Date())
        let days = max(1, Int(ceil(seconds / 86_400)))
        return days == 1 ? "Expira em 1 dia" : "Expira em \(days) dias"
    }

    func start() {
        if license?.hasLogin != true {
            showLogin = true
        } else {
            Task {
                await refreshLicense(showErrors: false)
            }
        }

        Task {
            await refreshPlayback(showErrors: false)
            await checkForUpdates()
        }

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshPlayback(showErrors: false)
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func saveConnection(host: String, port: String, password: String) {
        connection = ConnectionConfig(host: host, portText: port, password: password)
        ConnectionStore.save(connection)
    }

    func register(login: String) async {
        let normalized = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.range(of: #"^[a-zA-Z0-9._-]{3,32}$"#, options: .regularExpression) != nil else {
            toastMessage = "Login invalido."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let status = try await licenseClient.register(login: normalized, deviceId: LicenseStore.deviceId)
            license = status
            LicenseStore.save(status)
            showLogin = false
            toastMessage = "Login criado. Conta FREE."
        } catch {
            toastMessage = error.localizedDescription
            showLogin = true
        }
    }

    func refreshLicense(showErrors: Bool) async {
        guard let license, license.hasLogin else { return }

        do {
            let status = try await licenseClient.fetchStatus(login: license.login, deviceId: LicenseStore.deviceId)
            self.license = status
            LicenseStore.save(status)
        } catch {
            if showErrors {
                toastMessage = "Nao foi possivel verificar sua conta: \(error.localizedDescription)"
            }
        }
    }

    func sendNextCommand() {
        Task {
            await sendCommand("next")
        }
    }

    func sendPremiumCommand(_ command: String) {
        guard hasPremiumAccess else {
            showPremiumPrompt = true
            return
        }
        Task {
            await sendCommand(command)
        }
    }

    func requirePremiumOrToggle(_ action: () -> Void) {
        guard hasPremiumAccess else {
            showPremiumPrompt = true
            return
        }
        action()
    }

    func sendCommand(_ command: String) async {
        guard license?.hasLogin == true else {
            showLogin = true
            return
        }

        guard connection.isComplete else {
            showTutorial = true
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await radioBoss.sendCommand(connection: connection, command: command)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshPlayback(showErrors: false)
        } catch {
            isConnected = false
            toastMessage = "Falha ao enviar comando: \(error.localizedDescription)"
        }
    }

    func refreshPlayback(showErrors: Bool) async {
        guard connection.isComplete else {
            playbackInfo = .empty
            isConnected = false
            return
        }

        do {
            let response = try await radioBoss.sendAction(connection: connection, action: "playbackinfo")
            guard (200..<300).contains(response.statusCode) else {
                throw AppError.message("Playbackinfo retornou HTTP \(response.statusCode).")
            }
            playbackInfo = try PlaybackInfoParser.parse(response.body)
            isConnected = true
        } catch {
            isConnected = false
            if showErrors {
                toastMessage = "Falha ao buscar faixas: \(error.localizedDescription)"
            }
        }
    }

    func startPayment(email: String, couponCode: String) async {
        guard let license, license.hasLogin else {
            showLogin = true
            return
        }

        guard email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else {
            toastMessage = "Informe um e-mail valido."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let url = try await licenseClient.createPayment(login: license.login, deviceId: LicenseStore.deviceId, payerEmail: email, couponCode: couponCode)
            await UIApplication.shared.open(url)
            toastMessage = "Pagamento aberto. Depois de pagar, volte ao app."
        } catch {
            toastMessage = "Nao foi possivel iniciar o pagamento: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() async {
        guard !AppConfig.updateManifestURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        do {
            let update = try await updateClient.fetchUpdate()
            if update.versionCode > AppConfig.currentVersionCode {
                availableUpdate = update
                showUpdateAlert = true
            }
        } catch {
            // Update check is silent on startup, matching the Android behavior.
        }
    }

    func openUpdateDownload(_ update: UpdateInfo) {
        Task {
            await UIApplication.shared.open(update.downloadURL)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var currentExpanded = false
    @State private var nextExpanded = false

    var body: some View {
        ZStack {
            AppBackground()

            GeometryReader { proxy in
                let horizontalPadding = proxy.size.width <= 390 ? 14.0 : 18.0
                let contentSpacing = proxy.size.height <= 760 ? 14.0 : 18.0
                let topPadding = max(proxy.safeAreaInsets.top + 10, 20)
                let bottomPadding = max(proxy.safeAreaInsets.bottom + 18, 28)

                ScrollView {
                    VStack(spacing: contentSpacing) {
                        HeaderCard(compact: proxy.size.width <= 390)
                        ConfigButton(compact: proxy.size.width <= 390)
                        QuickCommands(compact: proxy.size.height <= 760)
                        TrackCard(
                            title: "Faixa atual",
                            systemImage: "music.note",
                            track: model.playbackInfo.currentTrack,
                            expanded: $currentExpanded
                        ) {
                            model.requirePremiumOrToggle {
                                currentExpanded.toggle()
                            }
                        }
                        TrackCard(
                            title: "Proxima faixa",
                            systemImage: "music.note.list",
                            track: model.playbackInfo.nextTrack,
                            expanded: $nextExpanded
                        ) {
                            model.requirePremiumOrToggle {
                                nextExpanded.toggle()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, topPadding)
                    .padding(.bottom, bottomPadding)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $model.showLogin) {
            LoginView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $model.showTutorial) {
            TutorialView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showPaymentEmail) {
            PaymentEmailView()
                .environmentObject(model)
        }
        .alert("Recurso premium", isPresented: $model.showPremiumPrompt) {
            Button("Adquirir") {
                model.showPaymentEmail = true
            }
            Button("Agora nao", role: .cancel) {}
        } message: {
            Text("Este recurso e premium. Deseja adquirir a assinatura mensal para desbloquear tudo?")
        }
        .alert("Atualizacao disponivel", isPresented: $model.showUpdateAlert, presenting: model.availableUpdate) { update in
            Button("Baixar") {
                model.openUpdateDownload(update)
            }
            Button("Depois", role: .cancel) {}
        } message: { update in
            Text("Nova versao do RB Remote encontrada: \(update.versionName).\n\n\(update.notes)")
        }
        .overlay(alignment: .bottom) {
            if !model.toastMessage.isEmpty {
                ToastView(text: model.toastMessage)
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            model.toastMessage = ""
                        }
                    }
            }
        }
        .overlay {
            if model.isLoading {
                ProgressView()
                    .tint(.white)
                    .padding(22)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }
}

struct HeaderCard: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 12 : 16) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: compact ? 58 : 66, height: compact ? 58 : 66)
                .padding(4)
                .background(Circle().fill(Color.white.opacity(0.04)))

            VStack(alignment: .leading, spacing: 5) {
                if !model.loginText.isEmpty {
                    Text(model.loginText)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(Color.blueWhite.opacity(0.75))
                }

                HStack(spacing: 8) {
                    Text("RB REMOTE")
                        .font((compact ? Font.headline : Font.title3).weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.white)
                        .layoutPriority(1)

                    Text(model.accountLabel)
                        .font(.caption.weight(.black))
                        .lineLimit(1)
                        .foregroundStyle(accountColor)
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isConnected ? Color.green : Color.red)
                        .frame(width: 9, height: 9)

                    Text(model.isConnected ? "Conectado" : "Desconectado")
                        .font(compact ? .footnote : .subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(model.isConnected ? .green : .red)

                    if let days = model.premiumDaysText {
                        Text(days)
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(Color.blueWhite.opacity(0.75))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 14 : 18)
        .background(RemoteCardBackground())
    }

    private var accountColor: Color {
        switch model.accountLabel {
        case "PREMIUM": return .green
        case "TESTER", "ADM": return Color.remoteBlue
        case "BLOQ": return .red
        default: return .orange
        }
    }
}

struct ConfigButton: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        Button {
            model.showTutorial = true
        } label: {
            HStack(spacing: compact ? 12 : 16) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: compact ? 26 : 30, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: compact ? 44 : 50, height: compact ? 44 : 50)
                    .background(Circle().fill(Color.white.opacity(0.08)))

                Text("CONFIGURAR")
                    .font(.headline.weight(.black))
                    .kerning(compact ? 1.3 : 2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)
                    .foregroundStyle(.white)
                    .layoutPriority(1)

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(compact ? 14 : 18)
            .background(
                LinearGradient(colors: [Color.remoteBlue, Color.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18)
            )
        }
        .buttonStyle(.plain)
    }
}

struct QuickCommands: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Color.remoteBlue)
                Text("COMANDOS RAPIDOS")
                    .font(.headline.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.white)
            }
            .padding(.top, compact ? 2 : 8)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: compact ? 10 : 12) {
                CommandButton(title: "PLAY", systemImage: "play.fill", locked: !model.hasPremiumAccess, compact: compact) {
                    model.sendPremiumCommand("play")
                }
                CommandButton(title: "PAUSE", systemImage: "pause.fill", locked: !model.hasPremiumAccess, compact: compact) {
                    model.sendPremiumCommand("pause")
                }
            }

            CommandButton(title: "STOP", systemImage: "stop.fill", locked: !model.hasPremiumAccess, wide: true, compact: compact) {
                model.sendPremiumCommand("stop")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: compact ? 10 : 12) {
                CommandButton(title: "FAIXA ANTERIOR", systemImage: "backward.fill", locked: !model.hasPremiumAccess, compact: compact) {
                    model.sendPremiumCommand("prev")
                }
                CommandButton(title: "PROXIMA FAIXA", systemImage: "forward.fill", locked: false, compact: compact) {
                    model.sendNextCommand()
                }
            }
        }
    }
}

struct CommandButton: View {
    let title: String
    let systemImage: String
    let locked: Bool
    var wide = false
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 10 : 14) {
                Image(systemName: locked ? "lock.fill" : systemImage)
                    .font(.system(size: wide ? 20 : (compact ? 25 : 30), weight: .black))
                    .foregroundStyle(Color.remoteBlue)
                Text(title)
                    .font((compact ? Font.caption : Font.subheadline).weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)
                    .foregroundStyle(.white)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: wide ? (compact ? 60 : 70) : (compact ? 76 : 92))
            .background(RemoteCardBackground())
            .opacity(locked ? 0.48 : 1)
        }
        .buttonStyle(.plain)
    }
}

struct TrackCard: View {
    let title: String
    let systemImage: String
    let track: TrackInfo
    @Binding var expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.black))
                        .foregroundStyle(Color.remoteBlue)
                        .frame(width: 46, height: 46)
                        .background(Circle().stroke(Color.remoteBlue, lineWidth: 1.2))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(.white)
                        Text("Toque para visualizar")
                            .font(.subheadline)
                            .lineLimit(1)
                            .foregroundStyle(Color.blueWhite.opacity(0.72))
                    }

                    Spacer(minLength: 0)
                    Text(expanded ? "Ocultar" : "Mostrar")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(Color.remoteBlue)
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Color.blueWhite.opacity(0.8))
                }

                if expanded {
                    Divider().background(Color.white.opacity(0.15))
                    TrackField(label: "Titulo", value: track.title)
                    TrackField(label: "Album", value: track.album)
                    TrackField(label: "Nome da Faixa", value: track.fileNameOnly)
                }
            }
            .padding(16)
            .background(RemoteCardBackground())
        }
        .buttonStyle(.plain)
    }
}

struct TrackField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
            Text(value.isEmpty ? "-" : value)
                .font(.subheadline)
                .foregroundStyle(Color.blueWhite.opacity(0.78))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var login = ""

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 22) {
                HeaderMini(status: "FREE")
                VStack(alignment: .leading, spacing: 14) {
                    Text("Criar login")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(.white)
                    Text("Crie um login para usar o RB Remote neste aparelho.")
                        .foregroundStyle(Color.blueWhite.opacity(0.78))
                    Text("LOGIN")
                        .font(.caption.weight(.black))
                        .foregroundStyle(Color.remoteBlue)
                    TextField("seu_login", text: $login)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding()
                        .background(InputBackground())
                    Button {
                        Task { await model.register(login: login) }
                    } label: {
                        Text("CRIAR LOGIN")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                            .background(LinearGradient(colors: [Color.remoteBlue, Color.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
                    }
                    Text("Sua conta inicia como FREE. Recursos premium podem ser desbloqueados depois.")
                        .font(.footnote)
                        .foregroundStyle(Color.blueWhite.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(22)
                .background(RemoteCardBackground())
            }
            .padding(18)
        }
    }
}

struct PaymentEmailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var couponCode = ""

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 22) {
                HeaderMini(status: "PREMIUM")
                VStack(alignment: .leading, spacing: 14) {
                    Text("E-mail do Mercado Pago")
                        .font(.title.weight(.black))
                        .foregroundStyle(.white)
                    Text("Informe o e-mail que será usado no pagamento")
                        .foregroundStyle(Color.blueWhite.opacity(0.78))
                    Text("E-MAIL")
                        .font(.caption.weight(.black))
                        .foregroundStyle(Color.remoteBlue)
                    TextField("email@exemplo.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding()
                        .background(InputBackground())
                    Text("CUPOM OPCIONAL")
                        .font(.caption.weight(.black))
                        .foregroundStyle(Color.remoteBlue)
                    TextField("PROMO10", text: $couponCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding()
                        .background(InputBackground())
                    Button {
                        dismiss()
                        Task { await model.startPayment(email: email, couponCode: couponCode) }
                    } label: {
                        Text("ADQUIRIR")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                            .background(LinearGradient(colors: [Color.remoteBlue, Color.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button("AGORA NAO") {
                        dismiss()
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.blueWhite.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                }
                .padding(22)
                .background(RemoteCardBackground())
            }
            .padding(18)
        }
    }
}

struct TutorialView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var step = 0
    @State private var host = ""
    @State private var port = "9000"
    @State private var password = ""

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 20) {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Text("CONFIGURAR")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                        Spacer()
                        Color.clear.frame(width: 28, height: 28)
                    }

                    StepperHeader(step: step)

                    VStack(alignment: .leading, spacing: 18) {
                        Text("Passo \(step + 1) de 3")
                            .font(.headline.weight(.black))
                            .foregroundStyle(Color.remoteBlue)

                        Text(stepText)
                            .font(.title2.weight(.black))
                            .foregroundStyle(.white)
                            .lineSpacing(4)

                        if step == 1 {
                            Text("Procure seu endereco IPv4 como na imagem e coloque ele na caixa abaixo.")
                                .font(.title3)
                                .foregroundStyle(Color.blueWhite.opacity(0.78))
                        }

                        Image(stepImage)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                            .background(InputBackground())

                        if step == 0 {
                            Text("COLOQUE AQUI A PORTA E SENHA DO RADIO BOSS")
                                .font(.subheadline.weight(.black))
                                .foregroundStyle(.white)
                            TextField("Porta", text: $port)
                                .keyboardType(.numberPad)
                                .padding()
                                .background(InputBackground())
                            SecureField("Senha opcional", text: $password)
                                .padding()
                                .background(InputBackground())
                        }

                        if step == 1 {
                            TextField("IP ou host", text: $host)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding()
                                .background(InputBackground())
                        }

                        Button {
                            model.saveConnection(host: host, port: port, password: password)
                            if step < 2 {
                                step += 1
                            } else {
                                dismiss()
                            }
                        } label: {
                            Text(step == 2 ? "FINALIZAR" : "PROXIMO PASSO")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .font(.headline.weight(.black))
                                .foregroundStyle(.white)
                                .background(LinearGradient(colors: [Color.remoteBlue, Color.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(22)
                    .background(RemoteCardBackground())
                }
                .padding(18)
            }
        }
        .onAppear {
            host = model.connection.host
            port = model.connection.portText.isEmpty ? "9000" : model.connection.portText
            password = model.connection.password
        }
    }

    private var stepText: String {
        switch step {
        case 0:
            return "1. Abra as configuracoes do RadioBOSS, clique em API, ative o acesso remoto, coloque a porta que desejar, e a senha de sua escolha, mas pode deixar em branco."
        case 1:
            return "2. Abra o cmd do seu Computador e digite IPCONFIG"
        default:
            return "3. Se der algum erro e nao estiver conectando, voce precisara liberar o RadioBoss no seu firewall, se nao souber como fazer procure o criador desse app pelo discord Jandinho."
        }
    }

    private var stepImage: String {
        switch step {
        case 0: return "TutorialApi"
        case 1: return "TutorialIpconfig"
        default: return "TutorialDiscord"
        }
    }
}

struct StepperHeader: View {
    let step: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<3) { index in
                Circle()
                    .strokeBorder(index <= step ? Color.remoteBlue : Color.white.opacity(0.18), lineWidth: 3)
                    .background(Circle().fill(index == step ? Color.remoteBlue : Color.clear))
                    .overlay {
                        Text(index < step ? "✓" : "\(index + 1)")
                            .font(.headline.weight(.black))
                            .foregroundStyle(index <= step ? Color.white : Color.blueWhite.opacity(0.7))
                    }
                    .frame(width: 42, height: 42)
                if index < 2 {
                    Rectangle()
                        .fill(index < step ? Color.remoteBlue : Color.white.opacity(0.18))
                        .frame(height: 3)
                }
            }
        }
        .padding(.horizontal, 50)
    }
}

struct HeaderMini: View {
    let status: String

    var body: some View {
        HStack(spacing: 18) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 66, height: 66)
            VStack(alignment: .leading, spacing: 6) {
                Text("RB REMOTE")
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white)
                Text(status)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(status == "PREMIUM" ? .green : .orange)
            }
            Spacer()
        }
        .padding(18)
        .background(RemoteCardBackground())
    }
}

struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(hex: 0x020912), Color(hex: 0x06162A), Color.black],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct RemoteCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color(hex: 0x07111F).opacity(0.88))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color(hex: 0x20344F), lineWidth: 1)
            )
    }
}

struct InputBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(hex: 0x0B1728))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(hex: 0x2A3B57), lineWidth: 1)
            )
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.78), in: Capsule())
            .padding(.horizontal, 18)
    }
}

struct ConnectionConfig: Codable {
    var host: String
    var portText: String
    var password: String

    var port: Int {
        Int(portText) ?? 0
    }

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65535).contains(port)
    }
}

enum ConnectionStore {
    static func load() -> ConnectionConfig {
        ConnectionConfig(
            host: UserDefaults.standard.string(forKey: "connection_host") ?? "",
            portText: UserDefaults.standard.string(forKey: "connection_port") ?? "9000",
            password: UserDefaults.standard.string(forKey: "connection_password") ?? ""
        )
    }

    static func save(_ config: ConnectionConfig) {
        UserDefaults.standard.set(config.host.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "connection_host")
        UserDefaults.standard.set(config.portText.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "connection_port")
        UserDefaults.standard.set(config.password, forKey: "connection_password")
    }
}

struct LicenseStatus: Codable {
    let login: String
    let deviceId: String
    let isPremium: Bool
    let reason: String
    let role: String
    let accountStatus: String
    let subscriptionStatus: String
    let premiumUntil: String

    var hasLogin: Bool {
        !login.isEmpty
    }

    var displayLabel: String {
        if accountStatus.lowercased() == "blocked" { return "BLOQ" }
        if role.lowercased() == "admin" { return "ADM" }
        if role.lowercased() == "tester" { return "TESTER" }
        return isPremium ? "PREMIUM" : "FREE"
    }
}

enum LicenseStore {
    static var deviceId: String {
        if let saved = UserDefaults.standard.string(forKey: "device_id"), !saved.isEmpty {
            return saved
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: "device_id")
        return generated
    }

    static func load() -> LicenseStatus? {
        guard let data = UserDefaults.standard.data(forKey: "license_status") else { return nil }
        return try? JSONDecoder().decode(LicenseStatus.self, from: data)
    }

    static func save(_ status: LicenseStatus) {
        if let data = try? JSONEncoder().encode(status) {
            UserDefaults.standard.set(data, forKey: "license_status")
        }
    }
}

struct CommandResponse {
    let url: URL
    let statusCode: Int
    let body: String
}

final class RadioBossClient {
    func sendCommand(connection: ConnectionConfig, command: String) async throws -> CommandResponse {
        try await sendRequest(connection: connection, parameter: "cmd", value: command)
    }

    func sendAction(connection: ConnectionConfig, action: String) async throws -> CommandResponse {
        try await sendRequest(connection: connection, parameter: "action", value: action)
    }

    private func sendRequest(connection: ConnectionConfig, parameter: String, value: String) async throws -> CommandResponse {
        var components = URLComponents()
        components.scheme = "http"
        components.host = normalizeHost(connection.host)
        components.port = connection.port
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "pass", value: connection.password),
            URLQueryItem(name: parameter, value: value)
        ]

        guard let url = components.url else {
            throw AppError.message("URL invalida.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        return CommandResponse(url: url, statusCode: statusCode, body: body)
    }

    private func normalizeHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "http://", with: "")
        value = value.replacingOccurrences(of: "https://", with: "")
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if let colon = value.lastIndex(of: ":"), value[colon...].dropFirst().allSatisfy(\.isNumber) {
            value = String(value[..<colon])
        }
        return value
    }
}

final class LicenseClient {
    func register(login: String, deviceId: String) async throws -> LicenseStatus {
        let json = try await post(path: "/api/users/register", body: [
            "login": login,
            "device_id": deviceId
        ])
        return try parseLicense(json)
    }

    func fetchStatus(login: String, deviceId: String) async throws -> LicenseStatus {
        var components = URLComponents(string: AppConfig.licenseServerBaseURL + "/api/license/status")
        components?.queryItems = [
            URLQueryItem(name: "login", value: login),
            URLQueryItem(name: "device_id", value: deviceId)
        ]
        guard let url = components?.url else { throw AppError.message("URL invalida.") }
        let json = try await request(url: url, method: "GET", body: nil)
        return try parseLicense(json)
    }

    func createPayment(login: String, deviceId: String, payerEmail: String, couponCode: String) async throws -> URL {
        let json = try await post(path: "/api/subscriptions/create", body: [
            "login": login,
            "device_id": deviceId,
            "payer_email": payerEmail,
            "coupon_code": couponCode.trimmingCharacters(in: .whitespacesAndNewlines)
        ])
        guard let initPoint = json["init_point"] as? String, let url = URL(string: initPoint) else {
            throw AppError.message("Mercado Pago nao retornou o link de pagamento.")
        }
        return url
    }

    private func post(path: String, body: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: AppConfig.licenseServerBaseURL + path) else {
            throw AppError.message("URL invalida.")
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(url: url, method: "POST", body: data)
    }

    private func request(url: URL, method: String, body: Data?) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = try JSONSerialization.jsonObject(with: data.isEmpty ? Data("{}".utf8) : data)
        let json = object as? [String: Any] ?? [:]
        let ok = json["ok"] as? Bool ?? false
        if !(200..<300).contains(statusCode) || !ok {
            let message = json["message"] as? String ?? "Falha ao acessar o servidor premium."
            throw AppError.message(message)
        }
        return json
    }

    private func parseLicense(_ json: [String: Any]) throws -> LicenseStatus {
        let user = json["user"] as? [String: Any] ?? [:]
        let license = json["license"] as? [String: Any] ?? [:]
        return LicenseStatus(
            login: user["login"] as? String ?? "",
            deviceId: user["device_id"] as? String ?? "",
            isPremium: license["premium"] as? Bool ?? false,
            reason: license["reason"] as? String ?? "free",
            role: license["role"] as? String ?? "user",
            accountStatus: license["account_status"] as? String ?? "active",
            subscriptionStatus: license["subscription_status"] as? String ?? "none",
            premiumUntil: license["premium_until"] as? String ?? ""
        )
    }
}

struct TrackInfo {
    let filename: String
    let title: String
    let album: String

    var fileNameOnly: String {
        filename.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? filename
    }
}

struct PlaybackInfo {
    let currentTrack: TrackInfo
    let previousTrack: TrackInfo
    let nextTrack: TrackInfo

    static let empty = PlaybackInfo(
        currentTrack: TrackInfo(filename: "", title: "", album: ""),
        previousTrack: TrackInfo(filename: "", title: "", album: ""),
        nextTrack: TrackInfo(filename: "", title: "", album: "")
    )
}

enum PlaybackInfoParser {
    static func parse(_ raw: String) throws -> PlaybackInfo {
        let xml = try extractXmlDocument(raw)
        return PlaybackInfo(
            currentTrack: readTrack(xml, section: "CurrentTrack"),
            previousTrack: readTrack(xml, section: "PrevTrack"),
            nextTrack: readTrack(xml, section: "NextTrack")
        )
    }

    private static func readTrack(_ xml: String, section: String) -> TrackInfo {
        let sectionText = firstMatch("<\(section)\\b[^>]*>(.*?)</\(section)>", in: xml) ?? ""
        let attributes = firstMatch("<TRACK\\b([^>]*)/?\\s*>", in: sectionText) ?? ""
        let filename = readAttribute("FILENAME", from: attributes)
        let title = firstNonEmpty(
            readAttribute("TITLE", from: attributes),
            readAttribute("CASTTITLE", from: attributes),
            readAttribute("ITEMTITLE", from: attributes)
        )
        let album = readAttribute("ALBUM", from: attributes)
        return TrackInfo(filename: filename, title: title, album: album)
    }

    private static func extractXmlDocument(_ raw: String) throws -> String {
        let value = raw.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AppError.message("Resposta vazia no playbackinfo.") }

        let ns = value as NSString
        let lower = value.lowercased() as NSString
        let start = lower.range(of: "<info").location
        let endRange = lower.range(of: "</info>", options: .backwards)

        if start != NSNotFound, endRange.location != NSNotFound, endRange.location > start {
            let length = endRange.location - start + endRange.length
            return ns.substring(with: NSRange(location: start, length: length))
        }

        throw AppError.message("A resposta nao contem o XML Info do playbackinfo.")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        guard let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func readAttribute(_ name: String, from attributes: String) -> String {
        let value = firstMatch("\\b\(name)\\s*=\\s*\"([^\"]*)\"", in: attributes) ?? ""
        return decodeXmlEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    private static func decodeXmlEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

struct UpdateInfo {
    let versionCode: Int
    let versionName: String
    let downloadURL: URL
    let notes: String
}

final class UpdateClient {
    func fetchUpdate() async throws -> UpdateInfo {
        guard let url = URL(string: AppConfig.updateManifestURLString) else {
            throw AppError.message("Link de atualizacao nao configurado.")
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = object as? [String: Any] ?? [:]
        let versionCode = json["versionCode"] as? Int ?? 0
        let versionName = json["versionName"] as? String ?? ""
        let notes = json["notes"] as? String ?? "Melhorias e correcoes."
        let rawURL =
            json["iosUrl"] as? String ??
            json["ipaUrl"] as? String ??
            json["downloadUrl"] as? String ??
            ""

        guard let downloadURL = URL(string: rawURL), !rawURL.isEmpty else {
            throw AppError.message("Manifest iOS sem link de download.")
        }

        return UpdateInfo(versionCode: versionCode, versionName: versionName, downloadURL: downloadURL, notes: notes)
    }
}

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

extension Color {
    static let remoteBlue = Color(hex: 0x1678FF)
    static let deepBlue = Color(hex: 0x053B9E)
    static let blueWhite = Color(hex: 0xDDE8FF)

    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
