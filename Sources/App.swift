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
        loadSound("click")
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
            bgPlayer?.volume = 0.3
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

// MARK: - Texture Cache
struct TextureCache {
    static let wood: UIImage? = {
        if let path = Bundle.main.path(forResource: "wood_texture", ofType: "png") { return UIImage(contentsOfFile: path) }
        return UIImage(named: "wood_texture")
    }()
    
    static let marble: UIImage? = {
        if let path = Bundle.main.path(forResource: "marble_texture", ofType: "png") { return UIImage(contentsOfFile: path) }
        return UIImage(named: "marble_texture")
    }()
}

// MARK: - Enums & Models
enum TimeControl: String, CaseIterable, Identifiable, Codable {
    case infinite = "Без времени"
    case blitz3 = "Блиц 3 мин"
    case rapid5 = "Рапид 5 мин"
    case classic10 = "Классика 10 мин"
    var id: String { rawValue }
    var initialSeconds: Int {
        switch self {
        case .infinite: return 0
        case .blitz3: return 180
        case .rapid5: return 300
        case .classic10: return 600
        }
    }
}

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

struct SaveSlot: Identifiable, Codable {
    var id: String
    var title: String
    var dateString: String
    var pieces: [PieceModel]
    var currentTurn: Side
    var playerSide: Side
    var mode: GameMode
    var difficulty: BotDifficulty
    var whiteSeconds: Int
    var blackSeconds: Int
}

// MARK: - GameManager
class GameManager: ObservableObject {
    @Published var pieces: [PieceModel] = []
    @Published var selectedPiece: PieceModel? = nil
    @Published var validMoves: [(col: Int, row: Int)] = []
    @Published var currentTurn: Side = .white
    @Published var playerSide: Side = .white
    @Published var mode: GameMode = .vsBot
    @Published var difficulty: BotDifficulty = .hard
    @Published var timeControl: TimeControl = .rapid5
    @Published var inMenu: Bool = true
    @Published var isPaused: Bool = false
    @Published var statusText: String = "Твой ход!"
    @Published var lastMoveNotation: String = "Начало партии"
    @Published var isARMode: Bool = false
    @Published var isAnimating: Bool = false
    
    @Published var whiteSeconds: Int = 300
    @Published var blackSeconds: Int = 300
    @Published var isClockActive: Bool = false
    
    @Published var sfxEnabled: Bool = true { didSet { saveSettings() } }
    @Published var musicEnabled: Bool = true { didSet { saveSettings(); SoundEngine.shared.toggleMusic(musicEnabled) } }
    @Published var voiceEnabled: Bool = true { didSet { saveSettings() } }
    
    @Published var saveSlots: [SaveSlot] = []
    @Published var undoCount: Int = 3
    private var moveHistory: [[PieceModel]] = []
    
    @Published var aiChatMessages: [(sender: String, text: String)] = [
        ("Гроссмейстер AI", "Приветствую! Партия проходит по строгим правилам FIDE. Жду твоих вопросов.")
    ]
    
    weak var sceneView: SCNView?
    weak var arSceneView: ARSCNView?
    var arBoardAnchorNode: SCNNode?
    var pieceNodes: [UUID: SCNNode] = [:]
    
    let colNames = ["A","B","C","D","E","F","G","H"]
    
    init() {
        loadSettings()
        loadSavesFromDisk()
        SoundEngine.shared.toggleMusic(musicEnabled)
    }
    
    func saveSettings() {
        UserDefaults.standard.set(sfxEnabled, forKey: "Vibe_Sfx")
        UserDefaults.standard.set(musicEnabled, forKey: "Vibe_Music")
        UserDefaults.standard.set(voiceEnabled, forKey: "Vibe_Voice")
    }
    
    func loadSettings() {
        if UserDefaults.standard.object(forKey: "Vibe_Sfx") != nil { self.sfxEnabled = UserDefaults.standard.bool(forKey: "Vibe_Sfx") }
        if UserDefaults.standard.object(forKey: "Vibe_Music") != nil { self.musicEnabled = UserDefaults.standard.bool(forKey: "Vibe_Music") }
        if UserDefaults.standard.object(forKey: "Vibe_Voice") != nil { self.voiceEnabled = UserDefaults.standard.bool(forKey: "Vibe_Voice") }
    }
    
