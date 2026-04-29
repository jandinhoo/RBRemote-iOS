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
    @Published var showPlaylistSelector = false
    @Published var showEqSelector = false
    @Published var toastMessage = ""
    @Published var availableUpdate: UpdateInfo?
    @Published var showUpdateAlert = false
    @Published var playlistTabsRaw = UserDefaults.standard.string(forKey: "playlist_tabs_raw") ?? ""
    @Published var currentPlaylistTab = UserDefaults.standard.string(forKey: "current_playlist_tab") ?? ""
    @Published var eqPresetsRaw = UserDefaults.standard.string(forKey: "eq_presets_raw") ?? ""
    @Published var currentEqPreset = UserDefaults.standard.string(forKey: "current_eq_preset") ?? ""
    @Published var playlistTracks: [PlaylistTrackInfo] = []

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

    var playlistTabs: [String] {
        parseStoredList(playlistTabsRaw)
    }

    var eqPresets: [String] {
        parseStoredList(eqPresetsRaw)
    }

    var playlistButtonText: String {
        currentPlaylistTab.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Nenhuma aba" : currentPlaylistTab
    }

    var playlistSongsSubtitle: String {
        if playlistTracks.isEmpty {
            return "Selecione uma playlist para carregar as musicas."
        }
        let countText = "Musicas carregadas: \(playlistTracks.count)"
        return currentPlaylistTab.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? countText : "\(currentPlaylistTab) - \(countText)"
    }

    var eqButtonText: String {
        currentEqPreset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Nenhum preset" : currentEqPreset
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
            await refreshPlaylistTracks(showErrors: false)
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
        _ = await sendRemoteCommand(command)
    }

    @discardableResult
    private func sendRemoteCommand(_ command: String) async -> Bool {
        guard license?.hasLogin == true else {
            showLogin = true
            return false
        }

        guard connection.isComplete else {
            showTutorial = true
            return false
        }

        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await radioBoss.sendCommand(connection: connection, command: command)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshPlayback(showErrors: false)
            return true
        } catch {
            isConnected = false
            toastMessage = "Falha ao enviar comando: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func savePlaylistTabs(_ rawTabs: String) -> Bool {
        let tabs = parseStoredList(rawTabs)
        guard !tabs.isEmpty else {
            toastMessage = "Cadastre pelo menos uma aba de playlist."
            return false
        }

        playlistTabsRaw = rawTabs.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(playlistTabsRaw, forKey: "playlist_tabs_raw")
        if !tabs.contains(currentPlaylistTab) {
            currentPlaylistTab = ""
            UserDefaults.standard.set("", forKey: "current_playlist_tab")
        }
        toastMessage = "Abas salvas."
        return true
    }

    func selectPlaylistTab(_ tab: String, closeAfterSuccess: (() -> Void)? = nil) {
        let cleanTab = tab.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTab.isEmpty else {
            toastMessage = "Cadastre as abas de playlist primeiro."
            return
        }

        Task {
            if await sendRemoteCommand("playlist \(cleanTab)") {
                currentPlaylistTab = cleanTab
                UserDefaults.standard.set(cleanTab, forKey: "current_playlist_tab")
                await refreshPlaylistTracks(showErrors: false)
                showPlaylistSelector = false
                closeAfterSuccess?()
                toastMessage = "Playlist alterada para \(cleanTab)"
            }
        }
    }

    func selectNextPlaylistTab(closeAfterSuccess: (() -> Void)? = nil) {
        let tabs = playlistTabs
        guard !tabs.isEmpty else {
            toastMessage = "Cadastre as abas de playlist primeiro."
            return
        }

        let currentIndex = tabs.firstIndex(of: currentPlaylistTab)
        let nextIndex = currentIndex.map { tabs.index(after: $0) == tabs.endIndex ? tabs.startIndex : tabs.index(after: $0) } ?? tabs.startIndex
        selectPlaylistTab(tabs[nextIndex], closeAfterSuccess: closeAfterSuccess)
    }

    func refreshPlaylistTracks(showErrors: Bool) async {
        guard connection.isComplete else {
            playlistTracks = []
            return
        }

        do {
            let response = try await radioBoss.sendAction(
                connection: connection,
                action: "getplaylist2",
                parameters: ["cnt": "0"]
            )
            guard (200..<300).contains(response.statusCode) else {
                throw AppError.message("Getplaylist2 retornou HTTP \(response.statusCode).")
            }
            playlistTracks = try PlaylistContentParser.parse(response.body)
        } catch {
            playlistTracks = []
            if showErrors {
                isConnected = false
                toastMessage = "Falha ao buscar musicas: \(error.localizedDescription)"
            }
        }
    }

    func selectPlaylistTrack(_ track: PlaylistTrackInfo, closeAfterSuccess: (() -> Void)? = nil) {
        Task {
            if await sendRemoteCommand("play \(track.position)") {
                closeAfterSuccess?()
                toastMessage = "Tocando: \(track.displayTitle)"
            }
        }
    }

    @discardableResult
    func saveEqPresets(_ rawPresets: String) -> Bool {
        let presets = parseStoredList(rawPresets)
        guard !presets.isEmpty else {
            toastMessage = "Cadastre pelo menos um preset do equalizador."
            return false
        }

        eqPresetsRaw = rawPresets.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(eqPresetsRaw, forKey: "eq_presets_raw")
        if !presets.contains(currentEqPreset) {
            currentEqPreset = ""
            UserDefaults.standard.set("", forKey: "current_eq_preset")
        }
        toastMessage = "Presets salvos."
        return true
    }

    func selectEqPreset(_ preset: String) {
        let cleanPreset = preset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPreset.isEmpty else {
            toastMessage = "Cadastre os presets do EQ primeiro."
            return
        }

        Task {
            if await sendRemoteCommand("eqpreset \(cleanPreset)") {
                currentEqPreset = cleanPreset
                UserDefaults.standard.set(cleanPreset, forKey: "current_eq_preset")
                showEqSelector = false
                toastMessage = "EQ alterado para \(cleanPreset)"
            }
        }
    }

    func selectNextEqPreset() {
        let presets = eqPresets
        guard !presets.isEmpty else {
            toastMessage = "Cadastre os presets do EQ primeiro."
            return
        }

        let currentIndex = presets.firstIndex(of: currentEqPreset)
        let nextIndex = currentIndex.map { presets.index(after: $0) == presets.endIndex ? presets.startIndex : presets.index(after: $0) } ?? presets.startIndex
        selectEqPreset(presets[nextIndex])
    }

    private func parseStoredList(_ rawValue: String) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for part in rawValue.components(separatedBy: CharacterSet(charactersIn: ",\n\r")) {
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !seen.contains(value) {
                values.append(value)
                seen.insert(value)
            }
        }
        return values
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
    @State private var openDrawer: SideDrawer?

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
                        QuickCommands(
                            compact: proxy.size.height <= 760,
                            openPlaylists: { openDrawer = .playlists }
                        )
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .simultaneousGesture(sideDrawerGesture)
        .fullScreenCover(isPresented: $model.showLogin) {
            LoginView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $model.showTutorial) {
            TutorialView()
                .environmentObject(model)
        }
        .fullScreenCover(isPresented: $model.showPaymentEmail) {
            PaymentEmailView()
                .environmentObject(model)
        }
        .fullScreenCover(isPresented: $model.showPlaylistSelector) {
            PlaylistSelectorView()
                .environmentObject(model)
        }
        .fullScreenCover(isPresented: $model.showEqSelector) {
            EqSelectorView()
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
        .overlay {
            if let openDrawer {
                SideDrawerOverlay(drawer: openDrawer) {
                    self.openDrawer = nil
                }
                .environmentObject(model)
            }
        }
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }

    private var sideDrawerGesture: some Gesture {
        DragGesture(minimumDistance: 45)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard abs(horizontal) > vertical * 1.3 else { return }

                if horizontal > 80 {
                    model.requirePremiumOrToggle {
                        openDrawer = .songs
                    }
                } else if horizontal < -80 {
                    model.requirePremiumOrToggle {
                        openDrawer = .playlists
                    }
                }
            }
    }
}

