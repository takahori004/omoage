import SwiftUI
import AudioToolbox
import Combine
import AVFoundation
import UserNotifications
import UniformTypeIdentifiers

// ---------------------------------------------------------
// 2026/01/05: 複数プログラム並行管理版
// 2026/03/10: HPSプログラム追加
// 2026/03/11: 名前をomoageに変更
// 2026/03/11: ブランチをクロードのやつに切り替えたてすと
// 2026/03/11: pullてすと
// 2026/03/26: データのエクスポート・インポート機能追加
// ---------------------------------------------------------

// MARK: - Data Models

/// プログラム（最上位の管理単位：1つの種目の3週間サイクル）
struct Program: Identifiable, Codable, Equatable {
    let id: UUID
    var programType: String // プログラムタイプ（例：「SmolovjJr」「5/3/1」「GZCL」）
    var name: String // 種目名（例：「ベンチプレス」「スクワット」）
    var oneRM: Double // 1RM重量
    var weeklyAdd: Double // 週ごとの重量増加幅
    var createdAt: Date

    init(id: UUID = UUID(), programType: String = "SmolovjJr", name: String, oneRM: Double, weeklyAdd: Double = 2.5) {
        self.id = id
        self.programType = programType
        self.name = name
        self.oneRM = oneRM
        self.weeklyAdd = weeklyAdd
        self.createdAt = Date()
    }
}

/// セッション進捗情報（1日分のトレーニング履歴）
struct SessionProgress: Codable {
    var completedSets: Int
    var isCompleted: Bool
    var startTime: Date?
    var endTime: Date?
    var totalRest: TimeInterval
    var isResting: Bool
    var restStartTime: Date?
    var restDuration: Int
    // セットごとのタイムライン記録
    var setCompletedTimes: [Date]?
    var assignedRestDurations: [Int]?

    init(completedSets: Int = 0, isCompleted: Bool = false, startTime: Date? = nil, endTime: Date? = nil, totalRest: TimeInterval = 0, isResting: Bool = false, restStartTime: Date? = nil, restDuration: Int = 0, setCompletedTimes: [Date]? = nil, assignedRestDurations: [Int]? = nil) {
        self.completedSets = completedSets
        self.isCompleted = isCompleted
        self.startTime = startTime
        self.endTime = endTime
        self.totalRest = totalRest
        self.isResting = isResting
        self.restStartTime = restStartTime
        self.restDuration = restDuration
        self.setCompletedTimes = setCompletedTimes
        self.assignedRestDurations = assignedRestDurations
    }
}

// MARK: - Export/Import Data Model

struct ExportData: Codable {
    let version: Int
    let exportedAt: Date
    let programs: [Program]
    let sessionProgressMap: [String: SessionProgress] // key: "programUUID_sessionID"
}

// MARK: - Program Manager

class ProgramManager: ObservableObject {
    @Published var programs: [Program] = []

    private let programsKey = "programs_v1"
    private let progressKeyPrefix = "session_progress_"

    init() {
        loadPrograms()
    }

    // MARK: - Program Management

    func addProgram(_ program: Program) {
        programs.append(program)
        savePrograms()
    }

    func updateProgram(_ program: Program) {
        if let index = programs.firstIndex(where: { $0.id == program.id }) {
            programs[index] = program
            savePrograms()
        }
    }

    func deleteProgram(_ program: Program) {
        programs.removeAll { $0.id == program.id }
        // プログラムに紐づくセッション進捗も削除
        deleteAllSessionProgress(for: program.id)
        savePrograms()
    }

    private func savePrograms() {
        if let encoded = try? JSONEncoder().encode(programs) {
            UserDefaults.standard.set(encoded, forKey: programsKey)
        }
    }

    private func loadPrograms() {
        if let data = UserDefaults.standard.data(forKey: programsKey),
           let decoded = try? JSONDecoder().decode([Program].self, from: data) {
            programs = decoded
        }
    }

    // MARK: - Session Progress Management

    func getSessionProgress(programID: UUID, sessionID: String) -> SessionProgress {
        let key = progressKey(programID: programID, sessionID: sessionID)
        if let data = UserDefaults.standard.data(forKey: key),
           let progress = try? JSONDecoder().decode(SessionProgress.self, from: data) {
            return progress
        }
        return SessionProgress()
    }