    func startNewGame(mode: GameMode, side: Side, diff: BotDifficulty, time: TimeControl) {
        self.mode = mode
        self.playerSide = side
        self.difficulty = diff
        self.timeControl = time
        self.currentTurn = .white
        self.inMenu = false
        self.isPaused = false
        self.isAnimating = false
        self.undoCount = 3
        self.lastMoveNotation = "Партия началась"
        
        let initialTime = time.initialSeconds
        self.whiteSeconds = initialTime
        self.blackSeconds = initialTime
        self.isClockActive = (time != .infinite)
        
        self.statusText = mode == .vsBot ? (side == .white ? "Твой ход (Белые)" : "Ход черных...") : "Ход Белых"
        resetBoard()
        moveHistory = [pieces]
        autoSave()
        
        SoundEngine.shared.speak(side == .white ? "Игра началась. Твой ход." : "Игра началась. Черные ходят первыми.", enabled: voiceEnabled)
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
    
    func onClockTick() {
        guard isClockActive, !inMenu, !isPaused, !isAnimating else { return }
        if currentTurn == .white {
            if whiteSeconds > 0 { whiteSeconds -= 1 } else { timeOut(loser: .white) }
        } else {
            if blackSeconds > 0 { blackSeconds -= 1 } else { timeOut(loser: .black) }
        }
    }
    
    private func timeOut(loser: Side) {
        isClockActive = false
        let winner = loser == .white ? "Черные" : "Белые"
        statusText = "Время вышло! Победили \(winner)!"
        SoundEngine.shared.play("capture", enabled: sfxEnabled)
        SoundEngine.shared.speak("Время вышло. Победа присуждена сопернику.", enabled: voiceEnabled)
    }
    
    func selectPiece(_ piece: PieceModel) {
        guard !isAnimating else { return }
        guard piece.side == currentTurn else { return }
        if mode == .vsBot && currentTurn != playerSide { return }
        
        selectedPiece = piece
        SoundEngine.shared.play("select", enabled: sfxEnabled)
        validMoves = calculateLegalMoves(for: piece, in: pieces)
    }
    
    func calculateLegalMoves(for piece: PieceModel, in currentBoard: [PieceModel]) -> [(col: Int, row: Int)] {
        var moves: [(col: Int, row: Int)] = []
        for c in 0..<8 {
            for r in 0..<8 {
                if isPathClearAndValid(piece: piece, toCol: c, toRow: r, in: currentBoard) { moves.append((c, r)) }
            }
        }
        return moves
    }
    
    func isPathClearAndValid(piece: PieceModel, toCol: Int, toRow: Int, in board: [PieceModel]) -> Bool {
        if piece.col == toCol && piece.row == toRow { return false }
        let targetOccupant = board.first { $0.col == toCol && $0.row == toRow }
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
                return !board.contains { $0.col == piece.col && $0.row == piece.row + dir }
            }
            if abs(dx) == 1 && dy == dir && targetOccupant != nil && targetOccupant?.side != piece.side { return true }
            return false
        case .knight:
            return (abs(dx) == 1 && abs(dy) == 2) || (abs(dx) == 2 && abs(dy) == 1)
        case .rook:
            if dx != 0 && dy != 0 { return false }
            return checkLineClear(fromCol: piece.col, fromRow: piece.row, toCol: toCol, toRow: toRow, sx: sx, sy: sy, in: board)
        case .bishop:
            if abs(dx) != abs(dy) { return false }
            return checkLineClear(fromCol: piece.col, fromRow: piece.row, toCol: toCol, toRow: toRow, sx: sx, sy: sy, in: board)
        case .queen:
            if (dx != 0 && dy != 0) && (abs(dx) != abs(dy)) { return false }
            return checkLineClear(fromCol: piece.col, fromRow: piece.row, toCol: toCol, toRow: toRow, sx: sx, sy: sy, in: board)
        case .king:
            return abs(dx) <= 1 && abs(dy) <= 1
        }
    }
    
    private func checkLineClear(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int, sx: Int, sy: Int, in board: [PieceModel]) -> Bool {
        var x = fromCol + sx
        var y = fromRow + sy
        while x != toCol || y != toRow {
            if board.contains(where: { $0.col == x && $0.row == y }) { return false }
            x += sx
            y += sy
        }
        return true
    }
    
    func executeMove(toCol: Int, toRow: Int) {
        guard !isAnimating else { return }
        guard let p = selectedPiece, let idx = pieces.firstIndex(where: { $0.id == p.id }) else { return }
        
        isAnimating = true
        let startNotation = "\(colNames[p.col])\(p.row + 1)"
        let endNotation = "\(colNames[toCol])\(toRow + 1)"
        var isCapture = false
        
        if let targetIdx = pieces.firstIndex(where: { $0.col == toCol && $0.row == toRow && $0.side != p.side }) {
            isCapture = true
            let captured = pieces[targetIdx]
            pieces.remove(at: targetIdx)
            SoundEngine.shared.play("capture", enabled: sfxEnabled)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            launchPhysicsBlast(for: captured.id)
        } else {
            SoundEngine.shared.play("move", enabled: sfxEnabled)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        
        lastMoveNotation = "\(p.type.rawValue.capitalized) \(startNotation) ➔ \(endNotation)"
        if isCapture { lastMoveNotation += " (Взятие)" }
        
        let targetPos = SCNVector3(Float(toCol) - 3.5, 0.05, Float(toRow) - 3.5)
        if let node = pieceNodes[p.id] {
            let lift = SCNAction.move(by: SCNVector3(0, 0.8, 0), duration: 0.15)
            lift.timingMode = .easeOut
            let glide = SCNAction.move(to: SCNVector3(targetPos.x, 0.85, targetPos.z), duration: 0.25)
            glide.timingMode = .easeInEaseOut
            let drop = SCNAction.move(to: targetPos, duration: 0.15)
            drop.timingMode = .easeIn
            
            let finalize = SCNAction.run { _ in DispatchQueue.main.async { self.finalizeMove(pieceIndex: idx, toCol: toCol, toRow: toRow) } }
            node.runAction(SCNAction.sequence([lift, glide, drop, finalize]))
        } else {
            finalizeMove(pieceIndex: idx, toCol: toCol, toRow: toRow)
        }
        
        pieces[idx].col = toCol
        pieces[idx].row = toRow
        selectedPiece = nil
        validMoves = []
    }
    
    private func finalizeMove(pieceIndex: Int, toCol: Int, toRow: Int) {
        if pieces[pieceIndex].type == .pawn {
            if (pieces[pieceIndex].side == .white && toRow == 7) || (pieces[pieceIndex].side == .black && toRow == 0) {
                pieces[pieceIndex].type = .queen
                SoundEngine.shared.speak("Пешка стала ферзем!", enabled: voiceEnabled)
                if let oldNode = pieceNodes[pieces[pieceIndex].id] {
                    let newNode = ChessPieceFactory.buildPieceNode(piece: pieces[pieceIndex], isSelected: false)
                    oldNode.parent?.addChildNode(newNode)
                    oldNode.removeFromParentNode()
                    pieceNodes[pieces[pieceIndex].id] = newNode
                }
            }
        }
        
        SoundEngine.shared.play("click", enabled: sfxEnabled)
        currentTurn = (currentTurn == .white) ? .black : .white
        moveHistory.append(pieces)
        autoSave()
        isAnimating = false
        
        if mode == .vsBot {
            if currentTurn == playerSide {
                statusText = "Твой ход!"
            } else {
                statusText = "Гроссмейстер думает..."
                triggerBotMove()
            }
        } else {
            statusText = currentTurn == .white ? "Ход Белых" : "Ход Черных"
        }
    }
    
    private func launchPhysicsBlast(for pieceId: UUID) {
        guard let node = pieceNodes[pieceId] else { return }
        let body = SCNPhysicsBody(type: .dynamic, shape: nil)
        body.mass = 2.0
        body.isAffectedByGravity = false
        node.physicsBody = body
        
        let fx = Float.random(in: -8...8)
        let fy = Float.random(in: 6...12)
        let fz = Float.random(in: -8...8)
        body.applyForce(SCNVector3(fx, fy, fz), asImpulse: true)
        body.applyTorque(SCNVector4(1, 0, 1, 10), asImpulse: true)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            node.removeFromParentNode()
            self?.pieceNodes.removeValue(forKey: pieceId)
        }
    }
    
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
            let centerValues = [
                [0, 0, 0, 0, 0, 0, 0, 0], [0, 5, 5, 5, 5, 5, 5, 0], [0, 5, 15, 20, 20, 15, 5, 0],
                [0, 5, 20, 30, 30, 20, 5, 0], [0, 5, 20, 30, 30, 20, 5, 0], [0, 5, 15, 20, 20, 15, 5, 0],
                [0, 5, 5, 5, 5, 5, 5, 0], [0, 0, 0, 0, 0, 0, 0, 0]
            ]
            
            for piece in myPieces.shuffled() {
                let moves = self.calculateLegalMoves(for: piece, in: boardSnapshot)
                for m in moves {
                    var score = 0
                    if let target = boardSnapshot.first(where: { $0.col == m.col && $0.row == m.row }) {
                        switch target.type {
                        case .pawn: score += 100; case .knight, .bishop: score += 320
                        case .rook: score += 500; case .queen: score += 950; case .king: score += 10000
                        }
                    }
                    if currentDiff == .hard || currentDiff == .medium { score += centerValues[m.row][m.col] }
                    if score > bestScore || chosenPiece == nil {
                        bestScore = score
                        chosenPiece = piece
                        chosenMove = m
                    }
                }
            }
            
            while self.isAnimating { Thread.sleep(forTimeInterval: 0.1) }
            DispatchQueue.main.async {
                if let p = chosenPiece, let m = chosenMove {
                    self.selectedPiece = p
                    self.executeMove(toCol: m.col, toRow: m.row)
                }
            }
        }
    }
    
    func sendUserMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        aiChatMessages.append(("Ты", trimmed))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            let lower = trimmed.lowercased()
            let reply: String
            
            if lower.contains("лучший") || lower.contains("ход") {
                let current = self.pieces.filter { $0.side == self.currentTurn }
                if let p = current.randomElement(), let m = self.calculateLegalMoves(for: p, in: self.pieces).randomElement() {
                    reply = "Алгоритм советует: \(p.type.rawValue) на \(self.colNames[m.col])\(m.row + 1)."
                } else {
                    reply = "Укрепляй пешки и выводи легкие фигуры."
                }
            } else if lower.contains("оцен") || lower.contains("шанс") {
                let w = self.pieces.filter { $0.side == .white }.count
                let b = self.pieces.filter { $0.side == .black }.count
                reply = "Материал на доске: Белые (\(w)) vs Черные (\(b)). Позиция в равновесии."
            } else {
                reply = "Веди позиционную игру, контролируй диагонали и рассчитывай ответы на два хода вперед."
            }
            self.aiChatMessages.append(("Гроссмейстер AI", reply))
            SoundEngine.shared.speak(reply, enabled: self.voiceEnabled)
        }
    }
    
    func performUndo() {
        guard !isAnimating, undoCount > 0, moveHistory.count > 1 else { return }
        moveHistory.removeLast()
        if let prev = moveHistory.last {
            pieces = prev
            undoCount -= 1
            currentTurn = playerSide
            selectedPiece = nil
            validMoves = []
            statusText = "Ход отменен!"
            lastMoveNotation = "Откат во времени"
            SoundEngine.shared.play("select", enabled: sfxEnabled)
            for (_, node) in pieceNodes { node.removeFromParentNode() }
            pieceNodes.removeAll()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
    
    func saveToSlot(slotId: String, title: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        let newSlot = SaveSlot(
            id: slotId, title: title, dateString: formatter.string(from: Date()),
            pieces: pieces, currentTurn: currentTurn, playerSide: playerSide,
            mode: mode, difficulty: difficulty, whiteSeconds: whiteSeconds, blackSeconds: blackSeconds
        )
        saveSlots.removeAll { $0.id == slotId }
        saveSlots.append(newSlot)
        if let data = try? JSONEncoder().encode(saveSlots) { UserDefaults.standard.set(data, forKey: "Vibe_Slots") }
        SoundEngine.shared.play("select", enabled: sfxEnabled)
    }
    
    func loadFromSlot(_ slot: SaveSlot) {
        self.pieces = slot.pieces
        self.currentTurn = slot.currentTurn
        self.playerSide = slot.playerSide
        self.mode = slot.mode
        self.difficulty = slot.difficulty
        self.whiteSeconds = slot.whiteSeconds
        self.blackSeconds = slot.blackSeconds
        self.inMenu = false
        self.isPaused = false
        self.isAnimating = false
        self.selectedPiece = nil
        self.validMoves = []
        self.statusText = "Партия загружена!"
        self.lastMoveNotation = "Загружено из сохранения"
        SoundEngine.shared.play("select", enabled: sfxEnabled)
        for (_, node) in pieceNodes { node.removeFromParentNode() }
        pieceNodes.removeAll()
    }
    
    private func autoSave() { saveToSlot(slotId: "auto", title: "Автосейв") }
    private func loadSavesFromDisk() {
        if let data = UserDefaults.standard.data(forKey: "Vibe_Slots"),
           let s = try? JSONDecoder().decode([SaveSlot].self, from: data) { self.saveSlots = s }
    }
}

// MARK: - Staunton Piece Factory
class ChessPieceFactory {
    static func buildPieceNode(piece: PieceModel, isSelected: Bool) -> SCNNode {
        let root = SCNNode(); root.name = "piece_\(piece.id.uuidString)"
        
        let mat = SCNMaterial()
        if let wood = TextureCache.wood {
            mat.diffuse.contents = wood
            if piece.side == .white {
                mat.multiply.contents = UIColor(red: 0.95, green: 0.88, blue: 0.76, alpha: 1.0)
            } else {
                mat.multiply.contents = UIColor(red: 0.22, green: 0.14, blue: 0.08, alpha: 1.0)
            }
        } else {
            if piece.side == .white {
                mat.diffuse.contents = UIColor.white
            } else {
                mat.diffuse.contents = UIColor.black
            }
        }
        mat.metalness.contents = 0.05
        mat.roughness.contents = 0.25
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

// MARK: - 3D Solar System View
struct Chess3DContainer: UIViewRepresentable {
    @ObservedObject var gameManager: GameManager
    
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = UIColor(red: 0.01, green: 0.01, blue: 0.03, alpha: 1.0)
        view.antialiasingMode = .multisampling4X
        gameManager.sceneView = view
        
        scene.lightingEnvironment.contents = UIColor(white: 0.85, alpha: 1.0)
        scene.lightingEnvironment.intensity = 1.3
        
        let planet = SCNSphere(radius: 5.5)
        let pMat = SCNMaterial(); pMat.diffuse.contents = UIColor(red: 0.82, green: 0.65, blue: 0.48, alpha: 1.0)
        planet.materials = [pMat]
        let planetNode = SCNNode(geometry: planet)
        planetNode.position = SCNVector3(0, 8.5, -16)
        
        let ring = SCNCylinder(radius: 10.5, height: 0.04)
        let rMat = SCNMaterial(); rMat.diffuse.contents = UIColor(red: 0.88, green: 0.75, blue: 0.58, alpha: 0.55)
        ring.materials = [rMat]
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles.x = 0.38
        planetNode.addChildNode(ringNode)
        scene.rootNode.addChildNode(planetNode)
        planetNode.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.4, z: 0, duration: 25)))
        
        let stars = SCNNode()
        for _ in 0..<160 {
            let starRadius: CGFloat = 0.035
            let star = SCNSphere(radius: starRadius)
            let m = SCNMaterial(); m.emission.contents = UIColor.white
            star.materials = [m]
            let sn = SCNNode(geometry: star)
            let px = Float.random(in: -35...35)
            let py = Float.random(in: -15...35)
            let pz = Float.random(in: -35...35)
            sn.position = SCNVector3(px, py, pz)
            stars.addChildNode(sn)
        }
        scene.rootNode.addChildNode(stars)
        
        let orbit = SCNNode(); orbit.name = "orbitNode"
        let camNode = SCNNode(); let cam = SCNCamera()
        cam.bloomIntensity = 1.1; cam.bloomThreshold = 0.5
        camNode.camera = cam; camNode.position = SCNVector3(0, 9.8, 9.2)
        camNode.look(at: SCNVector3(0, 0, -0.5))
        orbit.addChildNode(camNode)
        scene.rootNode.addChildNode(orbit)
        view.pointOfView = camNode
        
        orbit.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.25, z: 0, duration: 20)), forKey: "menuOrbit")
        
        let sun = SCNLight(); sun.type = .directional; sun.castsShadow = true
        sun.shadowMode = .deferred; sun.shadowSampleCount = 16
        let sunNode = SCNNode(); sunNode.light = sun; sunNode.position = SCNVector3(7, 16, 7)
        sunNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(sunNode)
        
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 260
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
                    orbit.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.25, z: 0, duration: 20)), forKey: "menuOrbit")
                }
            } else {
                orbit.removeAction(forKey: "menuOrbit")
            }
        }
        
        if gameManager.pieceNodes.count != gameManager.pieces.count && !gameManager.isAnimating {
            scene.rootNode.enumerateChildNodes { node, _ in
                if let name = node.name, name.starts(with: "piece_"), node.physicsBody == nil { node.removeFromParentNode() }
            }
            gameManager.pieceNodes.removeAll()
            for p in gameManager.pieces {
                let isSel = gameManager.selectedPiece?.id == p.id
                let node = ChessPieceFactory.buildPieceNode(piece: p, isSelected: isSel)
                scene.rootNode.addChildNode(node)
                gameManager.pieceNodes[p.id] = node
            }
        }
        drawElegantMoveDots(on: scene.rootNode)
    }
    
    private func buildTexturedBoard(on root: SCNNode) {
        let board = SCNNode(); board.name = "boardNode"
        let woodImg = TextureCache.wood
        let marbleImg = TextureCache.marble
        for r in 0..<8 {
            for c in 0..<8 {
                let box = SCNBox(width: 1.0, height: 0.15, length: 1.0, chamferRadius: 0.02)
                let mat = SCNMaterial(); mat.lightingModel = .physicallyBased
                let isDarkSquare = (r + c) % 2 != 0
                if isDarkSquare {
                    if let wood = woodImg { mat.diffuse.contents = wood } else { mat.diffuse.contents = UIColor.darkGray }
                    mat.metalness.contents = 0.2
                    mat.roughness.contents = 0.35
                } else {
                    if let marble = marbleImg { mat.diffuse.contents = marble } else { mat.diffuse.contents = UIColor.white }
                    mat.metalness.contents = 0.1
                    mat.roughness.contents = 0.4
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
    
    private func drawElegantMoveDots(on root: SCNNode) {
        root.enumerateChildNodes { node, _ in
            if let name = node.name, name == "moveDot" { node.removeFromParentNode() }
        }
        for m in gameManager.validMoves {
            let dot = SCNSphere(radius: 0.15)
            let mat = SCNMaterial(); mat.diffuse.contents = UIColor.clear; mat.emission.contents = UIColor.systemGreen.withAlphaComponent(0.8)
            dot.materials = [mat]
            let dotNode = SCNNode(geometry: dot)
            dotNode.name = "moveDot"
            dotNode.position = SCNVector3(Float(m.col) - 3.5, 0.2, Float(m.row) - 3.5)
            root.addChildNode(dotNode)
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
            guard !gameManager.inMenu, !gameManager.isPaused, !gameManager.isAnimating else { return }
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
            if let hitSq = hits.first(where: { $0.node.name?.starts(with: "sq_") == true || $0.node.name == "moveDot" }) {
                let nodeName = hitSq.node.name ?? ""
                let targetCol: Int; let targetRow: Int
                if nodeName == "moveDot" {
                    targetCol = Int(round(hitSq.node.position.x + 3.5))
                    targetRow = Int(round(hitSq.node.position.z + 3.5))
                } else {
                    let parts = nodeName.split(separator: "_")
                    targetCol = Int(parts[1])!; targetRow = Int(parts[2])!
                }
                if gameManager.selectedPiece != nil && gameManager.validMoves.contains(where: { $0.col == targetCol && $0.row == targetRow }) {
                    gameManager.executeMove(toCol: targetCol, toRow: targetRow)
                }
            }
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard !gameManager.inMenu, !gameManager.isPaused, !gameManager.isAnimating else { return }
            guard let view = gesture.view as? SCNView else { return }
            let t = gesture.translation(in: view)
            if let orbit = view.scene?.rootNode.childNode(withName: "orbitNode", recursively: true) {
                orbit.eulerAngles.y -= Float(t.x) * 0.005
                orbit.eulerAngles.x = max(-0.8, min(0.35, orbit.eulerAngles.x - Float(t.y) * 0.005))
            }
            gesture.setTranslation(.zero, in: view)
        }
    }
}

// MARK: - AR Tabletop View
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
            if gameManager.pieceNodes.count != gameManager.pieces.count && !gameManager.isAnimating {
                anchor.enumerateChildNodes { node, _ in
                    if let name = node.name, name.starts(with: "piece_"), node.physicsBody == nil { node.removeFromParentNode() }
                }
                gameManager.pieceNodes.removeAll()
                for p in gameManager.pieces {
                    let node = ChessPieceFactory.buildPieceNode(piece: p, isSelected: gameManager.selectedPiece?.id == p.id)
                    anchor.addChildNode(node)
                    gameManager.pieceNodes[p.id] = node
                }
            }
            drawElegantMoveDots(on: anchor)
        }
    }
    
    private func drawElegantMoveDots(on root: SCNNode) {
        root.enumerateChildNodes { node, _ in if node.name == "moveDot" { node.removeFromParentNode() } }
        for m in gameManager.validMoves {
            let dot = SCNSphere(radius: 0.15)
            let mat = SCNMaterial(); mat.diffuse.contents = UIColor.clear; mat.emission.contents = UIColor.systemGreen.withAlphaComponent(0.8)
            dot.materials = [mat]
            let dotNode = SCNNode(geometry: dot)
            dotNode.name = "moveDot"
            dotNode.position = SCNVector3(Float(m.col) - 3.5, 0.2, Float(m.row) - 3.5)
            root.addChildNode(dotNode)
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
            let targetType = ARRaycastQuery.Target.estimatedPlane
            let alignType = ARRaycastQuery.TargetAlignment.horizontal
            if let query = arView.raycastQuery(from: center, allowing: targetType, alignment: alignType) {
                if let hit = arView.session.raycast(query).first {
                    reticleNode?.simdTransform = hit.worldTransform
                    reticleNode?.isHidden = false
                } else {
                    reticleNode?.isHidden = true
                }
            } else {
                reticleNode?.isHidden = true
            }
        }
        
        @objc func handleARTap(_ gesture: UITapGestureRecognizer) {
            guard !gameManager.isAnimating else { return }
            guard let arView = gesture.view as? ARSCNView else { return }
            let loc = gesture.location(in: arView)
            
            if gameManager.arBoardAnchorNode == nil {
                let targetType = ARRaycastQuery.Target.estimatedPlane
                let alignType = ARRaycastQuery.TargetAlignment.horizontal
                if let query = arView.raycastQuery(from: loc, allowing: targetType, alignment: alignType) {
                    if let hit = arView.session.raycast(query).first {
                        let anchorNode = SCNNode()
                        anchorNode.simdTransform = hit.worldTransform
                        anchorNode.scale = SCNVector3(0.12, 0.12, 0.12)
                        
                        let woodImg = TextureCache.wood
                        let marbleImg = TextureCache.marble
                        for r in 0..<8 {
                            for c in 0..<8 {
                                let box = SCNBox(width: 1.0, height: 0.1, length: 1.0, chamferRadius: 0.02)
                                let mat = SCNMaterial()
                                let isDark = (r + c) % 2 != 0
                                if isDark {
                                    if let wood = woodImg { mat.diffuse.contents = wood } else { mat.diffuse.contents = UIColor.darkGray }
                                } else {
                                    if let marble = marbleImg { mat.diffuse.contents = marble } else { mat.diffuse.contents = UIColor.white }
                                }
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
                        
                        for p in gameManager.pieces {
                            let node = ChessPieceFactory.buildPieceNode(piece: p, isSelected: false)
                            anchorNode.addChildNode(node)
                            gameManager.pieceNodes[p.id] = node
                        }
                        return
                    }
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
            if let hitSq = hits.first(where: { $0.node.name?.starts(with: "sq_") == true || $0.node.name == "moveDot" }) {
                let nodeName = hitSq.node.name ?? ""
                let targetCol: Int; let targetRow: Int
                if nodeName == "moveDot" {
                    targetCol = Int(round(hitSq.node.position.x + 3.5))
                    targetRow = Int(round(hitSq.node.position.z + 3.5))
                } else {
                    let parts = nodeName.split(separator: "_")
                    targetCol = Int(parts[1])!; targetRow = Int(parts[2])!
                }
                if gameManager.selectedPiece != nil && gameManager.validMoves.contains(where: { $0.col == targetCol && $0.row == targetRow }) {
                    gameManager.executeMove(toCol: targetCol, toRow: targetRow)
                }
            }
        }
    }
}

// MARK: - FLATTENED ROOT VIEW
struct MainGameView: View {
    @StateObject private var gm = GameManager()
    @State private var showSaves = false
    @State private var showSettings = false
    @State private var showAIChat = false
    
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            if gm.isARMode {
                ARChessContainer(gameManager: gm).ignoresSafeArea()
            } else {
                Chess3DContainer(gameManager: gm).ignoresSafeArea()
            }
            
            if gm.inMenu {
                MenuOverlayView(gm: gm, showSaves: $showSaves, showSettings: $showSettings, showAIChat: $showAIChat)
            } else {
                HUDOverlayView(gm: gm, showAIChat: $showAIChat)
                if gm.isPaused {
                    PauseOverlayView(gm: gm, showSaves: $showSaves, showSettings: $showSettings)
                }
            }
        }
        .onReceive(timer) { _ in gm.onClockTick() }
        .sheet(isPresented: $showSaves) { SavesModalView(gm: gm) }
        .sheet(isPresented: $showAIChat) { AIChatModalView(gm: gm) }
        .sheet(isPresented: $showSettings) { SettingsModalView(gm: gm) }
    }
}

// MARK: - 10 INDEPENDENT MICRO-STRUCTURES (FAST COMPILE)
struct MenuHeaderTitleView: View {
    var body: some View {
        Text("VIBE CHESS 3D")
            .font(.system(size: 28, weight: .black, design: .monospaced))
            .foregroundColor(.cyan)
            .shadow(color: .cyan, radius: 10)
    }
}

struct MenuNavButtonsView: View {
    @Binding var showSaves: Bool
    @Binding var showSettings: Bool
    @Binding var showAIChat: Bool
    
    var body: some View {
        HStack {
            Button(action: { showSaves = true }) { Label("СЕЙВЫ", systemImage: "folder.fill").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.yellow) }
            Spacer()
            Button(action: { showSettings = true }) { Label("НАСТРОЙКИ", systemImage: "gearshape.fill").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.white) }
            Spacer()
            Button(action: { showAIChat = true }) { Label("ИИ ЧАТ", systemImage: "brain.head.profile").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.cyan) }
        }.padding(.horizontal, 4)
    }
}

