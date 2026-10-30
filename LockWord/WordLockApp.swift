import SwiftUI
import Combine

private let builtInDecks = ["초등", "중등 기본", "중등 고난도", "고등 기본", "고등 고난도", "고등 최상위", "회화"]

struct VocabWord: Codable, Identifiable, Equatable {
    var id: String { "\(deck.lowercased())|\(english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }
    var english: String
    var meaning: String
    var part: String = ""
    var example: String = ""
    var deck: String
    var mastered = false
    var wrongCount = 0
    var skippedCount = 0
}

struct StudySession: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var correct = 0
    var wrong = 0
}

@MainActor final class LearningStore: ObservableObject {
    @Published var words: [VocabWord] = [] { didSet { save() } }
    @Published var sessions: [StudySession] = [] { didSet { save() } }
    @Published var selectedDecks: Set<String> = Set(builtInDecks) { didSet { save() } }
    @Published var questionCount = 10 { didSet { save() } }
    @Published var spellingMode = false { didSet { save() } }
    @Published var darkMode = true { didSet { save() } }
    @Published var dailyWords: [String] = [] { didSet { save() } }
    @Published var dailyDate = "" { didSet { save() } }
    @Published var personalDecks: Set<String> = [] { didSet { save() } }

    private struct Persisted: Codable {
        var words: [VocabWord]
        var sessions: [StudySession]
        var selectedDecks: Set<String>
        var questionCount: Int
        var spellingMode: Bool
        var darkMode: Bool
        var dailyWords: [String]
        var dailyDate: String
        var personalDecks: Set<String>
    }

    init() {
        let url = Self.fileURL
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            words = saved.words
            sessions = saved.sessions
            selectedDecks = saved.selectedDecks
            questionCount = min(max(saved.questionCount, 3), 100)
            spellingMode = saved.spellingMode
            darkMode = saved.darkMode
            dailyWords = saved.dailyWords
            dailyDate = saved.dailyDate
            personalDecks = saved.personalDecks
            mergeBundledWords()
        } else {
            words = Self.loadBundledWords()
            sessions = []
            createDailySetIfNeeded()
        }
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WordLock", isDirectory: true)
            .appendingPathComponent("learning-data-v1.json")
    }

    private static func loadBundledWords() -> [VocabWord] {
        guard let url = Bundle.main.url(forResource: "built_in_words", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return CSV.read(text).dropFirst().compactMap { row in
            guard row.count >= 5 else { return nil }
            let english = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let meaning = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !english.isEmpty, !meaning.isEmpty else { return nil }
            return VocabWord(english: english, meaning: meaning, part: row[2], example: row[3], deck: row[4])
        }
    }

    private func mergeBundledWords() {
        let existing = Dictionary(words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bundled = Self.loadBundledWords().map { fresh in
            guard let old = existing[fresh.id] else { return fresh }
            var updated = fresh
            updated.mastered = old.mastered
            updated.wrongCount = old.wrongCount
            updated.skippedCount = old.skippedCount
            return updated
        }
        let personal = words.filter { !builtInDecks.contains($0.deck) }
        words = bundled + personal
        createDailySetIfNeeded()
    }

    private func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = Persisted(words: words, sessions: sessions, selectedDecks: selectedDecks,
                                  questionCount: questionCount, spellingMode: spellingMode,
                                  darkMode: darkMode, dailyWords: dailyWords, dailyDate: dailyDate,
                                  personalDecks: personalDecks)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            // Keep learning usable when local storage is temporarily unavailable.
        }
    }

    var deckNames: [String] { builtInDecks + Array(personalDecks.union(Set(words.map(\.deck).filter { !builtInDecks.contains($0) }))).sorted() }
    var totalUniqueWords: Int { Set(words.map { $0.english.lowercased() }).count }
    var wrongWords: [VocabWord] { words.filter { $0.wrongCount > 0 || $0.skippedCount > 0 }.sorted { $0.wrongCount + $0.skippedCount > $1.wrongCount + $1.skippedCount } }
    var todayKey: String { Self.dayFormatter.string(from: Date()) }
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"; return f
    }()

    func createDailySetIfNeeded() {
        guard dailyDate != todayKey || dailyWords.isEmpty else { return }
        let available = words.filter { selectedDecks.contains($0.deck) && !$0.mastered }
        dailyWords = Array(available.shuffled().prefix(30).map(\.id))
        dailyDate = todayKey
    }

    func markAnswer(word: VocabWord, correct: Bool, skipped: Bool = false) {
        guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
        if correct { return }
        words[index].wrongCount += 1
        if skipped { words[index].skippedCount += 1 }
    }

    func setMastered(_ word: VocabWord, _ value: Bool) {
        guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
        words[index].mastered = value
        if value, let dailyIndex = dailyWords.firstIndex(of: word.id),
           let replacement = words.filter({ !$0.mastered && !dailyWords.contains($0.id) && selectedDecks.contains($0.deck) }).randomElement() {
            dailyWords[dailyIndex] = replacement.id
        }
    }

    func addWord(english: String, meaning: String, deck: String) -> Bool {
        let e = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, !m.isEmpty, !words.contains(where: { $0.deck == deck && $0.english.caseInsensitiveCompare(e) == .orderedSame }) else { return false }
        words.append(VocabWord(english: e, meaning: m, deck: deck)); return true
    }

    func addDeck(name: String) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= 40,
              !deckNames.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) else { return false }
        personalDecks.insert(candidate)
        selectedDecks.insert(candidate)
        return true
    }

    func renameDeck(_ old: String, to new: String) -> Bool {
        let candidate = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !builtInDecks.contains(old), !candidate.isEmpty, candidate.count <= 40,
              !builtInDecks.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }),
              !deckNames.contains(where: { $0 != old && $0.caseInsensitiveCompare(candidate) == .orderedSame }) else { return false }
        for index in words.indices where words[index].deck == old { words[index].deck = candidate }
        personalDecks.remove(old)
        personalDecks.insert(candidate)
        if selectedDecks.remove(old) != nil { selectedDecks.insert(candidate) }
        if dailyWords.contains(where: { $0.hasPrefix(old.lowercased() + "|") }) {
            dailyDate = ""
            createDailySetIfNeeded()
        }
        return true
    }
}