    func saveSessionProgress(_ progress: SessionProgress, programID: UUID, sessionID: String) {
        let key = progressKey(programID: programID, sessionID: sessionID)
        if let encoded = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    func deleteSessionProgress(programID: UUID, sessionID: String) {
        let key = progressKey(programID: programID, sessionID: sessionID)
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func deleteAllSessionProgress(for programID: UUID) {
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        let prefix = progressKeyPrefix + programID.uuidString
        allKeys.filter { $0.hasPrefix(prefix) }.forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
    }

    private func progressKey(programID: UUID, sessionID: String) -> String {
        return "\(progressKeyPrefix)\(programID.uuidString)_\(sessionID)"
    }

    // MARK: - Helper Methods

    func getSessions(for program: Program) -> [SessionItem] {
        switch program.programType {
        case "SmolovjJr":
            return SessionItem.smolovjSessions
        case "HPS":
            return SessionItem.hpsSessions
        default:
            return SessionItem.smolovjSessions
        }
    }

    func getCompletedSessionsCount(for programID: UUID) -> Int {
        guard let program = programs.first(where: { $0.id == programID }) else { return 0 }
        let sessions = getSessions(for: program)
        let sessionIDs = sessions.map { $0.id }
        return sessionIDs.filter { sessionID in
            getSessionProgress(programID: programID, sessionID: sessionID).isCompleted
        }.count
    }

    func getCurrentWeek(for programID: UUID) -> Int {
        guard let program = programs.first(where: { $0.id == programID }) else { return 1 }
        let completed = getCompletedSessionsCount(for: programID)

        if completed == 0 { return 1 }

        // プログラムタイプに応じた週計算
        if program.programType == "HPS" {
            // HPS: 週3回、4週間サイクル
            if completed <= 3 { return 1 }
            if completed <= 6 { return 2 }
            if completed <= 9 { return 3 }
            return 4
        } else {
            // SmolovjJr: 週4回、3週間サイクル
            if completed <= 4 { return 1 }
            if completed <= 8 { return 2 }
            return 3
        }
    }

    func getLastTrainingDate(for programID: UUID) -> Date? {
        let sessionIDs = SessionItem.allSessionIDs
        var latestDate: Date? = nil

        for sessionID in sessionIDs {
            let progress = getSessionProgress(programID: programID, sessionID: sessionID)
            if progress.isCompleted, let endTime = progress.endTime {
                if let latest = latestDate {
                    if endTime > latest {
                        latestDate = endTime
                    }
                } else {
                    latestDate = endTime
                }
            }
        }

        return latestDate
    }

    // MARK: - Export / Import

    func exportData() -> Data? {
        var progressMap: [String: SessionProgress] = [:]
        for program in programs {
            let sessions = getSessions(for: program)
            for session in sessions {
                let progress = getSessionProgress(programID: program.id, sessionID: session.id)
                if progress.completedSets > 0 || progress.isCompleted {
                    let key = "\(program.id.uuidString)_\(session.id)"
                    progressMap[key] = progress
                }
            }
        }

        let export = ExportData(
            version: 1,
            exportedAt: Date(),
            programs: programs,
            sessionProgressMap: progressMap
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(export)
    }

    func importData(_ data: Data, merge: Bool) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let exportData = try? decoder.decode(ExportData.self, from: data) else {
            return false
        }

        if !merge {
            for program in programs {
                deleteAllSessionProgress(for: program.id)
            }
            programs = exportData.programs
        } else {
            for program in exportData.programs where !programs.contains(where: { $0.id == program.id }) {
                programs.append(program)
            }
        }
        savePrograms()

        let encoder = JSONEncoder()
        for (key, progress) in exportData.sessionProgressMap {
            if let encoded = try? encoder.encode(progress) {
                UserDefaults.standard.set(encoded, forKey: progressKeyPrefix + key)
            }
        }
        return true
    }
}

// MARK: - Session Item (旧programの各要素)

struct SessionItem {
    let id: String
    let week: Int
    let day: Int
    let sets: Int
    let reps: Int
    let percent: Double
    let restTime: Int? // 休憩時間（秒）。nilの場合は動的計算

    // スモロフJr用セッション
    static let smolovjSessions: [SessionItem] = [
        // Week 1
        SessionItem(id: "1-1", week: 1, day: 1, sets: 6, reps: 6, percent: 0.70, restTime: nil),
        SessionItem(id: "1-2", week: 1, day: 2, sets: 7, reps: 5, percent: 0.75, restTime: nil),
        SessionItem(id: "1-3", week: 1, day: 3, sets: 8, reps: 4, percent: 0.80, restTime: nil),
        SessionItem(id: "1-4", week: 1, day: 4, sets: 10, reps: 3, percent: 0.85, restTime: nil),
        // Week 2
        SessionItem(id: "2-1", week: 2, day: 1, sets: 6, reps: 6, percent: 0.70, restTime: nil),
        SessionItem(id: "2-2", week: 2, day: 2, sets: 7, reps: 5, percent: 0.75, restTime: nil),
        SessionItem(id: "2-3", week: 2, day: 3, sets: 8, reps: 4, percent: 0.80, restTime: nil),
        SessionItem(id: "2-4", week: 2, day: 4, sets: 10, reps: 3, percent: 0.85, restTime: nil),
        // Week 3
        SessionItem(id: "3-1", week: 3, day: 1, sets: 6, reps: 6, percent: 0.70, restTime: nil),
        SessionItem(id: "3-2", week: 3, day: 2, sets: 7, reps: 5, percent: 0.75, restTime: nil),
        SessionItem(id: "3-3", week: 3, day: 3, sets: 8, reps: 4, percent: 0.80, restTime: nil),
        SessionItem(id: "3-4", week: 3, day: 4, sets: 10, reps: 3, percent: 0.85, restTime: nil),
    ]

    // HPS用セッション（4週間サイクル、週3回）
    static let hpsSessions: [SessionItem] = [
        // Week 1
        SessionItem(id: "h1-1", week: 1, day: 1, sets: 3, reps: 8, percent: 0.725, restTime: 90),  // H
        SessionItem(id: "h1-2", week: 1, day: 2, sets: 5, reps: 1, percent: 0.55, restTime: 120),  // P
        SessionItem(id: "h1-3", week: 1, day: 3, sets: 3, reps: 1, percent: 0.90, restTime: 240),  // S
        // Week 2
        SessionItem(id: "h2-1", week: 2, day: 1, sets: 3, reps: 8, percent: 0.725, restTime: 90),  // H
        SessionItem(id: "h2-2", week: 2, day: 2, sets: 5, reps: 1, percent: 0.55, restTime: 120),  // P
        SessionItem(id: "h2-3", week: 2, day: 3, sets: 3, reps: 1, percent: 0.90, restTime: 240),  // S
        // Week 3
        SessionItem(id: "h3-1", week: 3, day: 1, sets: 3, reps: 8, percent: 0.725, restTime: 90),  // H
        SessionItem(id: "h3-2", week: 3, day: 2, sets: 5, reps: 1, percent: 0.55, restTime: 120),  // P
        SessionItem(id: "h3-3", week: 3, day: 3, sets: 3, reps: 1, percent: 0.90, restTime: 240),  // S
        // Week 4
        SessionItem(id: "h4-1", week: 4, day: 1, sets: 3, reps: 8, percent: 0.725, restTime: 90),  // H
        SessionItem(id: "h4-2", week: 4, day: 2, sets: 5, reps: 1, percent: 0.55, restTime: 120),  // P
        SessionItem(id: "h4-3", week: 4, day: 3, sets: 3, reps: 1, percent: 0.90, restTime: 240),  // S
    ]

    // 下位互換性のため
    static var allSessions: [SessionItem] {
        return smolovjSessions
    }

    static var allSessionIDs: [String] {
        allSessions.map { $0.id }
    }
}

// MARK: - Speech Manager

class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    nonisolated(unsafe) private let synthesizer = AVSpeechSynthesizer()
    nonisolated(unsafe) private var deactivationTimer: Timer?

    override init() {
        super.init()
        synthesizer.delegate = self
        setupAmbient()
    }

    private func setupAmbient() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Ambient setup error: \(error)")
        }
    }

    func speak(_ text: String, isVoiceEnabled: Bool) {
        guard isVoiceEnabled else { return }

        deactivationTimer?.invalidate()
        deactivationTimer = nil

        activateInterruption()

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.rate = 0.55
        utterance.volume = 1.0

        synthesizer.speak(utterance)
    }

    private func activateInterruption() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [])
            try session.setActive(true)
        } catch {
            print("Interruption setup error: \(error)")
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        scheduleDeactivation()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        scheduleDeactivation()
    }

    private func scheduleDeactivation() {
        deactivationTimer?.invalidate()
        deactivationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.deactivateInterruption()
        }
    }

    private func deactivateInterruption() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("Deactivate error: \(error)")
        }
    }
}