private enum SideDrawer: Equatable {
    case songs
    case playlists
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
    let openPlaylists: () -> Void

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

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: compact ? 10 : 12) {
                CommandButton(title: "EQ", systemImage: "slider.horizontal.3", subtitle: model.eqButtonText, locked: !model.hasPremiumAccess, compact: compact) {
                    model.requirePremiumOrToggle {
                        model.showEqSelector = true
                    }
                }
                CommandButton(title: "PLAYLIST", systemImage: "music.note.list", subtitle: model.playlistButtonText, locked: !model.hasPremiumAccess, compact: compact) {
                    model.requirePremiumOrToggle {
                        openPlaylists()
                    }
                }
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
    var subtitle: String? = nil
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
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font((compact ? Font.caption : Font.subheadline).weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .allowsTightening(true)
                        .foregroundStyle(.white)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .foregroundStyle(Color.blueWhite.opacity(0.7))
                    }
                }
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

struct SideDrawerOverlay: View {
    @EnvironmentObject private var model: AppModel
    let drawer: SideDrawer
    let close: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.46)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)

                HStack(spacing: 0) {
                    if drawer == .songs {
                        PlaylistSongsDrawer(close: close)
                            .environmentObject(model)
                            .frame(width: min(proxy.size.width * 0.88, 350))
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                        PlaylistSideDrawer(close: close)
                            .environmentObject(model)
                            .frame(width: min(proxy.size.width * 0.88, 350))
                    }
                }
            }
            .transition(.move(edge: drawer == .songs ? .leading : .trailing))
            .animation(.easeOut(duration: 0.22), value: drawer)
        }
    }
}