private enum CSV {
    static func read(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"" where field.isEmpty: quoted = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                case "\r": break
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

@main struct WordLockApp: App {
    @StateObject private var store = LearningStore()
    var body: some Scene {
        WindowGroup { RootTabs().environmentObject(store).preferredColorScheme(store.darkMode ? .dark : .light) }
    }
}

struct RootTabs: View {
    var body: some View {
        TabView {
            HomeView().tabItem { Label("홈", systemImage: "house.fill") }
            WordbooksView().tabItem { Label("단어장", systemImage: "books.vertical.fill") }
            WrongView().tabItem { Label("오답", systemImage: "arrow.uturn.backward.circle.fill") }
            HistoryView().tabItem { Label("기록", systemImage: "chart.bar.fill") }
            SettingsView().tabItem { Label("설정", systemImage: "slider.horizontal.3") }
        }.tint(Color(red: 0.38, green: 0.82, blue: 0.69))
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: LearningStore
    @State private var showQuiz = false
    @State private var daily = false
    private var todayCorrect: Int { store.sessions.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.correct } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WordLock").font(.largeTitle.bold())
                        Text("짧게 풀고, 자주 만나는 영어").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        MetricCard(title: "오늘 정답", value: "\(todayCorrect)", icon: "checkmark.circle.fill")
                        MetricCard(title: "복습할 오답", value: "\(store.wrongWords.count)", icon: "arrow.uturn.backward.circle.fill")
                    }
                    Button { daily = true; store.createDailySetIfNeeded(); showQuiz = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "sun.max.fill").font(.title2).foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 4) { Text("오늘의 Daily").font(.headline); Text("\(store.dailyWords.count)개 단어 · 오늘 목록으로 퀴즈").font(.subheadline).foregroundStyle(.secondary) }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(18).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("바로 학습").font(.title3.bold())
                        Button { daily = false; showQuiz = true } label: {
                            Label("퀴즈 시작", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 17)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white)
                        }
                        Text("선택한 단어장 · \(store.questionCount)문제").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    HStack { Label("전체 단어", systemImage: "text.book.closed"); Spacer(); Text("\(store.totalUniqueWords.formatted())개").bold() }
                        .padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    Text("iPhone에서는 학습 중에도 긴급 통화와 알림을 사용할 수 있어요.").font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }
            .navigationBarHidden(true)
            .fullScreenCover(isPresented: $showQuiz) { QuizView(daily: daily).environmentObject(store) }
        }
    }
}