// MARK: - Document Picker

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.json])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - Views

/// エントリーポイント：プログラム一覧画面
struct ContentView: View {
    @StateObject private var programManager = ProgramManager()
    @StateObject private var speechManager = SpeechManager()
    @State private var showingCreateProgram = false
    @State private var showingImportPicker = false
    @State private var pendingImportURL: URL? = nil
    @State private var showingImportAlert = false
    @State private var importError = false

    var body: some View {
        NavigationView {
            ProgramListView(programManager: programManager, speechManager: speechManager, showingCreateProgram: $showingCreateProgram)
                .navigationTitle("プログラム一覧")
                .navigationBarTitleDisplayMode(.automatic)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { showingCreateProgram = true }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            Button(action: { doExport() }) {
                                Label("エクスポート", systemImage: "square.and.arrow.up")
                            }
                            Button(action: { showingImportPicker = true }) {
                                Label("インポート", systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showingCreateProgram) {
                    ProgramCreateView(programManager: programManager, isPresented: $showingCreateProgram)
                }
                .sheet(isPresented: $showingImportPicker) {
                    DocumentPickerView { url in
                        pendingImportURL = url
                        showingImportPicker = false
                        showingImportAlert = true
                    }
                }
                .alert("インポート方法を選択", isPresented: $showingImportAlert) {
                    Button("上書き（全て置き換え）", role: .destructive) {
                        doImport(merge: false)
                    }
                    Button("追加（既存を保持）") {
                        doImport(merge: true)
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("「上書き」は既存のデータを全て削除して置き換えます。「追加」は既存データを保持したまま新しいプログラムを追加します。")
                }
                .alert("インポート失敗", isPresented: $importError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("ファイルの読み込みに失敗しました。正しいエクスポートファイルを選択してください。")
                }
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }

    private func doExport() {
        guard let data = programManager.exportData() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let dateStr = formatter.string(from: Date())
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("omoage_backup_\(dateStr).json")
        guard (try? data.write(to: tempURL)) != nil else { return }

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: 100, width: 0, height: 0)
            popover.permittedArrowDirections = .up
        }

        topVC.present(activityVC, animated: true)
    }

    private func doImport(merge: Bool) {
        guard let url = pendingImportURL,
              url.startAccessingSecurityScopedResource() else {
            importError = true
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url),
              programManager.importData(data, merge: merge) else {
            importError = true
            return
        }
    }
}

/// プログラム一覧画面
struct ProgramListView: View {
    @ObservedObject var programManager: ProgramManager
    @ObservedObject var speechManager: SpeechManager
    @Binding var showingCreateProgram: Bool

    var body: some View {
        Group {
            if programManager.programs.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("プログラムを追加してください")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Button(action: { showingCreateProgram = true }) {
                        Text("新しいプログラムを作成")
                            .font(.headline)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(programManager.programs) { program in
                        NavigationLink(destination: ProgramDetailView(program: program, programManager: programManager, speechManager: speechManager)) {
                            ProgramRowView(program: program, programManager: programManager)
                        }
                    }
                    .onDelete(perform: deletePrograms)
                }
            }
        }
    }

    private func deletePrograms(at offsets: IndexSet) {
        offsets.forEach { index in
            let program = programManager.programs[index]
            programManager.deleteProgram(program)
        }
    }
}