struct TimePickerBlockView: View {
    @Binding var timeControl: TimeControl
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("КОНТРОЛЬ ВРЕМЕНИ:").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.6))
            Picker("", selection: $timeControl) { ForEach(TimeControl.allCases) { t in Text(t.rawValue).tag(t) } }.pickerStyle(.segmented)
        }
    }
}

struct ModePickerBlockView: View {
    @Binding var mode: GameMode
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("РЕЖИМ:").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.6))
            Picker("", selection: $mode) { ForEach(GameMode.allCases) { m in Text(m.rawValue).tag(m) } }.pickerStyle(.segmented)
        }
    }
}

struct SidePickerBlockView: View {
    @Binding var side: Side
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("СТОРОНА:").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.6))
            Picker("", selection: $side) {
                Text("Белые (Клен)").tag(Side.white)
                Text("Черные (Орех)").tag(Side.black)
            }.pickerStyle(.segmented)
        }
    }
}

struct MenuOverlayView: View {
    @ObservedObject var gm: GameManager
    @Binding var showSaves: Bool
    @Binding var showSettings: Bool
    @Binding var showAIChat: Bool
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                MenuHeaderTitleView()
                MenuNavButtonsView(showSaves: $showSaves, showSettings: $showSettings, showAIChat: $showAIChat)
                TimePickerBlockView(timeControl: $gm.timeControl)
                ModePickerBlockView(mode: $gm.mode)
                SidePickerBlockView(side: $gm.playerSide)
                Toggle(isOn: $gm.isARMode) { Label("AR-Режим (на столе)", systemImage: "camera.viewfinder").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.cyan) }
                Button(action: { gm.startNewGame(mode: gm.mode, side: gm.playerSide, diff: gm.difficulty, time: gm.timeControl) }) {
                    Text("НАЧАТЬ ПАРТИЮ").font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundColor(.black).frame(maxWidth: .infinity).padding(.vertical, 14).background(Color.cyan).cornerRadius(12)
                }
            }
            .padding(22).background(Color.black.opacity(0.85)).cornerRadius(22).overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.cyan.opacity(0.5), lineWidth: 1.5)).padding(.horizontal, 22).padding(.top, 65)
        }
    }
}

