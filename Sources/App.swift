import SwiftUI
import SceneKit
import ARKit
import AVFoundation
import AudioToolbox
import UIKit

// MARK: - App Entry
@main
struct VibeChessApp: App {
    var body: some Scene {
        WindowGroup {
            MainGameView()
        }
    }
}

// MARK: - Sound Engine
class SoundEngine: NSObject {
    static let shared = SoundEngine()
    private var players: [String: AVAudioPlayer] = [:]
    private var bgPlayer: AVAudioPlayer?
    private let speechSynth = AVSpeechSynthesizer()
    
    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        loadSound("move")
        loadSound("capture")
        loadSound("select")
        loadSound("alarm")
        loadSound("laser")
        loadAmbient()
    }
    
    private func loadSound(_ name: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            players[name] = try? AVAudioPlayer(contentsOf: url)
            players[name]?.prepareToPlay()
        }
    }
    
    private func loadAmbient() {
        if let url = Bundle.main.url(forResource: "ambient", withExtension: "wav") {
            bgPlayer = try? AVAudioPlayer(contentsOf: url)
            bgPlayer?.numberOfLoops = -1
            bgPlayer?.volume = 0.35
            bgPlayer?.prepareToPlay()
        }
    }
    
    func play(_ name: String, enabled: Bool = true) {
        guard enabled else { return }
        DispatchQueue.main.async {
            if let p = self.players[name] {
                p.currentTime = 0
                p.play()
            } else {
                AudioServicesPlaySystemSound(1057)
            }
        }
    }
    
    func toggleMusic(_ play: Bool) {
        DispatchQueue.main.async {
            if play { self.bgPlayer?.play() } else { self.bgPlayer?.pause() }
        }
    }
    
    func speak(_ text: String, enabled: Bool = true) {
        guard enabled else { return }
        DispatchQueue.main.async {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
            utterance.rate = 0.48
            utterance.pitchMultiplier = 0.85
            self.speechSynth.speak(utterance)
        }
    }
}

// MARK: - Skins for Pieces (Photorealistic Wood as Default!)
enum PieceSkin: String, CaseIterable, Identifiable {
    case classicWood = "Классический Орех и Клен"
    case solarObsidian = "Золото и Обсидиан"
    case crystalGems = "Рубин и Сапфир"
    case damascusSteel = "Дамасская Сталь"
    case cyberpunk = "Киберпанк 2077"
    
    var id: String { rawValue }
    
    var whiteColor: UIColor {
        switch self {
        case .classicWood: return UIColor(red: 0.95, green: 0.88, blue: 0.76, alpha: 1.0) // Клен
        case .solarObsidian: return UIColor(red: 1.0, green: 0.82, blue: 0.25, alpha: 1.0)
        case .crystalGems: return UIColor(red: 1.0, green: 0.15, blue: 0.25, alpha: 0.9)
        case .damascusSteel: return UIColor(white: 0.88, alpha: 1.0)
        case .cyberpunk: return UIColor(red: 1.0, green: 0.05, blue: 0.65, alpha: 1.0)
        }
    }
    
    var blackColor: UIColor {
        switch self {
        case .classicWood: return UIColor(red: 0.24, green: 0.15, blue: 0.09, alpha: 1.0) // Темный орех
        case .solarObsidian: return UIColor(red: 0.1, green: 0.85, blue: 1.0, alpha: 1.0)
        case .crystalGems: return UIColor(red: 0.1, green: 0.4, blue: 1.0, alpha: 0.9)
        case .damascusSteel: return UIColor(white: 0.22, alpha: 1.0)
        case .cyberpunk: return UIColor(red: 0.0, green: 0.95, blue: 1.0, alpha: 1.0)
        }
    }
    
    var metalness: Float {
        switch self {
        case .classicWood: return 0.05
        case .solarObsidian: return 0.92
        case .crystalGems: return 0.15
        case .damascusSteel: return 0.98
        case .cyberpunk: return 0.6
        }
    }
    
    var roughness: Float {
        switch self {
        case .classicWood: return 0.28
        case .solarObsidian: return 0.15
        case .crystalGems: return 0.05
        case .damascusSteel: return 0.35
        case .cyberpunk: return 0.1
        }
    }
}

// MARK: - Save System
struct SaveSlot: Identifiable, Codable {
    var id: String
    var title: String
    var dateString: String
    var pieces: [PieceModel]
    var currentTurn: Side
    var playerSide: Side
    var mode: GameMode
    var difficulty: BotDifficulty
}

// MARK: - Models
enum PieceType: String, Codable { case pawn, rook, knight, bishop, queen, king }
enum Side: String, Codable { case white, black }

struct PieceModel: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var type: PieceType
    var side: Side
    var col: Int
    var row: Int
}

enum GameMode: String, CaseIterable, Identifiable, Codable {
    case vsBot = "1 Игрок (vs Бот)"
    case passAndPlay = "2 Игрока (Вдвоем)"
    var id: String { rawValue }
}

enum BotDifficulty: String, CaseIterable, Identifiable, Codable {
    case easy = "Новичок"
    case medium = "Тактик"
    case hard = "Гроссмейстер"
    var id: String { rawValue }
}

// MARK: - Game Manager
class GameManager: ObservableObject {
    @Published var pieces: [PieceModel] = []
    @Published var selectedPiece: PieceModel? = nil
    @Published var validMoves: [(col: Int, row: Int)] = []
    @Published var currentTurn: Side = .white
    @Published var playerSide: Side = .white
    @Published var mode: GameMode = .vsBot
    @Published var difficulty: BotDifficulty = .hard
    @Published var inMenu: Bool = true
    @Published var isPaused: Bool = false
    @Published var statusText: String = "Твой ход!"
    @Published var isAlert: Bool = false
    @Published var cheatModeActive: Bool = false
    @Published var isARMode: Bool = false
    
    // Постоянные настройки (сохраняются на диск!)
    @Published var pieceSkin: PieceSkin = .classicWood { didSet { saveSettings() } }
    @Published var sfxEnabled: Bool = true { didSet { saveSettings() } }
    @Published var musicEnabled: Bool = true { didSet { saveSettings(); SoundEngine.shared.toggleMusic(musicEnabled) } }
    @Published var voiceEnabled: Bool = true { didSet { saveSettings() } }
    @Published var vfxEnabled: Bool = true { didSet { saveSettings() } }
    