/// プログラム一覧の各行
struct ProgramRowView: View {
    let program: Program
    @ObservedObject var programManager: ProgramManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.name)
                        .font(.headline)
                    Text(programTypeDisplayName(program.programType))
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)
                }
                Spacer()

                // 経過日数バッジ
                daysSinceBadge

                Text("\(String(format: "%.1f", program.oneRM))kg")
                    .font(.callout)
                    .bold()
                    .foregroundColor(.blue)
            }

            HStack {
                let currentWeek = programManager.getCurrentWeek(for: program.id)
                let completedCount = programManager.getCompletedSessionsCount(for: program.id)

                Text("Week \(currentWeek)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("•")
                    .foregroundColor(.secondary)

                Text("\(completedCount)/12 完了")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text("増加幅: \(String(format: "%.1f", program.weeklyAdd))kg")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // 経過日数バッジビュー
    private var daysSinceBadge: some View {
        let (badgeText, badgeColor) = getDaysSinceInfo()

        return Text(badgeText)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(badgeColor))
    }

    // 経過日数とバッジ色を計算
    private func getDaysSinceInfo() -> (String, Color) {
        guard let lastDate = programManager.getLastTrainingDate(for: program.id) else {
            // 未開始の場合
            return ("-", Color.gray)
        }

        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastDate), to: calendar.startOfDay(for: now))
        let daysSince = components.day ?? 0

        if daysSince >= 7 {
            return ("\(daysSince)", Color.red)
        } else {
            return ("\(daysSince)", Color.green)
        }
    }

    private func programTypeDisplayName(_ type: String) -> String {
        switch type {
        case "SmolovjJr":
            return "スモロフJr."
        case "HPS":
            return "HPS"
        case "531":
            return "5/3/1"
        case "GZCL":
            return "GZCL"
        default:
            return type
        }
    }
}

/// プログラム作成画面
struct ProgramCreateView: View {
    @ObservedObject var programManager: ProgramManager
    @Binding var isPresented: Bool

    @State private var programType: String = "SmolovjJr"
    @State private var name: String = "ベンチプレス"
    @State private var startingSession: String = "1-1" // W1-D1から開始
    @State private var oneRM: Double = 80.0
    @State private var weeklyAdd: Double = 2.5

    @State private var showWeightHelp = false