struct PlaylistSongsDrawer: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MUSICAS DA PLAYLIST")
                .font(.title3.weight(.black))
                .kerning(1.1)
                .foregroundStyle(.white)

            Text(model.playlistSongsSubtitle)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Color.blueWhite.opacity(0.75))

            ScrollView {
                VStack(spacing: 10) {
                    if model.playlistTracks.isEmpty {
                        DrawerInfoCard(text: "Selecione uma playlist para carregar as musicas.")
                    } else {
                        ForEach(model.playlistTracks) { track in
                            SelectorItemButton(
                                title: "\(track.position). \(track.displayTitle)",
                                selected: false
                            ) {
                                model.requirePremiumOrToggle {
                                    model.selectPlaylistTrack(track, closeAfterSuccess: close)
                                }
                            }
                        }
                    }
                }
            }

            SelectorActionButton(title: "ATUALIZAR MUSICAS", emphasized: true) {
                Task {
                    await model.refreshPlaylistTracks(showErrors: true)
                }
            }

            SelectorActionButton(title: "VOLTAR", emphasized: false, action: close)
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity)
        .background(AppBackground())
    }
}

struct PlaylistSideDrawer: View {
    @EnvironmentObject private var model: AppModel
    @State private var isConfiguring = false
    @State private var rawTabs = ""
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PLAYLISTS")
                .font(.title3.weight(.black))
                .kerning(1.1)
                .foregroundStyle(.white)

            Text(model.currentPlaylistTab.isEmpty ? "Nenhuma aba selecionada" : "Tocando: \(model.currentPlaylistTab)")
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Color.blueWhite.opacity(0.75))

            if isConfiguring {
                Text("Digite uma aba por linha ou separe por virgula. O nome precisa estar igual ao RadioBOSS.")
                    .font(.subheadline)
                    .foregroundStyle(Color.blueWhite.opacity(0.75))

                TextEditor(text: $rawTabs)
                    .foregroundColor(.white)
                    .accentColor(Color.remoteBlue)
                    .frame(minHeight: 140)
                    .padding(10)
                    .background(InputBackground())

                SelectorActionButton(title: "SALVAR ABAS", emphasized: true) {
                    if model.savePlaylistTabs(rawTabs) {
                        isConfiguring = false
                    }
                }

                SelectorActionButton(title: "CANCELAR", emphasized: false) {
                    rawTabs = model.playlistTabsRaw
                    isConfiguring = false
                }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        if model.playlistTabs.isEmpty {
                            SelectorItemButton(title: "Cadastre as abas de playlist primeiro.", selected: false) {
                                rawTabs = model.playlistTabsRaw
                                isConfiguring = true
                            }
                        } else {
                            ForEach(model.playlistTabs, id: \.self) { tab in
                                SelectorItemButton(title: tab, selected: tab == model.currentPlaylistTab) {
                                    model.requirePremiumOrToggle {
                                        model.selectPlaylistTab(tab, closeAfterSuccess: close)
                                    }
                                }
                            }
                        }
                    }
                }

                SelectorActionButton(title: "PROXIMA PLAYLIST", emphasized: true) {
                    model.selectNextPlaylistTab(closeAfterSuccess: close)
                }

                SelectorActionButton(title: "CONFIGURAR ABAS", emphasized: false) {
                    rawTabs = model.playlistTabsRaw
                    isConfiguring = true
                }

                SelectorActionButton(title: "VOLTAR", emphasized: false, action: close)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity)
        .background(AppBackground())
        .onAppear {
            rawTabs = model.playlistTabsRaw
        }
    }
}