private struct MetricCard: View {
    var title: String; var value: String; var icon: String
    var body: some View { VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).foregroundStyle(.mint); Text(value).font(.title.bold()); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16)) }
}

struct WordbooksView: View {
    @EnvironmentObject private var store: LearningStore
    @State private var newDeck = ""
    @State private var adding = false
    @State private var editDeck: String?
    var body: some View {
        NavigationStack {
            List {
                Section("출제할 단어장") {
                    ForEach(store.deckNames, id: \.self) { deck in
                        let deckWords = store.words.filter { $0.deck == deck }
                        HStack {
                            Button { if store.selectedDecks.contains(deck) { store.selectedDecks.remove(deck) } else { store.selectedDecks.insert(deck) } } label: {
                                Image(systemName: store.selectedDecks.contains(deck) ? "checkmark.circle.fill" : "circle").foregroundStyle(store.selectedDecks.contains(deck) ? .mint : .secondary)
                            }.buttonStyle(.plain)
                            NavigationLink(destination: DeckDetailView(deck: deck).environmentObject(store)) {
                                VStack(alignment: .leading) { Text(deck).font(.headline); Text("\(deckWords.count)개 · 암기 \(deckWords.filter(\.mastered).count)개").font(.caption).foregroundStyle(.secondary) }
                            }
                            if !builtInDecks.contains(deck) { Button { editDeck = deck } label: { Image(systemName: "pencil") }.buttonStyle(.borderless) }
                        }
                    }
                }
            }.navigationTitle("단어장").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") } } }
                .sheet(isPresented: $adding) { NavigationStack { Form { TextField("단어장 이름", text: $newDeck) }.navigationTitle("나만의 단어장").toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { adding = false } }; ToolbarItem(placement: .confirmationAction) { Button("추가") { if store.addDeck(name: newDeck) { newDeck = ""; adding = false } } } } } }
                .alert("단어장 이름 변경", isPresented: Binding(get: { editDeck != nil }, set: { if !$0 { editDeck = nil } })) { TextField("새 이름", text: $newDeck); Button("취소", role: .cancel) { newDeck = "" }; Button("저장") { if let old = editDeck { _ = store.renameDeck(old, to: newDeck) }; newDeck = ""; editDeck = nil } } message: { Text("나만의 단어장 이름을 바꿉니다.") }
        }
    }
}

struct DeckDetailView: View {
    @EnvironmentObject private var store: LearningStore
    let deck: String
    @State private var adding = false
    @State private var english = ""
    @State private var meaning = ""
    var body: some View {
        List {
            Section { Text("\(store.words.filter { $0.deck == deck }.count)개 단어") }
            ForEach(store.words.filter { $0.deck == deck }.sorted { $0.english.localizedCaseInsensitiveCompare($1.english) == .orderedAscending }) { word in
                HStack { VStack(alignment: .leading, spacing: 4) { Text(word.english).font(.headline); Text(word.meaning).foregroundStyle(.secondary) }; Spacer(); if word.mastered { Image(systemName: "checkmark.seal.fill").foregroundStyle(.mint) } }
            }
        }.navigationTitle(deck).toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") } } }
            .sheet(isPresented: $adding) { NavigationStack { Form { TextField("영어 단어", text: $english); TextField("뜻", text: $meaning) }.navigationTitle("단어 추가").toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { adding = false } }; ToolbarItem(placement: .confirmationAction) { Button("추가") { if store.addWord(english: english, meaning: meaning, deck: deck) { english = ""; meaning = ""; adding = false } } } } } }
    }
}

struct QuizView: View {
    @EnvironmentObject private var store: LearningStore
    @Environment(\.dismiss) private var dismiss
    let daily: Bool
    @State private var queue: [VocabWord] = []
    @State private var index = 0
    @State private var correct = 0
    @State private var wrong = 0
    @State private var options: [String] = []
    @State private var feedback: String?
    @State private var typed = ""
    @State private var ended = false
    private var current: VocabWord? { index < queue.count ? queue[index] : nil }