struct ClockBadgeView: View {
    let seconds: Int
    let isTurn: Bool
    let label: String
    
    var body: some View {
        Text("\(label) \(formatSec(seconds))")
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundColor(isTurn ? Color.green : Color.white.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isTurn ? Color.white.opacity(0.15) : Color.black.opacity(0.5))
            .cornerRadius(8)
    }
    private func formatSec(_ s: Int) -> String { return String(format: "%02d:%02d", s / 60, s % 60) }
}

struct HUDOverlayView: View {
    @ObservedObject var gm: GameManager
    @Binding var showAIChat: Bool
    
    var body: some View {
        VStack {
            HStack {
                Button(action: { gm.isPaused = true }) { Image(systemName: "pause.fill").foregroundColor(.white).padding(9).background(Color.black.opacity(0.75)).clipShape(Circle()) }
                Spacer()
                if gm.isClockActive {
                    HStack(spacing: 8) {
                        ClockBadgeView(seconds: gm.whiteSeconds, isTurn: gm.currentTurn == .white, label: "⚪️")
                        ClockBadgeView(seconds: gm.blackSeconds, isTurn: gm.currentTurn == .black, label: "⚫️")
                    }
                } else {
                    Text(gm.statusText).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.cyan).padding(.horizontal, 10).padding(.vertical, 5).background(Color.black.opacity(0.8)).cornerRadius(8)
                }
                Spacer()
                Button(action: { showAIChat = true }) { Image(systemName: "brain.head.profile").foregroundColor(.cyan).padding(9).background(Color.black.opacity(0.75)).clipShape(Circle()) }
            }
            .padding(.horizontal, 14).padding(.top, 45)
            Spacer()
            HStack {
                Button(action: { gm.performUndo() }) {
                    HStack(spacing: 4) { Image(systemName: "arrow.uturn.backward"); Text("Откат (\(gm.undoCount))") }.font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.yellow).padding(.horizontal, 12).padding(.vertical, 8).background(Color.black.opacity(0.75)).cornerRadius(10)
                }
                Spacer()
                Text(gm.lastMoveNotation).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.cyan).padding(.horizontal, 10).padding(.vertical, 8).background(Color.black.opacity(0.75)).cornerRadius(10)
            }
            .padding(.horizontal, 16).padding(.bottom, 25)
        }
    }
}