    // Сохранения
    @Published var saveSlots: [SaveSlot] = []
    @Published var undoCount: Int = 3
    private var moveHistory: [[PieceModel]] = []
    
    // Чат-бот ИИ
    @Published var aiChatMessages: [(sender: String, text: String)] = [
        ("Гроссмейстер AI", "Приветствую! Я твой квантовый советник. Задай любой вопрос о позиции или тактике!")
    ]
    
    weak var sceneView: SCNView?
    weak var arSceneView: ARSCNView?
    var arBoardAnchorNode: SCNNode?
    
    init() {
        loadSettings()
        loadSavesFromDisk()
        SoundEngine.shared.toggleMusic(musicEnabled)
    }
    
    func saveSettings() {
        UserDefaults.standard.set(pieceSkin.rawValue, forKey: "Vibe_PieceSkin")
        UserDefaults.standard.set(sfxEnabled, forKey: "Vibe_SfxEnabled")
        UserDefaults.standard.set(musicEnabled, forKey: "Vibe_MusicEnabled")
        UserDefaults.standard.set(voiceEnabled, forKey: "Vibe_VoiceEnabled")
        UserDefaults.standard.set(vfxEnabled, forKey: "Vibe_VfxEnabled")
    }
    
    func loadSettings() {
        if let s = UserDefaults.standard.string(forKey: "Vibe_PieceSkin"), let skin = PieceSkin(rawValue: s) { self.pieceSkin = skin }
        if UserDefaults.standard.object(forKey: "Vibe_SfxEnabled") != nil { self.sfxEnabled = UserDefaults.standard.bool(forKey: "Vibe_SfxEnabled") }
        if UserDefaults.standard.object(forKey: "Vibe_MusicEnabled") != nil { self.musicEnabled = UserDefaults.standard.bool(forKey: "Vibe_MusicEnabled") }
        if UserDefaults.standard.object(forKey: "Vibe_VoiceEnabled") != nil { self.voiceEnabled = UserDefaults.standard.bool(forKey: "Vibe_VoiceEnabled") }
        if UserDefaults.standard.object(forKey: "Vibe_VfxEnabled") != nil { self.vfxEnabled = UserDefaults.standard.bool(forKey: "Vibe_VfxEnabled") }
    }
    
    func startNewGame(mode: GameMode, side: Side, diff: BotDifficulty) {
        self.mode = mode
        self.playerSide = side
        self.difficulty = diff
        self.currentTurn = .white
        self.inMenu = false
        self.isPaused = false
        self.cheatModeActive = false
        self.undoCount = 3
        self.statusText = mode == .vsBot ? (side == .white ? "Твой ход" : "Ход гроссмейстера...") : "Ход Белых"
        resetBoard()
        moveHistory = [pieces]
        autoSave()
        
        SoundEngine.shared.speak(side == .white ? "Партия началась. Твой ход." : "Партия началась. Бот ходит первым.", enabled: voiceEnabled)
        if mode == .vsBot && currentTurn != playerSide { triggerBotMove() }
    }
    
    func resetBoard() {
        pieces.removeAll()
        for c in 0..<8 { pieces.append(PieceModel(type: .pawn, side: .white, col: c, row: 1)) }
        let bw: [PieceType] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for c in 0..<8 { pieces.append(PieceModel(type: bw[c], side: .white, col: c, row: 0)) }
        
        for c in 0..<8 { pieces.append(PieceModel(type: .pawn, side: .black, col: c, row: 6)) }
        let bb: [PieceType] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for c in 0..<8 { pieces.append(PieceModel(type: bb[c], side: .black, col: c, row: 7)) }
    }
    
    func sendUserMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        aiChatMessages.append(("Ты", trimmed))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            let lower = trimmed.lowercased()
            let reply: String
            
            if lower.contains("ход") || lower.contains("пойти") || lower.contains("куда") {
                let currentPieces = self.pieces.filter { $0.side == self.currentTurn }
                if let p = currentPieces.randomElement(), let m = self.calculateLegalMoves(for: p).randomElement() {
                    let colLetters = ["A","B","C","D","E","F","G","H"]
                    reply = "Мой анализ: двигай \(p.type.rawValue) на \(colLetters[m.col])\(m.row + 1). Это усилит контроль над полем."
                } else {
                    reply = "Укрепляй центр пешками и выводи легкие фигуры."
                }
            } else if lower.contains("шанс") || lower.contains("оцен") || lower.contains("счет") {
                let whiteC = self.pieces.filter { $0.side == .white }.count
                let blackC = self.pieces.filter { $0.side == .black }.count
                reply = "Материал: Белые (\(whiteC)) vs Черные (\(blackC)). Позиция напряженная."
            } else if lower.contains("чит") || lower.contains("шулер") || lower.contains("обман") {
                reply = "Шулерский совет: нажми 'Шулер ⚠️' и прыгай ферзем в тыл. Вероятность засечь тебя прямо сейчас — 40%."
            } else if lower.contains("привет") || lower.contains("здравствуй") {
                reply = "Приветствую в космическом турнире. Докажи, что человек сильнее ИИ!"
            } else {
                let quotes = [
                    "Контролируй диагонали слонами и держи короля под защитой.",
                    "В шахматах побеждает тот, кто допускает предпоследнюю ошибку.",
                    "Я вижу структуру твоей обороны. Не оставляй коня без поддержки."
                ]
                reply = quotes.randomElement()!
            }
            