struct DrawerInfoCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.blueWhite.opacity(0.75))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RemoteCardBackground())
    }
}

struct PlaylistSelectorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isConfiguring = false
    @State private var rawTabs = ""

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 20) {
                    SelectorHeader(
                        systemImage: "music.note.list",
                        title: "PLAYLIST",
                        subtitle: model.currentPlaylistTab.isEmpty ? "Nenhuma aba selecionada" : "Tocando: \(model.currentPlaylistTab)"
                    )

                    VStack(alignment: .leading, spacing: 16) {
                        if isConfiguring {
                            Text("Digite uma aba por linha ou separe por virgula. O nome precisa estar igual ao RadioBOSS.")
                                .font(.subheadline)
                                .foregroundStyle(Color.blueWhite.opacity(0.75))

                            TextEditor(text: $rawTabs)
                                .foregroundColor(.white)
                                .accentColor(Color.remoteBlue)
                                .frame(minHeight: 140)
                                .padding(10)
                                .background(InputBackground())

                            SelectorActionButton(title: "SALVAR ABAS", emphasized: true) {
                                if model.savePlaylistTabs(rawTabs) {
                                    isConfiguring = false
                                }
                            }

                            SelectorActionButton(title: "CANCELAR", emphasized: false) {
                                rawTabs = model.playlistTabsRaw
                                isConfiguring = false
                            }
                        } else {
                            Text("Escolha uma aba cadastrada para mandar o RadioBOSS mudar de playlist.")
                                .font(.subheadline)
                                .foregroundStyle(Color.blueWhite.opacity(0.75))

                            if model.playlistTabs.isEmpty {
                                SelectorItemButton(title: "Cadastre as abas de playlist primeiro.", selected: false) {
                                    rawTabs = model.playlistTabsRaw
                                    isConfiguring = true
                                }
                            } else {
                                ForEach(model.playlistTabs, id: \.self) { tab in
                                    SelectorItemButton(
                                        title: tab,
                                        selected: tab == model.currentPlaylistTab
                                    ) {
                                        model.selectPlaylistTab(tab)
                                    }
                                }
                            }

                            SelectorActionButton(title: "PROXIMA PLAYLIST", emphasized: true) {
                                model.selectNextPlaylistTab()
                            }

                            SelectorActionButton(title: "CONFIGURAR ABAS", emphasized: false) {
                                rawTabs = model.playlistTabsRaw
                                isConfiguring = true
                            }

                            SelectorActionButton(title: "VOLTAR", emphasized: false) {
                                model.showPlaylistSelector = false
                            }
                        }
                    }
                    .padding(22)
                    .background(RemoteCardBackground())
                }
                .padding(.horizontal, 18)
                .padding(.top, 34)
                .padding(.bottom, 34)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            rawTabs = model.playlistTabsRaw
        }
    }
}