struct PauseOverlayView: View {
    @ObservedObject var gm: GameManager
    @Binding var showSaves: Bool
    @Binding var showSettings: Bool
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("ПАУЗА").font(.system(size: 26, weight: .black, design: .monospaced)).foregroundColor(.white)
                Button("Продолжить") { gm.isPaused = false }.buttonStyle(.borderedProminent).tint(.cyan)
                Button("Настройки") { showSettings = true }.buttonStyle(.bordered)
                Button("Сохранить партию") { showSaves = true }.buttonStyle(.bordered)
                Button("Перезапуск") { gm.isPaused = false; gm.resetBoard() }.buttonStyle(.bordered)
                Button("Выход в меню") { gm.isPaused = false; gm.inMenu = true }.foregroundColor(.red)
            }
            .padding(26).background(Color.black.opacity(0.95)).cornerRadius(20).overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.2), lineWidth: 1))
        }
    }
}

// MARK: - Modals
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
                            let isUser = msg.sender == "Ты"
                            HStack {
                                if isUser { Spacer() }
                                VStack(alignment: isUser ? .trailing : .leading) {
                                    Text(msg.sender).font(.caption2).foregroundColor(.gray)
                                    Text(msg.text).padding(10).background(isUser ? Color.cyan.opacity(0.3) : Color.white.opacity(0.12)).cornerRadius(12)
                                }
                                if !isUser { Spacer() }
                            }
                        }
                    }.padding()
                }
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("🧠 Лучший ход?") { gm.sendUserMessage("Какой ход лучший?") }.buttonStyle(.borderedTinted).tint(.cyan)
                        Button("⚖️ Оцени позицию") { gm.sendUserMessage("Оцени шансы") }.buttonStyle(.borderedTinted).tint(.cyan)
                    }.padding(.horizontal)
                }
                HStack {
                    TextField("Сообщение ИИ...", text: $inputMessage).textFieldStyle(.roundedBorder)
                    Button(action: { gm.sendUserMessage(inputMessage); inputMessage = "" }) { Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundColor(.cyan) }
                }.padding(.horizontal).padding(.bottom, 10).padding(.top, 4)
            }
            .navigationTitle("AI Каспаров-9000")
            .navigationBarItems(trailing: Button("Закрыть") { dismiss() })
        }
    }
}

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
                Section(header: Text("Сложность Бота")) {
                    Picker("Сложность", selection: $gm.difficulty) { ForEach(BotDifficulty.allCases) { d in Text(d.rawValue).tag(d) } }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarItems(trailing: Button("Готово") { dismiss() })
        }
    }
}

struct SavesModalView: View {
    @ObservedObject var gm: GameManager
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationView {
            List {
                Section("Сохранить партию") {
                    ForEach(1...3, id: \.self) { num in
                        Button("Сохранить в Слот #\(num)") { gm.saveToSlot(slotId: "slot_\(num)", title: "Слот #\(num)"); dismiss() }
                    }
                }
                Section("Загрузить партию") {
                    if gm.saveSlots.isEmpty {
                        Text("Нет сохранений").foregroundColor(.secondary)
                    } else {
                        ForEach(gm.saveSlots) { slot in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(slot.title).font(.headline)
                                    Text("\(slot.dateString) • Фигур: \(slot.pieces.count)").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Загрузить") { gm.loadFromSlot(slot); dismiss() }.buttonStyle(.borderedProminent)
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