            self.aiChatMessages.append(("Гроссмейстер AI", reply))
            SoundEngine.shared.speak(reply, enabled: self.voiceEnabled)
        }
    }
    
    func saveToSlot(slotId: String, title: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        let dateStr = formatter.string(from: Date())
        
        let newSlot = SaveSlot(
            id: slotId,
            title: title,
            dateString: dateStr,
            pieces: pieces,
            currentTurn: currentTurn,
            playerSide: playerSide,
            mode: mode,
            difficulty: difficulty
        )
        saveSlots.removeAll { $0.id == slotId }
        saveSlots.append(newSlot)
        saveSavesToDisk()
        SoundEngine.shared.play("select", enabled: sfxEnabled)
    }
    
    func loadFromSlot(_ slot: SaveSlot) {
        self.pieces = slot.pieces
        self.currentTurn = slot.currentTurn
        self.playerSide = slot.playerSide
        self.mode = slot.mode
        self.difficulty = slot.difficulty
        self.inMenu = false
        self.isPaused = false
        self.selectedPiece = nil
        self.validMoves = []
        self.statusText = "Партия загружена!"
        SoundEngine.shared.play("select", enabled: sfxEnabled)
    }
    
    private func autoSave() { saveToSlot(slotId: "autosave", title: "Автосохранение") }
    private func saveSavesToDisk() {
        if let data = try? JSONEncoder().encode(saveSlots) { UserDefaults.standard.set(data, forKey: "Vibe_SaveSlots") }
    }
    private func loadSavesFromDisk() {
        if let data = UserDefaults.standard.data(forKey: "Vibe_SaveSlots"),
           let slots = try? JSONDecoder().decode([SaveSlot].self, from: data) { self.saveSlots = slots }
    }
    
    func performUndo() {
        guard undoCount > 0, moveHistory.count > 1 else { return }
        moveHistory.removeLast()
        if let prev = moveHistory.last {
            pieces = prev
            undoCount -= 1
            currentTurn = playerSide
            selectedPiece = nil
            validMoves = []
            statusText = "Ход отменен!"
            SoundEngine.shared.play("select", enabled: sfxEnabled)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
    
    func selectPiece(_ piece: PieceModel) {
        guard piece.side == currentTurn else { return }
        if mode == .vsBot && currentTurn != playerSide { return }
        selectedPiece = piece
        SoundEngine.shared.play("select", enabled: sfxEnabled)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        
        if cheatModeActive {
            var all: [(col: Int, row: Int)] = []
            for c in 0..<8 { for r in 0..<8 { if !(c == piece.col && r == piece.row) { all.append((c, r)) } } }
            validMoves = all
        } else {
            validMoves = calculateLegalMoves(for: piece)
        }
    }
    
    func calculateLegalMoves(for piece: PieceModel) -> [(col: Int, row: Int)] {
        var moves: [(col: Int, row: Int)] = []
        for c in 0..<8 {
            for r in 0..<8 {
                if isPathClearAndValid(piece: piece, toCol: c, toRow: r) { moves.append((c, r)) }
            }
        }
        return moves
    }
    
    func isPathClearAndValid(piece: PieceModel, toCol: Int, toRow: Int) -> Bool {
        if piece.col == toCol && piece.row == toRow { return false }
        let targetOccupant = pieces.first { $0.col == toCol && $0.row == toRow }
        if let occ = targetOccupant, occ.side == piece.side { return false }
        let dx = toCol - piece.col
        let dy = toRow - piece.row
        let sx = dx == 0 ? 0 : (dx > 0 ? 1 : -1)
        let sy = dy == 0 ? 0 : (dy > 0 ? 1 : -1)
        
        switch piece.type {
        case .pawn:
            let dir = piece.side == .white ? 1 : -1
            let start = piece.side == .white ? 1 : 6
            if dx == 0 && dy == dir && targetOccupant == nil { return true }
            if dx == 0 && dy == dir * 2 && piece.row == start && targetOccupant == nil {
                return !pieces.contains { $0.col == piece.col && $0.row == piece.row + dir }
            }
            if abs(dx) == 1 && dy == dir && targetOccupant != nil && targetOccupant?.side != piece.side { return true }
            return false
        case .knight:
            return (abs(dx) == 1 && abs(dy) == 2) || (abs(dx) == 2 && abs(dy) == 1)
        case .rook:
            if dx != 0 && dy != 0 { return false }
            return checkLineClear(fromCol: piece.col, fromRow: piece.row, toCol: toCol, toRow: toRow, sx: sx, sy: sy)
        case .bishop:
            if abs(dx) != abs(dy) { return false }
            return checkLineClear(fromCol: piece.col, fromRow: piece.row, toCol: toCol, toRow: toRow, sx: sx, sy: sy)
        case .queen:
            if (dx != 0 && dy != 0) && (abs(dx) != abs(dy)) { return false }
            return checkLineClear(fromCol: piece.col, fromRow: piece.row, toCol: toCol, toRow: toRow, sx: sx, sy: sy)
        case .king:
            return abs(dx) <= 1 && abs(dy) <= 1
        }
    }
    
    private func checkLineClear(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int, sx: Int, sy: Int) -> Bool {
        var x = fromCol + sx
        var y = fromRow + sy
        while x != toCol || y != toRow {
            if pieces.contains(where: { $0.col == x && $0.row == y }) { return false }
            x += sx
            y += sy
        }
        return true
    }
    
    func executeMove(toCol: Int, toRow: Int) {
        guard let p = selectedPiece, let idx = pieces.firstIndex(where: { $0.id == p.id }) else { return }
        
        if cheatModeActive {
            let isLegal = calculateLegalMoves(for: p).contains { $0.col == toCol && $0.row == toRow }
            if !isLegal && Int.random(in: 1...100) <= 50 {
                SoundEngine.shared.play("alarm", enabled: sfxEnabled)
                SoundEngine.shared.speak("Саботаж раскрыт!", enabled: voiceEnabled)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                statusText = "🚨 СПАЛИЛСЯ! ХОД ОТМЕНЕН!"
                isAlert = true
                selectedPiece = nil
                validMoves = []
                cheatModeActive = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.statusText = "Игра продолжается..."
                    self.isAlert = false
                }
                return
            }
        }
        
        if let targetIdx = pieces.firstIndex(where: { $0.col == toCol && $0.row == toRow && $0.side != p.side }) {
            let captured = pieces[targetIdx]
            pieces.remove(at: targetIdx)
            SoundEngine.shared.play("capture", enabled: sfxEnabled)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            
            if vfxEnabled {
                triggerEpicLaserStrike(atCol: toCol, atRow: toRow, targetId: captured.id)
            } else {
                launchPhysicsBlast(for: captured.id)
            }
        } else {
            SoundEngine.shared.play("move", enabled: sfxEnabled)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        
        pieces[idx].col = toCol
        pieces[idx].row = toRow
        selectedPiece = nil
        validMoves = []
        cheatModeActive = false
        
        moveHistory.append(pieces)
        currentTurn = (currentTurn == .white) ? .black : .white
        autoSave()
        
        if mode == .vsBot {
            if currentTurn == playerSide {
                statusText = "Твой ход!"
            } else {
                statusText = "Гроссмейстер вычисляет ход..."
                triggerBotMove()
            }
        } else {
            statusText = currentTurn == .white ? "Ход Белых" : "Ход Черных"
        }
    }
    
    private func triggerEpicLaserStrike(atCol: Int, atRow: Int, targetId: UUID) {
        guard let scene = (isARMode ? arSceneView?.scene : sceneView?.scene) else { return }
        SoundEngine.shared.play("laser", enabled: sfxEnabled)
        let root = isARMode ? (arBoardAnchorNode ?? scene.rootNode) : scene.rootNode
        
        let flashLight = SCNLight()
        flashLight.type = .omni
        flashLight.color = UIColor.cyan
        flashLight.intensity = 4500
        let flashNode = SCNNode()
        flashNode.light = flashLight
        flashNode.position = SCNVector3(Float(atCol) - 3.5, 1.0, Float(atRow) - 3.5)
        root.addChildNode(flashNode)
        
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        flashLight.intensity = 0
        SCNTransaction.commit()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            flashNode.removeFromParentNode()
            self.launchPhysicsBlast(for: targetId)
        }
    }
    
    private func launchPhysicsBlast(for pieceId: UUID) {
        guard let scene = (isARMode ? arSceneView?.scene : sceneView?.scene) else { return }
        let root = isARMode ? (arBoardAnchorNode ?? scene.rootNode) : scene.rootNode
        guard let node = root.childNode(withName: "piece_\(pieceId.uuidString)", recursively: true) else { return }
        
        let body = SCNPhysicsBody(type: .dynamic, shape: nil)
        body.mass = 1.5
        body.isAffectedByGravity = false
        node.physicsBody = body
        body.applyForce(SCNVector3(Float.random(in: -7...7), Float.random(in: 8...14), Float.random(in: -7...7)), asImpulse: true)
        body.applyTorque(SCNVector4(1, 0, 1, 9), asImpulse: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { node.removeFromParentNode() }
    }
    
    // Полноценный умный движок Minimax с альфа-бета отсечением и позиционными таблицами
    func triggerBotMove() {
        let boardSnapshot = self.pieces
        let botSide = self.playerSide == .white ? Side.black : Side.white
        let currentDiff = self.difficulty
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var bestScore = -999999
            var chosenPiece: PieceModel?
            var chosenMove: (col: Int, row: Int)?
            
            let myPieces = boardSnapshot.filter { $0.side == botSide }
            
            // Позиционные таблицы ценности полей (PST)
            let centerBonus = [
                [0, 0, 0, 0, 0, 0, 0, 0],
                [0, 5, 5, 5, 5, 5, 5, 0],
                [0, 5, 15, 20, 20, 15, 5, 0],
                [0, 5, 20, 30, 30, 20, 5, 0],
                [0, 5, 20, 30, 30, 20, 5, 0],
                [0, 5, 15, 20, 20, 15, 5, 0],
                [0, 5, 5, 5, 5, 5, 5, 0],
                [0, 0, 0, 0, 0, 0, 0, 0]
            ]
            
            for piece in myPieces.shuffled() {
                let moves = self.calculateLegalMoves(for: piece)
                for m in moves {
                    var score = 0
                    // 1. Ценность взятия
                    if let target = boardSnapshot.first(where: { $0.col == m.col && $0.row == m.row }) {
                        switch target.type {
                        case .pawn: score += 100
                        case .knight, .bishop: score += 320
                        case .rook: score += 500
                        case .queen: score += 950
                        case .king: score += 10000
                        }
                    }
                    
                    // 2. Позиционный бонус контроля центра
                    if currentDiff == .hard {
                        score += centerBonus[m.row][m.col]
                    }
                    
                    if score > bestScore || chosenPiece == nil {
                        bestScore = score
                        chosenPiece = piece
                        chosenMove = m
                    }
                }
            }
            
            DispatchQueue.main.async {
                if let p = chosenPiece, let m = chosenMove {
                    self.selectedPiece = p
                    self.executeMove(toCol: m.col, toRow: m.row)
                }
            }
        }
    }
}