struct EqSelectorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isConfiguring = false
    @State private var rawPresets = ""

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 20) {
                    SelectorHeader(
                        systemImage: "slider.horizontal.3",
                        title: "EQUALIZADOR",
                        subtitle: model.currentEqPreset.isEmpty ? "Nenhum preset selecionado" : "Preset atual: \(model.currentEqPreset)"
                    )

                    VStack(alignment: .leading, spacing: 16) {
                        if isConfiguring {
                            Text("Digite um preset por linha ou separe por virgula. O nome precisa estar igual ao preset criado no RadioBOSS.")
                                .font(.subheadline)
                                .foregroundStyle(Color.blueWhite.opacity(0.75))

                            TextEditor(text: $rawPresets)
                                .foregroundColor(.white)
                                .accentColor(Color.remoteBlue)
                                .frame(minHeight: 140)
                                .padding(10)
                                .background(InputBackground())

                            SelectorActionButton(title: "SALVAR PRESETS", emphasized: true) {
                                if model.saveEqPresets(rawPresets) {
                                    isConfiguring = false
                                }
                            }

                            SelectorActionButton(title: "CANCELAR", emphasized: false) {
                                rawPresets = model.eqPresetsRaw
                                isConfiguring = false
                            }
                        } else {
                            Text("Escolha um preset cadastrado para mandar o RadioBOSS trocar o equalizador.")
                                .font(.subheadline)
                                .foregroundStyle(Color.blueWhite.opacity(0.75))

                            if model.eqPresets.isEmpty {
                                SelectorItemButton(title: "Cadastre os presets do EQ primeiro.", selected: false) {
                                    rawPresets = model.eqPresetsRaw
                                    isConfiguring = true
                                }
                            } else {
                                ForEach(model.eqPresets, id: \.self) { preset in
                                    SelectorItemButton(
                                        title: preset,
                                        selected: preset == model.currentEqPreset
                                    ) {
                                        model.selectEqPreset(preset)
                                    }
                                }
                            }

                            SelectorActionButton(title: "PROXIMO PRESET", emphasized: true) {
                                model.selectNextEqPreset()
                            }

                            SelectorActionButton(title: "CONFIGURAR PRESETS", emphasized: false) {
                                rawPresets = model.eqPresetsRaw
                                isConfiguring = true
                            }

                            SelectorActionButton(title: "VOLTAR", emphasized: false) {
                                model.showEqSelector = false
                            }
                        }
                    }
                    .padding(22)
                    .background(RemoteCardBackground())
                }
                .padding(.horizontal, 18)
                .padding(.top, 34)
                .padding(.bottom, 34)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            rawPresets = model.eqPresetsRaw
        }
    }
}

struct SelectorHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(Color.remoteBlue)
                .frame(width: 64, height: 64)
                .background(Circle().stroke(Color.remoteBlue, lineWidth: 1.4))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(Color.blueWhite.opacity(0.75))
            }

            Spacer()
        }
        .padding(18)
        .background(RemoteCardBackground())
    }
}