    var body: some View {
        NavigationStack {
            Group {
                if ended { summary }
                else if let word = current { question(word) }
                else { ContentUnavailableView("문제가 없어요", systemImage: "text.magnifyingglass", description: Text("설정에서 출제할 단어장을 선택해 주세요.")) }
            }.padding(20).navigationTitle(daily ? "오늘의 Daily" : "퀴즈").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("마치기") { finish() } } }
                .onAppear(perform: prepare)
        }
        .interactiveDismissDisabled(false)
    }

    @ViewBuilder private func question(_ word: VocabWord) -> some View {
        VStack(spacing: 18) {
            HStack { Label("정답 \(correct) / \(store.questionCount)", systemImage: "checkmark.circle"); Spacer(); Label("오답 \(wrong)", systemImage: "xmark.circle").foregroundStyle(.secondary) }.font(.subheadline)
            ProgressView(value: Double(min(correct, store.questionCount)), total: Double(max(store.questionCount, 1))).tint(.mint)
            Spacer(minLength: 8)
            Text(word.deck).font(.subheadline).foregroundStyle(.mint)
            Text(store.spellingMode ? word.meaning : word.english).font(.system(size: 36, weight: .bold, design: .rounded)).multilineTextAlignment(.center).minimumScaleFactor(0.65)
            Spacer(minLength: 8)
            if store.spellingMode {
                TextField("영어 철자 입력", text: $typed).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).font(.title3)
                Button("확인") { answer(typed.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(word.english) == .orderedSame) }.buttonStyle(.borderedProminent).tint(.mint).disabled(feedback != nil)
            } else {
                ForEach(options, id: \.self) { option in
                    Button { answer(option == word.meaning) } label: { Text(option).frame(maxWidth: .infinity).padding(15).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15)) }.buttonStyle(.plain).disabled(feedback != nil)
                }
            }
            if let feedback { Text(feedback).font(.headline).foregroundStyle(feedback.hasPrefix("정답") ? .mint : .orange).multilineTextAlignment(.center) }
            HStack {
                Button("건너뛰기") { skip(word) }.buttonStyle(.bordered).disabled(feedback != nil)
                Spacer()
                if correct >= store.questionCount { Button("다 외웠음") { store.setMastered(word, true); next() }.buttonStyle(.bordered) }
                if feedback != nil { Button("다음") { next() }.buttonStyle(.borderedProminent).tint(.mint) }
                if correct >= store.questionCount { Button("마치기") { finish() }.buttonStyle(.bordered) }
            }
        }
    }

    private var summary: some View {
        VStack(spacing: 18) { Spacer(); Image(systemName: "checkmark.seal.fill").font(.system(size: 58)).foregroundStyle(.mint); Text("오늘 학습 완료").font(.largeTitle.bold()); Text("정답 \(correct)개 · 오답 \(wrong)개").font(.title3).foregroundStyle(.secondary); Spacer(); Button("홈으로") { dismiss() }.buttonStyle(.borderedProminent).tint(.mint).frame(maxWidth: .infinity) }.padding(.vertical, 30)
    }

    private func prepare() {
        guard queue.isEmpty else { return }
        let pool = store.words.filter { word in daily ? store.dailyWords.contains(word.id) : store.selectedDecks.contains(word.deck) }
        queue = pool.filter { !$0.mastered }.shuffled()
        buildOptions()
        if queue.isEmpty { ended = true }
    }
    private func buildOptions() {
        guard let word = current else { return }
        options = Array(Set([word.meaning] + store.words.filter { $0.id != word.id }.shuffled().prefix(3).map(\.meaning))).shuffled()
    }
    private func answer(_ isCorrect: Bool) {
        guard let word = current else { return }
        if isCorrect { correct += 1; feedback = "정답이에요! \(word.english) — \(word.meaning)" }
        else { wrong += 1; store.markAnswer(word: word, correct: false); feedback = "오답이에요. 정답: \(word.english) — \(word.meaning)" }
    }
    private func skip(_ word: VocabWord) { wrong += 1; store.markAnswer(word: word, correct: false, skipped: true); feedback = "건너뛰었어요. 정답: \(word.english) — \(word.meaning)" }
    private func next() { index += 1; feedback = nil; typed = ""; if index >= queue.count { finish() } else { buildOptions() } }
    private func finish() {
        guard !ended else { dismiss(); return }
        if correct + wrong > 0 { store.sessions.insert(StudySession(correct: correct, wrong: wrong), at: 0) }
        ended = true
    }
}