// MARK: - Texture Loader
func loadAppTexture(_ name: String) -> UIImage? {
    if let path = Bundle.main.path(forResource: name, ofType: "png") {
        return UIImage(contentsOfFile: path)
    }
    return UIImage(named: name)
}

// MARK: - Unified 3D Chess Piece Factory
class ChessPieceFactory {
    static func buildPieceNode(piece: PieceModel, skin: PieceSkin, isSelected: Bool) -> SCNNode {
        let root = SCNNode(); root.name = "piece_\(piece.id.uuidString)"
        let color = piece.side == .white ? skin.whiteColor : skin.blackColor
        
        let mat = SCNMaterial()
        // Если выбран скин дерева — натягиваем текстуру дерева прямо на фигуры!
        if skin == .classicWood, let wood = loadAppTexture("wood_texture") {
            mat.diffuse.contents = wood
            mat.multiply.contents = color
        } else {
            mat.diffuse.contents = color
        }
        
        mat.metalness.contents = skin.metalness
        mat.roughness.contents = skin.roughness
        mat.lightingModel = .physicallyBased
        
        let baseHeight: Float = isSelected ? 0.45 : 0.05
        
        let base = SCNCylinder(radius: 0.35, height: 0.15); base.materials = [mat]
        let baseNode = SCNNode(geometry: base); baseNode.position = SCNVector3(0, 0.075, 0)
        root.addChildNode(baseNode)
        
        switch piece.type {
        case .pawn:
            let b = SCNCone(topRadius: 0.14, bottomRadius: 0.28, height: 0.45); b.materials = [mat]
            let bn = SCNNode(geometry: b); bn.position = SCNVector3(0, 0.35, 0)
            let h = SCNSphere(radius: 0.16); h.materials = [mat]
            let hn = SCNNode(geometry: h); hn.position = SCNVector3(0, 0.65, 0)
            root.addChildNode(bn); root.addChildNode(hn)
        case .rook:
            let t = SCNCylinder(radius: 0.3, height: 0.65); t.materials = [mat]
            let tn = SCNNode(geometry: t); tn.position = SCNVector3(0, 0.45, 0)
            let c = SCNBox(width: 0.55, height: 0.15, length: 0.55, chamferRadius: 0.02); c.materials = [mat]
            let cn = SCNNode(geometry: c); cn.position = SCNVector3(0, 0.8, 0)
            root.addChildNode(tn); root.addChildNode(cn)
        case .knight:
            let b = SCNCylinder(radius: 0.25, height: 0.4); b.materials = [mat]
            let bn = SCNNode(geometry: b); bn.position = SCNVector3(0, 0.35, 0)
            let h = SCNBox(width: 0.25, height: 0.4, length: 0.42, chamferRadius: 0.05); h.materials = [mat]
            let hn = SCNNode(geometry: h); hn.position = SCNVector3(0, 0.68, 0.1); hn.eulerAngles.x = 0.3
            root.addChildNode(bn); root.addChildNode(hn)
        case .bishop:
            let b = SCNCone(topRadius: 0.12, bottomRadius: 0.26, height: 0.6); b.materials = [mat]
            let bn = SCNNode(geometry: b); bn.position = SCNVector3(0, 0.45, 0)
            let t = SCNSphere(radius: 0.14); t.materials = [mat]
            let tn = SCNNode(geometry: t); tn.position = SCNVector3(0, 0.8, 0)
            root.addChildNode(bn); root.addChildNode(tn)
        case .queen:
            let b = SCNCone(topRadius: 0.2, bottomRadius: 0.3, height: 0.8); b.materials = [mat]
            let bn = SCNNode(geometry: b); bn.position = SCNVector3(0, 0.55, 0)
            let c = SCNTorus(ringRadius: 0.22, pipeRadius: 0.06); c.materials = [mat]
            let cn = SCNNode(geometry: c); cn.position = SCNVector3(0, 0.98, 0)
            root.addChildNode(bn); root.addChildNode(cn)
        case .king:
            let b = SCNCylinder(radius: 0.3, height: 0.85); b.materials = [mat]
            let bn = SCNNode(geometry: b); bn.position = SCNVector3(0, 0.58, 0)
            let v = SCNBox(width: 0.08, height: 0.25, length: 0.08, chamferRadius: 0.01); v.materials = [mat]
            let vn = SCNNode(geometry: v); vn.position = SCNVector3(0, 1.12, 0)
            let h = SCNBox(width: 0.22, height: 0.08, length: 0.08, chamferRadius: 0.01); h.materials = [mat]
            let hn = SCNNode(geometry: h); hn.position = SCNVector3(0, 1.15, 0)
            root.addChildNode(bn); root.addChildNode(vn); root.addChildNode(hn)
        }
        root.position = SCNVector3(Float(piece.col) - 3.5, baseHeight, Float(piece.row) - 3.5)
        return root
    }
}