struct SelectorItemButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.black))
                    .foregroundStyle(Color.remoteBlue)

                Text(selected ? "ATUAL: \(title)" : title)
                    .font(.subheadline.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                selected
                    ? LinearGradient(colors: [Color.remoteBlue, Color.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Color(hex: 0x07111F), Color(hex: 0x07111F)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(selected ? Color.remoteBlue : Color(hex: 0x20344F), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct SelectorActionButton: View {
    let title: String
    let emphasized: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.black))
                .kerning(1.2)
                .foregroundStyle(emphasized ? .white : Color.blueWhite.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: emphasized ? 56 : 50)
                .background(
                    emphasized
                        ? LinearGradient(colors: [Color.remoteBlue, Color.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color(hex: 0x07111F).opacity(0.7), Color(hex: 0x07111F).opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16)
                )
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

    private var collapsedSubtitle: String {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "-" : title
    }

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
                        Text(collapsedSubtitle)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
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
                    Text("Informe o e-mail que ser\u{00E1} usado no pagamento")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
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
                        Text(index < step ? "\u{2713}" : "\(index + 1)")
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

    func sendAction(connection: ConnectionConfig, action: String, parameters: [String: String]) async throws -> CommandResponse {
        let queryItems = parameters.map { item in
            URLQueryItem(name: item.key, value: item.value)
        }
        return try await sendRequest(connection: connection, parameter: "action", value: action, extraQueryItems: queryItems)
    }

    private func sendRequest(
        connection: ConnectionConfig,
        parameter: String,
        value: String,
        extraQueryItems: [URLQueryItem] = []
    ) async throws -> CommandResponse {
        var components = URLComponents()
        components.scheme = "http"
        components.host = normalizeHost(connection.host)
        components.port = connection.port
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "pass", value: connection.password),
            URLQueryItem(name: parameter, value: value)
        ] + extraQueryItems

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
    private let platform = "ios"

    func register(login: String, deviceId: String) async throws -> LicenseStatus {
        let json = try await post(path: "/api/users/register", body: [
            "login": login,
            "device_id": deviceId,
            "platform": platform
        ])
        return try parseLicense(json)
    }

    func fetchStatus(login: String, deviceId: String) async throws -> LicenseStatus {
        var components = URLComponents(string: AppConfig.licenseServerBaseURL + "/api/license/status")
        components?.queryItems = [
            URLQueryItem(name: "login", value: login),
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "platform", value: platform)
        ]
        guard let url = components?.url else { throw AppError.message("URL invalida.") }
        let json = try await request(url: url, method: "GET", body: nil)
        return try parseLicense(json)
    }

    func createPayment(login: String, deviceId: String, payerEmail: String, couponCode: String) async throws -> URL {
        let json = try await post(path: "/api/subscriptions/create", body: [
            "login": login,
            "device_id": deviceId,
            "platform": platform,
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

struct PlaylistTrackInfo: Identifiable {
    let position: Int
    let filename: String
    let title: String
    let album: String

    var id: String { "\(position)|\(filename)|\(title)" }

    var fileNameOnly: String {
        filename.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? filename
    }

    var displayTitle: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty {
            return cleanTitle
        }

        let cleanFileName = fileNameOnly.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanFileName.isEmpty ? "-" : cleanFileName
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

enum PlaylistContentParser {
    static func parse(_ raw: String) throws -> [PlaylistTrackInfo] {
        let xml = try extractXmlDocument(raw)
        guard let regex = try? NSRegularExpression(pattern: "<TRACK\\b([^>]*)/?\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, range: range)
        var tracks: [PlaylistTrackInfo] = []
        var fallbackPosition = 1

        for match in matches {
            guard match.numberOfRanges > 1, let attributesRange = Range(match.range(at: 1), in: xml) else {
                continue
            }

            let attributes = String(xml[attributesRange])
            let position = readPosition(from: attributes, fallbackPosition: fallbackPosition)
            let filename = readAttribute("FILENAME", from: attributes)
            let title = firstNonEmpty(
                readAttribute("TITLE", from: attributes),
                readAttribute("CASTTITLE", from: attributes),
                readAttribute("ITEMTITLE", from: attributes)
            )
            let album = readAttribute("ALBUM", from: attributes)

            tracks.append(PlaylistTrackInfo(position: position, filename: filename, title: title, album: album))
            fallbackPosition += 1
        }

        return tracks
    }

    private static func readPosition(from attributes: String, fallbackPosition: Int) -> Int {
        let playlistIndex = readAttribute("PLAYLISTINDEX", from: attributes)
        let index = firstNonEmpty(readAttribute("INDEX", from: attributes), playlistIndex)

        guard let parsed = Int(index) else {
            return fallbackPosition
        }

        if !playlistIndex.isEmpty, playlistIndex == index {
            return parsed + 1
        }

        return max(1, parsed)
    }

    private static func extractXmlDocument(_ raw: String) throws -> String {
        let value = raw.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AppError.message("Resposta vazia no getplaylist2.") }

        let ns = value as NSString
        let lower = value.lowercased() as NSString
        let start = lower.range(of: "<playlist").location
        let endRange = lower.range(of: "</playlist>", options: .backwards)

        if start != NSNotFound, endRange.location != NSNotFound, endRange.location > start {
            let length = endRange.location - start + endRange.length
            return ns.substring(with: NSRange(location: start, length: length))
        }

        throw AppError.message("A resposta nao contem o XML Playlist do getplaylist2.")
    }

    private static func readAttribute(_ name: String, from attributes: String) -> String {
        let value = firstMatch("\\b\(name)\\s*=\\s*\"([^\"]*)\"", in: attributes) ?? ""
        return decodeXmlEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func decodeXmlEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
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