struct WrongView: View {
    @EnvironmentObject private var store: LearningStore
    @State private var showQuiz = false
    var body: some View {
        NavigationStack {
            Group {
                if store.wrongWords.isEmpty { ContentUnavailableView("오답이 없어요", systemImage: "checkmark.circle", description: Text("퀴즈에서 틀리거나 건너뛴 단어가 여기에 모입니다.")) }
                else { List(store.wrongWords) { word in HStack { VStack(alignment: .leading, spacing: 4) { Text(word.english).font(.headline); Text(word.meaning).foregroundStyle(.secondary) }; Spacer(); Text("오답 \(word.wrongCount) · 건너뜀 \(word.skippedCount)").font(.caption).foregroundStyle(.secondary) } } }
            }.navigationTitle("오답 노트").toolbar { if !store.wrongWords.isEmpty { ToolbarItem(placement: .topBarTrailing) { Button("오답 테스트") { showQuiz = true } } } }
                .fullScreenCover(isPresented: $showQuiz) { WrongQuizView().environmentObject(store) }
        }
    }
}

private struct WrongQuizView: View {
    @EnvironmentObject private var store: LearningStore
    @Environment(\.dismiss) private var dismiss
    @State private var current: VocabWord?
    @State private var choices: [String] = []
    @State private var message: String?
    @State private var done = false
    @State private var correct = 0
    private var pending: [VocabWord] { store.wrongWords.filter { !$0.mastered } }
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if done { Spacer(); Text("오답 복습 완료").font(.largeTitle.bold()); Text("정답 \(correct)개"); Spacer(); Button("닫기") { dismiss() }.buttonStyle(.borderedProminent) }
                else if let word = current {
                    Text("오답 테스트 · 제한 없이 풀기").font(.headline).foregroundStyle(.secondary)
                    Text(word.english).font(.largeTitle.bold()).padding(.vertical, 26)
                    ForEach(choices, id: \.self) { item in Button(item) { if item == word.meaning { correct += 1; message = "정답이에요"; store.setMastered(word, true) } else { message = "뜻을 다시 확인해 보세요" } }.frame(maxWidth: .infinity).padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14)).disabled(message == "정답이에요") }
                    if let message { Text(message).foregroundStyle(message == "정답이에요" ? .mint : .orange) }
                    Button("다음") { advance() }.buttonStyle(.borderedProminent).disabled(message != "정답이에요")
                    Spacer()
                } else { ContentUnavailableView("복습할 오답이 없어요", systemImage: "checkmark.seal"); Button("닫기") { dismiss() } }
            }.padding(20).navigationTitle("오답 테스트").toolbar { ToolbarItem(placement: .topBarLeading) { Button("나가기") { dismiss() } } }.onAppear(perform: advance)
        }
    }
    private func advance() {
        message = nil
        guard let next = pending.randomElement() else { done = true; current = nil; return }
        current = next
        choices = Array(Set([next.meaning] + store.words.filter { $0.id != next.id }.shuffled().prefix(3).map(\.meaning))).shuffled()
    }
}

struct HistoryView: View {
    @EnvironmentObject private var store: LearningStore
    var body: some View {
        NavigationStack { List { if store.sessions.isEmpty { ContentUnavailableView("학습 기록이 아직 없어요", systemImage: "chart.bar", description: Text("퀴즈를 풀면 기록이 여기에 저장됩니다.")) } else { ForEach(store.sessions) { item in HStack { VStack(alignment: .leading) { Text(item.date.formatted(date: .abbreviated, time: .shortened)); Text("정답 \(item.correct) · 오답 \(item.wrong)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("\(item.correct + item.wrong)문제").font(.subheadline.bold()) } } } }.navigationTitle("학습 기록") }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LearningStore
    var body: some View {
        NavigationStack {
            Form {
                Section("출제 설정") {
                    ForEach(store.deckNames, id: \.self) { deck in Toggle(deck, isOn: Binding(get: { store.selectedDecks.contains(deck) }, set: { value in if value { store.selectedDecks.insert(deck) } else { store.selectedDecks.remove(deck) } })) }
                    Stepper("문제 수 · \(store.questionCount)", value: $store.questionCount, in: 3...100)
                    Toggle("철자 맞히기", isOn: $store.spellingMode)
                }
                Section("화면") { Toggle("다크 모드", isOn: $store.darkMode) }
                Section("앱 잠금") { Label("iPhone은 앱 실행/사용을 강제로 막을 수 없습니다.", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                Section { Text("학습 자료는 이 iPhone 안에 저장됩니다. 앱을 삭제하면 백업되지 않은 기록은 함께 삭제될 수 있습니다.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("설정")
        }
    }
}