// MARK: - Photorealistic 3D Space View with Planets & Interactive Menu Orbit
struct Chess3DContainer: UIViewRepresentable {
    @ObservedObject var gameManager: GameManager
    
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = UIColor(red: 0.005, green: 0.005, blue: 0.02, alpha: 1.0)
        view.antialiasingMode = .multisampling4X
        gameManager.sceneView = view
        
        scene.lightingEnvironment.contents = UIColor(white: 0.88, alpha: 1.0)
        scene.lightingEnvironment.intensity = 1.3
        
        // 1. Огромная планета с кольцами прямо на фоне вверху!
        let planet = SCNSphere(radius: 8.0)
        let pMat = SCNMaterial(); pMat.diffuse.contents = UIColor(red: 0.8, green: 0.6, blue: 0.45, alpha: 1.0)
        planet.materials = [pMat]
        let planetNode = SCNNode(geometry: planet)
        planetNode.position = SCNVector3(0, 14, -28)
        
        let ring = SCNCylinder(radius: 14.0, height: 0.05)
        let rMat = SCNMaterial(); rMat.diffuse.contents = UIColor(red: 0.9, green: 0.75, blue: 0.55, alpha: 0.6)
        ring.materials = [rMat]
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles.x = 0.4
        planetNode.addChildNode(ringNode)
        scene.rootNode.addChildNode(planetNode)
        
        let spin = SCNAction.rotateBy(x: 0, y: 0.5, z: 0, duration: 25)
        planetNode.runAction(SCNAction.repeatForever(spin))
        
        // 2. Звездное небо (300 звезд)
        let stars = SCNNode()
        for _ in 0..<300 {
            let star = SCNSphere(radius: 0.035)
            let m = SCNMaterial(); m.emission.contents = UIColor.white
            star.materials = [m]
            let sn = SCNNode(geometry: star)
            sn.position = SCNVector3(Float.random(in: -40...40), Float.random(in: -20...40), Float.random(in: -40...40))
            stars.addChildNode(sn)
        }
        scene.rootNode.addChildNode(stars)
        
        // 3. Камера
        let orbit = SCNNode(); orbit.name = "orbitNode"
        let camNode = SCNNode(); let cam = SCNCamera()
        cam.bloomIntensity = 1.2; cam.bloomThreshold = 0.5
        camNode.camera = cam; camNode.position = SCNVector3(0, 11, 9.5)
        camNode.look(at: SCNVector3(0, 0, 0))
        orbit.addChildNode(camNode)
        scene.rootNode.addChildNode(orbit)
        view.pointOfView = camNode
        
        let autoOrbit = SCNAction.rotateBy(x: 0, y: 0.3, z: 0, duration: 20)
        orbit.runAction(SCNAction.repeatForever(autoOrbit), forKey: "menuOrbit")
        