    private let exerciseOptions = ["ベンチプレス", "スクワット", "デッドリフト", "アームカール", "サイドレイズ", "ショルダープレス", "その他"]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("プログラムタイプ")) {
                    Picker("タイプ", selection: $programType) {
                        Text("スモロフJr.").tag("SmolovjJr")
                        Text("HPS").tag("HPS")
                        // 将来追加予定：
                        // Text("5/3/1").tag("531")
                        // Text("GZCL").tag("GZCL")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: programType) {
                        // プログラムタイプが変更されたら、開始位置をリセット
                        startingSession = programType == "HPS" ? "h1-1" : "1-1"
                    }

                    if programType == "SmolovjJr" {
                        Text("3週間サイクル、週4回のプログラム")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if programType == "HPS" {
                        Text("4週間サイクル、週3回（筋肥大・パワー・筋力）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("種目情報")) {
                    Picker("種目", selection: $name) {
                        ForEach(exerciseOptions, id: \.self) { exercise in
                            Text(exercise).tag(exercise)
                        }
                    }

                    Picker("開始位置", selection: $startingSession) {
                        let sessions = programType == "HPS" ? SessionItem.hpsSessions : SessionItem.smolovjSessions
                        ForEach(sessions, id: \.id) { session in
                            Text("Week \(session.week) - Day \(session.day)").tag(session.id)
                        }
                    }

                    HStack {
                        Text("1RM (MAX重量):")
                        Spacer()
                        TextField("80", value: $oneRM, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("kg")
                    }
                }

                Section(header: Text("プログラム設定")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("重量増加幅 /週")
                            Button(action: { showWeightHelp = true }) {
                                Image(systemName: "questionmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.title3)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        Picker("増加幅", selection: $weeklyAdd) {
                            Text("2.5 kg").tag(2.5)
                            Text("5.0 kg").tag(5.0)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .navigationTitle("新しいプログラム")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("作成") {
                        createProgram()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .sheet(isPresented: $showWeightHelp) { WeightHelpView() }
        }
    }

    private func createProgram() {
        let newProgram = Program(
            programType: programType,
            name: name,
            oneRM: oneRM,
            weeklyAdd: weeklyAdd
        )
        programManager.addProgram(newProgram)

        // 開始位置がデフォルト以外の場合、それより前のセッションを完了済みにする
        let sessions = programType == "HPS" ? SessionItem.hpsSessions : SessionItem.smolovjSessions
        let defaultStartID = programType == "HPS" ? "h1-1" : "1-1"

        if startingSession != defaultStartID {
            let startIndex = sessions.firstIndex(where: { $0.id == startingSession }) ?? 0
            for i in 0..<startIndex {
                let session = sessions[i]
                var progress = SessionProgress(completedSets: session.sets, isCompleted: true)
                progress.startTime = Date()
                progress.endTime = Date()
                programManager.saveSessionProgress(progress, programID: newProgram.id, sessionID: session.id)
            }
        }

        isPresented = false
    }
}

/// プログラム詳細画面（旧ContentView）
struct ProgramDetailView: View {
    let program: Program
    @ObservedObject var programManager: ProgramManager
    @ObservedObject var speechManager: SpeechManager

    @AppStorage("isVoiceEnabled") private var isVoiceEnabled: Bool = true
    @State private var showWeightHelp = false
    @State private var reloadID = UUID()

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%02d:%02d", m, s)
    }

    func roundTo2_5(_ value: Double) -> Double {
        return (value / 2.5).rounded() * 2.5
    }

    var body: some View {
        List {
            Section(header: Text("基本設定")) {
                Toggle(isOn: $isVoiceEnabled) {
                    HStack {
                        Image(systemName: isVoiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .foregroundColor(isVoiceEnabled ? .blue : .gray)
                        Text("音声ガイド")
                    }
                }
                .padding(.vertical, 4)

                HStack {
                    Text("種目:")
                    Spacer()
                    Text(program.name)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("1RM (MAX重量):")
                    Spacer()
                    Text("\(String(format: "%.1f", program.oneRM)) kg")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                HStack {
                    Text("重量増加幅 /週:")
                    Button(action: { showWeightHelp = true }) {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundColor(.blue)
                            .font(.title3)
                    }
                    .buttonStyle(PlainButtonStyle())
                    Spacer()
                    Text("\(String(format: "%.1f", program.weeklyAdd)) kg")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("スケジュール\(program.programType == "SmolovjJr" ? " (\(String(format: "%.1f", program.weeklyAdd))kg刻み)" : "")")) {
                ForEach(programManager.getSessions(for: program), id: \.id) { item in
                    let addedWeight = program.programType == "HPS" ? 0 : (item.week == 1 ? 0 : (item.week == 2 ? program.weeklyAdd : program.weeklyAdd * 2))
                    let rawWeight = (program.oneRM * item.percent) + addedWeight
                    let weight = roundTo2_5(rawWeight)

                    let progress = programManager.getSessionProgress(programID: program.id, sessionID: item.id)

                    NavigationLink(destination: SessionDetailView(
                        program: program,
                        session: item,
                        calculatedWeight: weight,
                        programManager: programManager,
                        speechManager: speechManager
                    )) {
                        HStack(alignment: .top) {
                            Image(systemName: progress.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(progress.isCompleted ? .green : .gray)
                                .font(.system(size: 24))
                                .padding(.top, 4)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Week \(item.week) - Day \(item.day)")
                                        .font(.headline)
                                        .foregroundColor(progress.isCompleted ? .secondary : .primary)
                                    Spacer()
                                    Text("\(String(format: "%.1f", weight))kg")
                                        .font(.callout)
                                        .bold()
                                        .foregroundColor(progress.isCompleted ? .gray : .blue)
                                }

                                Text("\(item.reps)回 x \(item.sets)セット")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if progress.isCompleted, let start = progress.startTime, let end = progress.endTime {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("日時: \(dateFormatter.string(from: start)) 〜 \(dateFormatter.string(from: end))")
                                        HStack {
                                            Text("総時間: \(formatDuration(end.timeIntervalSince(start)))")
                                            Text("内休憩: \(formatDuration(progress.totalRest))")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(4)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(4)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle(program.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWeightHelp) { WeightHelpView() }
        .id(reloadID)
        .onAppear {
            reloadID = UUID()
        }
    }
}

// ---------------------------------------------------------
// ヘルプ画面1: 増加幅について
// ---------------------------------------------------------
struct WeightHelpView: View {
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(.yellow)
                        .font(.title)
                    Text("増加幅の選び方")
                        .font(.title2)
                        .bold()
                }
                .padding(.top, 20)

                HStack(alignment: .top, spacing: 15) {
                    Image(systemName: "checkmark.square.fill")
                        .foregroundColor(.green)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("2.5 kg (推奨)")
                            .font(.headline)
                        Text("ベンチプレスなど、比較的小さな筋肉群向け。関節への負担を抑え、神経系の適応を優先する安全な進行です。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 15) {
                    Image(systemName: "flame.fill")
                        .foregroundColor(.orange)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("5.0 kg (ハード)")
                            .font(.headline)
                        Text("スクワットなど、大筋群を使う種目向け。負荷が非常に高く、回復能力（リカバリー）の限界に挑む設定です。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Text("閉じる")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.bottom, 20)
            }
            .padding(24)
            .navigationBarHidden(true)
        }
    }
}

// ---------------------------------------------------------
// ヘルプ画面2: 時間制限モードについて
// ---------------------------------------------------------
struct TimeLimitHelpView: View {
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "clock.fill")
                        .foregroundColor(.blue)
                        .font(.title)
                    Text("リカバリー制御設定")
                        .font(.title2)
                        .bold()
                }
                .padding(.top, 20)

                Text("生理学的なエネルギー供給機構（ATP-CP系）の回復理論に基づき、状況に合わせて休憩時間を最適化します。")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(alignment: .top, spacing: 15) {
                    Image(systemName: "figure.mind.and.body")
                        .foregroundColor(.green)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("制限なし (推奨)")
                            .font(.headline)
                        Text("クレアチンリン酸の再合成がほぼ完了する「3分」をベースに、後半は中枢神経系(CNS)の疲労回復も考慮して「5分」まで延長。\n高強度セットにおけるモーターユニットの動員率を最大化します。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 15) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundColor(.red)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("制限あり (短縮)")
                            .font(.headline)
                        Text("ジムの利用時間制限などの外部要因に合わせて、インターバルを逆算・圧縮します。\n不完全回復下でのトレーニングとなり代謝ストレスは高まりますが、最大出力は低下する可能性があります。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Text("閉じる")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.bottom, 20)
            }
            .padding(24)
            .navigationBarHidden(true)
        }
    }
}

// ---------------------------------------------------------
// セッション詳細画面（旧WorkoutDetailView）
// ---------------------------------------------------------
struct SessionDetailView: View {
    let program: Program
    let session: SessionItem
    let calculatedWeight: Double

    @ObservedObject var programManager: ProgramManager
    @ObservedObject var speechManager: SpeechManager

    @AppStorage("isVoiceEnabled") private var isVoiceEnabled: Bool = true
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.presentationMode) var presentationMode

    @State private var isSessionStarted = false
    @State private var sessionStartTime: Date? = nil
    @State private var totalElapsedTime: TimeInterval = 0
    @State private var totalRestAccumulated: TimeInterval = 0

    @State private var completedSets = 0
    @State private var isFinished = false
    @State private var finishedDate: Date? = nil
    @State private var setCompletedTimes: [Date] = []
    @State private var assignedRestDurations: [Int] = []

    @State private var isResting = false
    @State private var timeRemaining = 180
    @State private var currentRestDuration = 180

    // レスト開始時刻を保存する用（バックグラウンド復帰対応）
    @State private var restStartTime: Date? = nil

    // 時間制限モード（セッションごとに設定可能）
    @State private var useTimeLimit: Bool = false
    @State private var timeLimit: Double = 20.0
    @State private var showTimeLimitHelp = false

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private func timeString(time: Int) -> String {
        let t = max(0, time)
        let minutes = t / 60
        let seconds = t % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func speak(_ text: String) {
        speechManager.speak(text, isVoiceEnabled: isVoiceEnabled)
    }

    // MARK: - Session Control

    private func startSession() {
        completedSets = 0
        isSessionStarted = true
        let now = Date()
        sessionStartTime = now

        var progress = programManager.getSessionProgress(programID: program.id, sessionID: session.id)
        progress.startTime = now
        programManager.saveSessionProgress(progress, programID: program.id, sessionID: session.id)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        speak("トレーニングを開始します。頑張りましょう。")
    }

    private func loadProgress() {
        let progress = programManager.getSessionProgress(programID: program.id, sessionID: session.id)

        if progress.isCompleted {
            completedSets = session.sets
            isFinished = true
            finishedDate = progress.endTime
            sessionStartTime = progress.startTime
            totalRestAccumulated = progress.totalRest
            isSessionStarted = true
            return
        }

        if progress.completedSets > 0 {
            completedSets = progress.completedSets
            sessionStartTime = progress.startTime
            totalRestAccumulated = progress.totalRest
            setCompletedTimes = progress.setCompletedTimes ?? []
            assignedRestDurations = progress.assignedRestDurations ?? []
            isSessionStarted = true

            // 休憩状態の復元
            if progress.isResting, let restStart = progress.restStartTime {
                let elapsed = Date().timeIntervalSince(restStart)
                let remaining = Double(progress.restDuration) - elapsed
                if remaining > 0 {
                    isResting = true
                    restStartTime = restStart
                    currentRestDuration = progress.restDuration
                    timeRemaining = Int(ceil(remaining))
                } else {
                    // 休憩時間が既に終了している
                    isResting = false
                    restStartTime = nil
                    speak("休憩終了です。次のセットを始めてください")
                }
            }
        } else {
            isSessionStarted = false
        }
    }

    private func updateTimerState() {
        guard isSessionStarted, !isFinished else { return }
        if let start = sessionStartTime {
            totalElapsedTime = Date().timeIntervalSince(start)
        }
    }

    private func proceedSet() {
        if completedSets < session.sets {
            completedSets += 1
            setCompletedTimes.append(Date())

            var progress = programManager.getSessionProgress(programID: program.id, sessionID: session.id)
            progress.completedSets = completedSets
            progress.totalRest = totalRestAccumulated
            progress.setCompletedTimes = setCompletedTimes

            if completedSets >= session.sets {
                programManager.saveSessionProgress(progress, programID: program.id, sessionID: session.id)
                finishSession()
            } else {
                startRestTimer()
                assignedRestDurations.append(currentRestDuration)
                progress.assignedRestDurations = assignedRestDurations
                programManager.saveSessionProgress(progress, programID: program.id, sessionID: session.id)
            }
        }
    }

    private func finishSession() {
        let now = Date()

        var progress = programManager.getSessionProgress(programID: program.id, sessionID: session.id)
        progress.isCompleted = true
        progress.endTime = now
        progress.totalRest = totalRestAccumulated
        if progress.startTime == nil {
            progress.startTime = sessionStartTime ?? now
        }
        programManager.saveSessionProgress(progress, programID: program.id, sessionID: session.id)

        finishedDate = now
        isFinished = true
        isResting = false
        restStartTime = nil
        speak("お疲れ様でした。トレーニング完了です")
    }

    private func startRestTimer() {
        var restTime = 180

        if useTimeLimit && timeLimit > 0, let start = sessionStartTime {
            // 実際の経過時間ベースで動的再計算（ウジウジ時間も吸収）
            let elapsed = Date().timeIntervalSince(start)
            let setsLeft = Double(session.sets - completedSets)
            let liftTimeRemaining = setsLeft * 45.0
            let remainingBudget = timeLimit * 60.0 - elapsed - liftTimeRemaining
            restTime = Int(max(30.0, remainingBudget / setsLeft))
        } else if let fixedRestTime = session.restTime {
            // セッションに固定の休憩時間が設定されている場合（HPSなど）
            restTime = fixedRestTime
        } else {
            // スモロフJrの動的計算
            if session.week == 2 { restTime += 30 }
            else if session.week == 3 { restTime += 60 }
            if completedSets >= (session.sets / 2) { restTime += 60 }
        }

        timeRemaining = restTime
        currentRestDuration = restTime
        isResting = true
        restStartTime = Date()

        let m = restTime / 60
        let s = restTime % 60
        var speech = "休憩に入ります。"
        if m > 0 { speech += "\(m)分" }
        if s > 0 { speech += "\(s)秒" }
        speak(speech)

        scheduleRestEndNotification(restTime: restTime)
    }

    private static let restNotificationID = "rest_end"

    private func scheduleRestEndNotification(restTime: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.restNotificationID])

        let nextSetNumber = completedSets + 1
        let remainingSets = session.sets - completedSets - 1
        let weightStr = String(format: "%.1f", calculatedWeight)
        let body: String
        if remainingSets > 0 {
            body = "\(nextSetNumber)set目 \(weightStr)kg×\(session.reps) | 残り\(remainingSets)set"
        } else {
            body = "\(nextSetNumber)set目（最終セット） \(weightStr)kg×\(session.reps)"
        }

        let content = UNMutableNotificationContent()
        content.title = "休憩終了"
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(restTime), repeats: false)
        let request = UNNotificationRequest(identifier: Self.restNotificationID, content: content, trigger: trigger)
        center.add(request)
    }

    private func resetProgress() {
        completedSets = 0
        isFinished = false
        finishedDate = nil
        isResting = false
        isSessionStarted = false
        sessionStartTime = nil
        totalElapsedTime = 0
        totalRestAccumulated = 0
        restStartTime = nil
        setCompletedTimes = []
        assignedRestDurations = []

        programManager.deleteSessionProgress(programID: program.id, sessionID: session.id)
    }

    private func undoLastSet() {
        if completedSets > 0 {
            completedSets -= 1

            var progress = programManager.getSessionProgress(programID: program.id, sessionID: session.id)
            progress.completedSets = completedSets
            programManager.saveSessionProgress(progress, programID: program.id, sessionID: session.id)

            isResting = false
            restStartTime = nil
        }
    }

    private func skipRest() {
        isResting = false
        restStartTime = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.restNotificationID])
        speak("休憩を終了します")
    }

    var body: some View {
        VStack(spacing: 0) {
            if isSessionStarted && !isFinished {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "stopwatch")
                        Text(timeString(time: Int(totalElapsedTime)))
                            .font(.system(.body, design: .monospaced))
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "bed.double.fill")
                        Text(timeString(time: Int(totalRestAccumulated)))
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .padding()
                .background(Color(UIColor.systemGray6))
            }

            ScrollView {
                VStack(spacing: 30) {
                    VStack(spacing: 10) {
                        Text(program.name)
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Text("Week \(session.week) - Day \(session.day)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("\(String(format: "%.1f", calculatedWeight)) kg")
                            .font(.system(size: 64, weight: .heavy, design: .rounded))
                            .foregroundColor(.primary)

                        HStack {
                            Image(systemName: "scalemass")
                            Text("目標: \(session.reps)回 x \(session.sets)セット")
                            if useTimeLimit && timeLimit > 0 {
                                Text("(\(Int(timeLimit))分制限)")
                                    .font(.caption).foregroundColor(.red).bold()
                            }
                        }
                        .font(.title3)
                        .foregroundColor(.gray)
                    }
                    .padding(.top)

                    // 時間制限モード設定（トレーニング開始前のみ表示）
                    if !isSessionStarted {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $useTimeLimit) {
                                HStack {
                                    Text("時間制限モード")
                                        .font(.headline)
                                    Button(action: { showTimeLimitHelp = true }) {
                                        Image(systemName: "questionmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    if useTimeLimit {
                                        Image(systemName: "clock.badge.exclamationmark")
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                            .padding()
                            .background(Color(UIColor.systemGray6))
                            .cornerRadius(12)

                            if useTimeLimit {
                                VStack(spacing: 8) {
                                    Text("制限時間")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Picker("制限時間", selection: $timeLimit) {
                                        Text("20分").tag(20.0)
                                        Text("30分").tag(30.0)
                                        Text("45分").tag(45.0)
                                    }
                                    .pickerStyle(.segmented)
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.horizontal)
                    }

                    Divider()

                    if isFinished {
                        FinishView(
                            finishedDate: finishedDate,
                            resetAction: resetProgress,
                            sessionStartTime: sessionStartTime,
                            setCompletedTimes: setCompletedTimes,
                            assignedRestDurations: assignedRestDurations
                        )
                    } else if !isSessionStarted {
                        Button(action: {
                            withAnimation { startSession() }
                        }) {
                            VStack(spacing: 8) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 60))
                                Text("トレーニング開始")
                                    .font(.title2)
                                    .bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(20)
                            .shadow(radius: 5)
                        }
                        .padding(.horizontal)

                    } else if isResting {
                        VStack(spacing: 20) {
                            Text("休憩中")
                                .font(.title)
                                .foregroundColor(.orange)
                                .bold()

                            VStack(spacing: 5) {
                                Text("残り: \(session.sets - completedSets) セット")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 6) {
                                ForEach(0..<session.sets, id: \.self) { index in
                                    if index < completedSets {
                                        Image(systemName: "square.fill").foregroundColor(.blue)
                                    } else {
                                        Image(systemName: "square").foregroundColor(.gray.opacity(0.3))
                                    }
                                }
                            }
                            .font(.title3)

                            Text(timeString(time: timeRemaining))
                                .font(.system(size: 90, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange)

                            VStack(spacing: 4) {
                                Text("今回の休憩時間: \(currentRestDuration / 60)分 \(currentRestDuration % 60)秒")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                if useTimeLimit {
                                    let sessionLeft = max(0, timeLimit * 60 - totalElapsedTime)
                                    Text("セッション残り: \(timeString(time: Int(sessionLeft)))")
                                        .font(.caption)
                                        .foregroundColor(sessionLeft < 60 ? .red : .orange)
                                        .bold()
                                }
                            }

                            Button(action: skipRest) {
                                Text("休憩を終了して次へ")
                                    .font(.headline)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundColor(.orange)
                                    .cornerRadius(12)
                            }
                            .padding(.horizontal, 40)
                            .padding(.top, 10)

                            Button("一覧に戻る") {
                                presentationMode.wrappedValue.dismiss()
                            }
                            .padding(.top, 10)
                        }
                        .transition(.opacity)

                    } else {
                        VStack {
                            Text("現在のセット数")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("\(completedSets + 1) / \(session.sets)")
                                .font(.system(size: 80, weight: .bold))
                                .foregroundColor(.blue)
                                .contentTransition(.numericText(value: Double(completedSets + 1)))

                            Button(action: {
                                withAnimation(.spring()) { proceedSet() }
                            }) {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("セット完了 (休憩開始)")
                                }
                                .font(.title2)
                                .bold()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(20)
                                .shadow(radius: 5, y: 5)
                            }
                            .padding(.horizontal, 40)
                            .padding(.top, 20)

                            if completedSets > 0 {
                                Button("1つ戻す") {
                                    undoLastSet()
                                }
                                .padding(.top, 20)
                                .foregroundColor(.gray)
                            }

                            Button("一覧に戻る") {
                                presentationMode.wrappedValue.dismiss()
                            }
                            .padding(.top, 20)
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle("W\(session.week)-D\(session.day)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { isVoiceEnabled.toggle() }) {
                    Image(systemName: isVoiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .foregroundColor(isVoiceEnabled ? .blue : .gray)
                }
            }
        }
        .sheet(isPresented: $showTimeLimitHelp) { TimeLimitHelpView() }
        .onAppear { loadProgress() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                updateTimerState()
                // レスト中にバックグラウンドから復帰した場合の処理
                if isResting, let restStart = restStartTime {
                    let elapsed = Date().timeIntervalSince(restStart)
                    let remaining = Double(currentRestDuration) - elapsed
                    if remaining > 0 {
                        timeRemaining = Int(ceil(remaining))
                    } else {
                        timeRemaining = 0
                        isResting = false
                        restStartTime = nil
                        speak("休憩終了です。次のセットを始めてください")
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            if isSessionStarted && !isFinished {
                updateTimerState()

                if isResting {
                    totalRestAccumulated += 1
                    if timeRemaining > 0 {
                        timeRemaining -= 1
                    }

                    if timeRemaining == 30 {
                        speak("あと30秒で次のセット開始です。準備を始めてください")
                    } else if timeRemaining == 10 {
                        speak("あと10秒です")
                    } else if timeRemaining > 0 && timeRemaining < 10 {
                        speak("\(timeRemaining)")
                    } else if timeRemaining == 0 {
                        isResting = false
                        restStartTime = nil
                        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.restNotificationID])
                        speak("休憩終了です。次のセットを始めてください")
                    }
                }
            }
        }
        .onDisappear {
            if isSessionStarted {
                var progress = programManager.getSessionProgress(programID: program.id, sessionID: session.id)
                progress.totalRest = totalRestAccumulated
                progress.isResting = isResting
                progress.restStartTime = restStartTime
                progress.restDuration = currentRestDuration
                programManager.saveSessionProgress(progress, programID: program.id, sessionID: session.id)
            }
        }
    }
}

struct FinishView: View {
    let finishedDate: Date?
    let resetAction: () -> Void
    let sessionStartTime: Date?
    let setCompletedTimes: [Date]
    let assignedRestDurations: [Int]

    @Environment(\.presentationMode) var presentationMode

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }

    private func durationString(_ interval: TimeInterval) -> String {
        let t = max(0, Int(interval))
        let m = t / 60
        let s = t % 60
        return m > 0 ? "\(m)分\(s)秒" : "\(s)秒"
    }

    // セット番号・直前イベントからの経過時間・休憩設定のタプル配列
    private var timeline: [(setNumber: Int, setDuration: TimeInterval, restSeconds: Int?)] {
        guard let start = sessionStartTime, !setCompletedTimes.isEmpty else { return [] }
        return setCompletedTimes.enumerated().map { i, completedAt in
            let prev = i == 0 ? start : setCompletedTimes[i - 1]
            let rest = i < assignedRestDurations.count ? assignedRestDurations[i] : nil
            return (setNumber: i + 1, setDuration: completedAt.timeIntervalSince(prev), restSeconds: rest)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 80))
                .foregroundColor(.yellow)
                .padding()
                .background(Circle().fill(Color.yellow.opacity(0.2)))

            Text("トレーニング完了！")
                .font(.title)
                .bold()

            if let date = finishedDate {
                Text("完了日時: \(dateFormatter.string(from: date))")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            // タイムライン
            if !timeline.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("タイムライン")
                        .font(.headline)
                        .padding(.bottom, 8)

                    ForEach(timeline, id: \.setNumber) { item in
                        // セット行
                        HStack {
                            Text("セット\(item.setNumber)")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 70, alignment: .leading)
                            Spacer()
                            Text(durationString(item.setDuration))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.blue)
                        }
                        .padding(.vertical, 4)

                        // 休憩行（最終セット以外）
                        if let rest = item.restSeconds {
                            HStack {
                                Text("  └ 休憩")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 70, alignment: .leading)
                                Spacer()
                                Text(durationString(TimeInterval(rest)))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.orange)
                            }
                            .padding(.bottom, 2)
                        }
                    }
                }
                .padding()
                .background(Color(UIColor.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)
            }

            Text("お疲れ様でした。\nしっかり栄養を取って休みましょう。")
                .multilineTextAlignment(.center)

            Button("未完了に戻す") { resetAction() }
                .foregroundColor(.red)
                .padding(.top, 20)

            Button("一覧に戻る") { presentationMode.wrappedValue.dismiss() }
                .padding(.top, 10)
        }
        .transition(.scale)
    }
}

#Preview {
    ContentView()
}