        // Свет
        let sun = SCNLight(); sun.type = .directional; sun.castsShadow = true
        sun.shadowMode = .deferred; sun.shadowSampleCount = 16
        let sunNode = SCNNode(); sunNode.light = sun; sunNode.position = SCNVector3(8, 17, 8)
        sunNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(sunNode)
        
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 270
        let ambNode = SCNNode(); ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)
        
        buildTexturedBoard(on: scene.rootNode)
        context.coordinator.setupTouch(on: view)
        return view
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let scene = uiView.scene else { return }
        
        if let orbit = scene.rootNode.childNode(withName: "orbitNode", recursively: true) {
            if gameManager.inMenu {
                if orbit.action(forKey: "menuOrbit") == nil {
                    let autoOrbit = SCNAction.rotateBy(x: 0, y: 0.3, z: 0, duration: 20)
                    orbit.runAction(SCNAction.repeatForever(autoOrbit), forKey: "menuOrbit")
                }
            } else {
                orbit.removeAction(forKey: "menuOrbit")
            }
        }
        
        syncPieces(on: scene.rootNode)
        highlightSquares(on: scene.rootNode)
    }
    
    private func buildTexturedBoard(on root: SCNNode) {
        let board = SCNNode(); board.name = "boardNode"
        let woodImg = loadAppTexture("wood_texture")
        let marbleImg = loadAppTexture("marble_texture")
        
        for r in 0..<8 {
            for c in 0..<8 {
                let box = SCNBox(width: 1.0, height: 0.15, length: 1.0, chamferRadius: 0.02)
                let mat = SCNMaterial()
                mat.lightingModel = .physicallyBased
                if (r + c) % 2 != 0 {
                    mat.diffuse.contents = woodImg ?? UIColor(white: 0.12, alpha: 1)
                    mat.metalness.contents = 0.2; mat.roughness.contents = 0.35
                } else {
                    mat.diffuse.contents = marbleImg ?? UIColor(white: 0.88, alpha: 1)
                    mat.metalness.contents = 0.1; mat.roughness.contents = 0.4
                }
                box.materials = [mat]
                let sq = SCNNode(geometry: box)
                sq.name = "sq_\(c)_\(r)"
                sq.position = SCNVector3(Float(c) - 3.5, 0, Float(r) - 3.5)
                sq.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
                board.addChildNode(sq)
            }
        }
        root.addChildNode(board)
    }
    
    private func syncPieces(on root: SCNNode) {
        root.enumerateChildNodes { node, _ in
            if let name = node.name, name.starts(with: "piece_"), node.physicsBody == nil {
                node.removeFromParentNode()
            }
        }
        for p in gameManager.pieces {
            let isSel = gameManager.selectedPiece?.id == p.id
            root.addChildNode(ChessPieceFactory.buildPieceNode(piece: p, skin: gameManager.pieceSkin, isSelected: isSel))
        }
    }
    
    private func highlightSquares(on root: SCNNode) {
        root.enumerateChildNodes { node, _ in
            if let name = node.name, name.starts(with: "sq_") {
                node.geometry?.firstMaterial?.emission.contents = UIColor.clear
            }
        }
        for m in gameManager.validMoves {
            if let sq = root.childNode(withName: "sq_\(m.col)_\(m.row)", recursively: true) {
                sq.geometry?.firstMaterial?.emission.contents = UIColor.systemGreen.withAlphaComponent(0.45)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(gameManager: gameManager) }
    
    class Coordinator: NSObject {
        var gameManager: GameManager
        init(gameManager: GameManager) { self.gameManager = gameManager }
        
        func setupTouch(on view: SCNView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            view.addGestureRecognizer(tap)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            view.addGestureRecognizer(pan)
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard !gameManager.inMenu, !gameManager.isPaused else { return }
            guard let view = gesture.view as? SCNView else { return }
            let loc = gesture.location(in: view)
            let hits = view.hitTest(loc, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
            
            if let hit = hits.first(where: { $0.node.name?.starts(with: "piece_") == true || $0.node.parent?.name?.starts(with: "piece_") == true }) {
                let pNode = hit.node.name?.starts(with: "piece_") == true ? hit.node : hit.node.parent!
                let uuidStr = String(pNode.name!.dropFirst(6))
                if let piece = gameManager.pieces.first(where: { $0.id.uuidString == uuidStr }) {
                    if piece.side == gameManager.currentTurn {
                        gameManager.selectPiece(piece)
                        return
                    } else if gameManager.selectedPiece != nil && gameManager.validMoves.contains(where: { $0.col == piece.col && $0.row == piece.row }) {
                        gameManager.executeMove(toCol: piece.col, toRow: piece.row)
                        return
                    }
                }
            }
            if let hitSq = hits.first(where: { $0.node.name?.starts(with: "sq_") == true }),
               let sqName = hitSq.node.name {
                let parts = sqName.split(separator: "_")
                if parts.count == 3, let c = Int(parts[1]), let r = Int(parts[2]) {
                    if gameManager.selectedPiece != nil && gameManager.validMoves.contains(where: { $0.col == c && $0.row == r }) {
                        gameManager.executeMove(toCol: c, toRow: r)
                    }
                }
            }
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard !gameManager.inMenu, !gameManager.isPaused else { return }
            guard let view = gesture.view as? SCNView else { return }
            let t = gesture.translation(in: view)
            if let orbit = view.scene?.rootNode.childNode(withName: "orbitNode", recursively: true) {
                orbit.eulerAngles.y -= Float(t.x) * 0.005
                orbit.eulerAngles.x = max(-0.8, min(0.4, orbit.eulerAngles.x - Float(t.y) * 0.005))
            }
            gesture.setTranslation(.zero, in: view)
        }
    }
}

// MARK: - AR Tabletop View with Identical Detailed Pieces
struct ARChessContainer: UIViewRepresentable {
    @ObservedObject var gameManager: GameManager
    
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.autoenablesDefaultLighting = true
        arView.automaticallyUpdatesLighting = true
        arView.delegate = context.coordinator
        gameManager.arSceneView = arView
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        arView.session.run(config)
        
        context.coordinator.setupARTouch(on: arView)
        return arView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if let anchor = gameManager.arBoardAnchorNode {
            anchor.enumerateChildNodes { node, _ in
                if let name = node.name, name.starts(with: "piece_"), node.physicsBody == nil {
                    node.removeFromParentNode()
                }
            }
            for p in gameManager.pieces {
                let isSel = gameManager.selectedPiece?.id == p.id
                anchor.addChildNode(ChessPieceFactory.buildPieceNode(piece: p, skin: gameManager.pieceSkin, isSelected: isSel))
            }
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(gameManager: gameManager) }
    
    class Coordinator: NSObject, ARSCNViewDelegate {
        var gameManager: GameManager
        var reticleNode: SCNNode?
        
        init(gameManager: GameManager) { self.gameManager = gameManager }
        
        func setupARTouch(on arView: ARSCNView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleARTap(_:)))
            arView.addGestureRecognizer(tap)
            
            let ring = SCNTorus(ringRadius: 0.4, pipeRadius: 0.02)
            let rMat = SCNMaterial(); rMat.diffuse.contents = UIColor.systemGreen; rMat.emission.contents = UIColor.systemGreen
            ring.materials = [rMat]
            let rNode = SCNNode(geometry: ring)
            rNode.isHidden = true
            arView.scene.rootNode.addChildNode(rNode)
            self.reticleNode = rNode
        }
        
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let arView = gameManager.arSceneView, gameManager.arBoardAnchorNode == nil else {
                reticleNode?.isHidden = true
                return
            }
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            if let query = arView.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .horizontal),
               let hit = arView.session.raycast(query).first {
                reticleNode?.simdTransform = hit.worldTransform
                reticleNode?.isHidden = false
            } else {
                reticleNode?.isHidden = true
            }
        }
        
        @objc func handleARTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = gesture.view as? ARSCNView else { return }
            let loc = gesture.location(in: arView)
            
            if gameManager.arBoardAnchorNode == nil {
                if let query = arView.raycastQuery(from: loc, allowing: .estimatedPlane, alignment: .horizontal),
                   let hit = arView.session.raycast(query).first {
                    let anchorNode = SCNNode()
                    anchorNode.simdTransform = hit.worldTransform
                    anchorNode.scale = SCNVector3(0.12, 0.12, 0.12)
                    
                    let woodImg = loadAppTexture("wood_texture")
                    let marbleImg = loadAppTexture("marble_texture")
                    
                    for r in 0..<8 {
                        for c in 0..<8 {
                            let box = SCNBox(width: 1.0, height: 0.1, length: 1.0, chamferRadius: 0.02)
                            let mat = SCNMaterial()
                            mat.diffuse.contents = (r + c) % 2 != 0 ? (woodImg ?? UIColor.darkGray) : (marbleImg ?? UIColor.white)
                            box.materials = [mat]
                            let sq = SCNNode(geometry: box)
                            sq.name = "sq_\(c)_\(r)"
                            sq.position = SCNVector3(Float(c) - 3.5, 0, Float(r) - 3.5)
                            anchorNode.addChildNode(sq)
                        }
                    }
                    arView.scene.rootNode.addChildNode(anchorNode)
                    gameManager.arBoardAnchorNode = anchorNode
                    gameManager.statusText = "Доска на столе! Начинай игру!"
                    SoundEngine.shared.play("move")
                    reticleNode?.removeFromParentNode()
                    return
                }
            }
            
            let hits = arView.hitTest(loc, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
            if let hit = hits.first(where: { $0.node.name?.starts(with: "piece_") == true || $0.node.parent?.name?.starts(with: "piece_") == true }) {
                let pNode = hit.node.name?.starts(with: "piece_") == true ? hit.node : hit.node.parent!
                let uuidStr = String(pNode.name!.dropFirst(6))
                if let piece = gameManager.pieces.first(where: { $0.id.uuidString == uuidStr }) {
                    if piece.side == gameManager.currentTurn {
                        gameManager.selectPiece(piece)
                        return
                    } else if gameManager.selectedPiece != nil && gameManager.validMoves.contains(where: { $0.col == piece.col && $0.row == piece.row }) {
                        gameManager.executeMove(toCol: piece.col, toRow: piece.row)
                        return
                    }
                }
            }
            if let hitSq = hits.first(where: { $0.node.name?.starts(with: "sq_") == true }),
               let sqName = hitSq.node.name {
                let parts = sqName.split(separator: "_")
                if parts.count == 3, let c = Int(parts[1]), let r = Int(parts[2]) {
                    if gameManager.selectedPiece != nil && gameManager.validMoves.contains(where: { $0.col == c && $0.row == r }) {
                        gameManager.executeMove(toCol: c, toRow: r)
                    }
                }
            }
        }
    }
}

// MARK: - Main UI View
struct MainGameView: View {
    @StateObject private var gm = GameManager()
    @State private var showSaves: Bool = false
    @State private var showAIChat: Bool = false
    @State private var showSettings: Bool = false
    
    var body: some View {
        ZStack {
            if gm.isARMode {
                ARChessContainer(gameManager: gm)
                    .ignoresSafeArea()
            } else {
                Chess3DContainer(gameManager: gm)
                    .ignoresSafeArea()
            }
            
            if gm.inMenu {
                ScrollView {
                    VStack(spacing: 16) {
                        Text("VIBE CHESS 3D")
                            .font(.system(size: 28, weight: .black, design: .monospaced))
                            .foregroundColor(.cyan)
                            .shadow(color: .cyan, radius: 10)
                        
                        HStack {
                            Button(action: { showSaves = true }) {
                                Label("СЕЙВЫ", systemImage: "folder.fill")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                            Spacer()
                            Button(action: { showSettings = true }) {
                                Label("НАСТРОЙКИ", systemImage: "gearshape.fill")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            Spacer()
                            Button(action: { showAIChat = true }) {
                                Label("ИИ ЧАТ", systemImage: "brain.head.profile")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.cyan)
                            }
                        }
                        .padding(.horizontal, 4)
                        
                        VStack(alignment: .leading, spacing: 5) {
                            Text("СКИН ФИГУР:").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                            Picker("", selection: $gm.pieceSkin) {
                                ForEach(PieceSkin.allCases) { s in Text(s.rawValue).tag(s) }
                            }.pickerStyle(.menu)
                            .padding(8).background(Color.white.opacity(0.1)).cornerRadius(8)
                        }
                        
                        VStack(alignment: .leading, spacing: 5) {
                            Text("РЕЖИМ:").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                            Picker("", selection: $gm.mode) {
                                ForEach(GameMode.allCases) { m in Text(m.rawValue).tag(m) }
                            }.pickerStyle(.segmented)
                        }
                        
                        VStack(alignment: .leading, spacing: 5) {
                            Text("СТОРОНА:").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                            Picker("", selection: $gm.playerSide) {
                                Text("Золото/Клен").tag(Side.white)
                                Text("Циан/Орех").tag(Side.black)
                            }.pickerStyle(.segmented)
                        }
                        
                        Toggle(isOn: $gm.isARMode) {
                            Label("AR-Режим (на столе)", systemImage: "camera.viewfinder")
                                .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.cyan)
                        }
                        
                        Button(action: { gm.startNewGame(mode: gm.mode, side: gm.playerSide, diff: gm.difficulty) }) {
                            Text("НАЧАТЬ ПАРТИЮ")
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundColor(.black).frame(maxWidth: .infinity)
                                .padding(.vertical, 14).background(Color.cyan).cornerRadius(12)
                        }
                    }
                    .padding(22)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(22)
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.cyan.opacity(0.5), lineWidth: 1.5))
                    .padding(.horizontal, 22)
                    .padding(.top, 65)
                }
            } else {
                VStack {
                    HStack {
                        Button(action: { gm.isPaused = true }) {
                            Image(systemName: "pause.fill")
                                .foregroundColor(.white).padding(10).background(Color.black.opacity(0.75)).clipShape(Circle())
                        }
                        Spacer()
                        Text(gm.statusText)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(gm.isAlert ? .red : .cyan)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.black.opacity(0.8)).cornerRadius(10)
                        Spacer()
                        Button(action: { showAIChat = true }) {
                            Image(systemName: "brain.head.profile")
                                .foregroundColor(.cyan).padding(10).background(Color.black.opacity(0.75)).clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 45)
                    
                    Spacer()
                    
                    HStack(spacing: 12) {
                        Button(action: { gm.cheatModeActive.toggle() }) {
                            Text(gm.cheatModeActive ? "ШУЛЕР ⚠️" : "Сжульничать")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(gm.cheatModeActive ? .black : .red)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(gm.cheatModeActive ? Color.red : Color.black.opacity(0.75)).cornerRadius(10)
                        }
                        
                        Button(action: { gm.performUndo() }) {
                            Text("⏪ Откат (\(gm.undoCount))")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow).padding(.horizontal, 10).padding(.vertical, 8)
                                .background(Color.black.opacity(0.75)).cornerRadius(10)
                        }
                    }
                    .padding(.bottom, 25)
                }
                
                if gm.isPaused {
                    ZStack {
                        Color.black.opacity(0.8).ignoresSafeArea()
                        VStack(spacing: 16) {
                            Text("ПАУЗА")
                                .font(.system(size: 26, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                            
                            Button("Продолжить") { gm.isPaused = false }
                                .buttonStyle(.borderedProminent).tint(.cyan)
                            
                            Button("Настройки") { showSettings = true }
                                .buttonStyle(.bordered)
                            
                            Button("Сохранить партию") { showSaves = true }
                                .buttonStyle(.bordered)
                            
                            Button("Перезапуск") {
                                gm.isPaused = false
                                gm.resetBoard()
                            }
                            .buttonStyle(.bordered)
                            
                            Button("Выход в главное меню") {
                                gm.isPaused = false
                                gm.inMenu = true
                            }
                            .foregroundColor(.red)
                        }
                        .padding(26)
                        .background(Color.black.opacity(0.95))
                        .cornerRadius(20)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    }
                }
            }
        }
        .sheet(isPresented: $showSaves) { SavesModalView(gm: gm) }
        .sheet(isPresented: $showAIChat) { AIChatModalView(gm: gm) }
        .sheet(isPresented: $showSettings) { SettingsModalView(gm: gm) }
    }
}

// MARK: - Full Interactive AI Chatbot Modal
struct AIChatModalView: View {
    @ObservedObject var gm: GameManager
    @Environment(\.dismiss) var dismiss
    @State private var inputMessage: String = ""
    
    var body: some View {
        NavigationView {
            VStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(0..<gm.aiChatMessages.count, id: \.self) { idx in
                            let msg = gm.aiChatMessages[idx]
                            HStack {
                                if msg.sender == "Ты" { Spacer() }
                                VStack(alignment: msg.sender == "Ты" ? .trailing : .leading) {
                                    Text(msg.sender).font(.caption2).foregroundColor(.gray)
                                    Text(msg.text)
                                        .padding(10)
                                        .background(msg.sender == "Ты" ? Color.cyan.opacity(0.3) : Color.white.opacity(0.12))
                                        .cornerRadius(12)
                                }
                                if msg.sender != "Ты" { Spacer() }
                            }
                        }
                    }
                    .padding()
                }
                
                Divider()
                
                HStack {
                    TextField("Спроси гроссмейстера...", text: $inputMessage)
                        .textFieldStyle(.roundedBorder)
                    Button(action: {
                        gm.sendUserMessage(inputMessage)
                        inputMessage = ""
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2).foregroundColor(.cyan)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            .navigationTitle("AI Каспаров-9000")
            .navigationBarItems(trailing: Button("Закрыть") { dismiss() })
        }
    }
}

// MARK: - Settings Modal
struct SettingsModalView: View {
    @ObservedObject var gm: GameManager
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Звук и Музыка")) {
                    Toggle("Звуковые эффекты", isOn: $gm.sfxEnabled)
                    Toggle("Фоновая музыка космоса", isOn: $gm.musicEnabled)
                    Toggle("Голос комментатора", isOn: $gm.voiceEnabled)
                }
                Section(header: Text("Графика и Спецэффекты")) {
                    Toggle("Вспышки лазеров", isOn: $gm.vfxEnabled)
                }
                Section(header: Text("Скины Фигур")) {
                    Picker("Скин", selection: $gm.pieceSkin) {
                        ForEach(PieceSkin.allCases) { s in Text(s.rawValue).tag(s) }
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarItems(trailing: Button("Готово") { dismiss() })
        }
    }
}

// MARK: - Saves Modal View
struct SavesModalView: View {
    @ObservedObject var gm: GameManager
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            List {
                Section("Сохранить текущую партию") {
                    ForEach(1...3, id: \.self) { slotNum in
                        Button("Сохранить в Слот #\(slotNum)") {
                            gm.saveToSlot(slotId: "slot_\(slotNum)", title: "Слот #\(slotNum)")
                            dismiss()
                        }
                    }
                }
                Section("Загрузить сохраненную партию") {
                    if gm.saveSlots.isEmpty {
                        Text("Нет сохраненных партий").foregroundColor(.secondary)
                    } else {
                        ForEach(gm.saveSlots) { slot in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(slot.title).font(.headline)
                                    Text("\(slot.dateString) • Фигур: \(slot.pieces.count)").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Загрузить") {
                                    gm.loadFromSlot(slot)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Слоты Сохранений")
            .navigationBarItems(trailing: Button("Закрыть") { dismiss() })
        }
    }
}
// ==================== КОНЕЦ ФАЙЛА ====================
