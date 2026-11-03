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

// MARK: - Audio Engine
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
            bgPlayer?.volume = 0.3
            bgPlayer?.prepareToPlay()
        }
    }
    
    func play(_ name: String, enabled: Bool = true) {
        guard enabled else { return }
        if let p = players[name] {
            p.currentTime = 0
            p.play()
        } else {
            AudioServicesPlaySystemSound(1057)
        }
    }
    
    func toggleMusic(_ play: Bool) {
        if play { bgPlayer?.play() } else { bgPlayer?.pause() }
    }
    
    func speak(_ text: String, enabled: Bool = true) {
        guard enabled else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = 0.48
        utterance.pitchMultiplier = 0.85
        speechSynth.speak(utterance)
    }
}

// MARK: - Save System (Multiple Slots)
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

// MARK: - Enums & Models
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
    @Published var difficulty: BotDifficulty = .medium
    @Published var inMenu: Bool = true
    @Published var statusText: String = "Твой ход!"
    @Published var isAlert: Bool = false
    @Published var cheatModeActive: Bool = false
    @Published var isARMode: Bool = false
    
    // Система сохранений
    @Published var saveSlots: [SaveSlot] = []
    @Published var undoCount: Int = 3
    private var moveHistory: [[PieceModel]] = []
    
    // Настройки
    @Published var sfxEnabled: Bool = true
    @Published var voiceEnabled: Bool = true
    @Published var vfxEnabled: Bool = true
    
    weak var sceneView: SCNView?
    weak var arSceneView: ARSCNView?
    var arBoardAnchorNode: SCNNode?
    
    init() {
        loadSavesFromDisk()
        SoundEngine.shared.toggleMusic(true)
    }
    
    func startNewGame(mode: GameMode, side: Side, diff: BotDifficulty) {
        self.mode = mode
        self.playerSide = side
        self.difficulty = diff
        self.currentTurn = .white
        self.inMenu = false
        self.cheatModeActive = false
        self.undoCount = 3
        self.statusText = mode == .vsBot ? (side == .white ? "Твой ход (Золото)" : "Ход бота...") : "Ход Белых"
        resetBoard()
        moveHistory = [pieces]
        autoSave()
        
        SoundEngine.shared.speak(side == .white ? "Игра началась. Твой ход." : "Игра началась. Бот ходит первым.", enabled: voiceEnabled)
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
    
    // Сохранение в конкретный слот
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
        self.selectedPiece = nil
        self.validMoves = []
        self.statusText = "Партия загружена!"
        SoundEngine.shared.play("select", enabled: sfxEnabled)
    }
    
    private func autoSave() {
        saveToSlot(slotId: "autosave", title: "Автосохранение")
    }
    
    private func saveSavesToDisk() {
        if let data = try? JSONEncoder().encode(saveSlots) {
            UserDefaults.standard.set(data, forKey: "Vibe_SaveSlots")
        }
    }
    
    private func loadSavesFromDisk() {
        if let data = UserDefaults.standard.data(forKey: "Vibe_SaveSlots"),
           let slots = try? JSONDecoder().decode([SaveSlot].self, from: data) {
            self.saveSlots = slots
        }
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
                SoundEngine.shared.speak("Внимание! Попытка саботажа!", enabled: voiceEnabled)
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
                statusText = "Бот вычисляет ход..."
                triggerBotMove()
            }
        } else {
            statusText = currentTurn == .white ? "Ход Белых" : "Ход Черных"
        }
    }
    
    // Эпичный удар лазера со световой вспышкой
    private func triggerEpicLaserStrike(atCol: Int, atRow: Int, targetId: UUID) {
        guard let scene = (isARMode ? arSceneView?.scene : sceneView?.scene) else { return }
        SoundEngine.shared.play("laser", enabled: sfxEnabled)
        
        let root = isARMode ? (arBoardAnchorNode ?? scene.rootNode) : scene.rootNode
        
        // 1. Мощный луч лазера
        let laser = SCNCylinder(radius: 0.1, height: 20.0)
        let lMat = SCNMaterial()
        lMat.diffuse.contents = UIColor.cyan
        lMat.emission.contents = UIColor.white
        laser.materials = [lMat]
        let laserNode = SCNNode(geometry: laser)
        laserNode.position = SCNVector3(Float(atCol) - 3.5, 10.0, Float(atRow) - 3.5)
        root.addChildNode(laserNode)
        
        // 2. Вспышка света в точке удара
        let flashLight = SCNLight()
        flashLight.type = .omni
        flashLight.color = UIColor.cyan
        flashLight.intensity = 4000
        let flashNode = SCNNode()
        flashNode.light = flashLight
        flashNode.position = SCNVector3(Float(atCol) - 3.5, 0.5, Float(atRow) - 3.5)
        root.addChildNode(flashNode)
        
        // Анимация затухания
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        laserNode.opacity = 0.0
        flashLight.intensity = 0
        SCNTransaction.commit()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            laserNode.removeFromParentNode()
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
    
    func triggerBotMove() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self = self else { return }
            let botSide = self.playerSide == .white ? Side.black : Side.white
            let botPieces = self.pieces.filter { $0.side == botSide }
            var bestScore = -9999
            var chosenPiece: PieceModel?
            var chosenTarget: (col: Int, row: Int)?
            
            for p in botPieces.shuffled() {
                let moves = self.calculateLegalMoves(for: p)
                for m in moves {
                    var score = 0
                    if let target = self.pieces.first(where: { $0.col == m.col && $0.row == m.row }) {
                        switch target.type {
                        case .pawn: score += 10
                        case .knight, .bishop: score += 30
                        case .rook: score += 50
                        case .queen: score += 95
                        case .king: score += 1000
                        }
                    }
                    if self.difficulty == .hard { score += (8 - abs(3 - m.col) - abs(3 - m.row)) }
                    if score > bestScore || chosenPiece == nil {
                        bestScore = score
                        chosenPiece = p
                        chosenTarget = m
                    }
                }
            }
            if let p = chosenPiece, let t = chosenTarget {
                self.selectedPiece = p
                self.executeMove(toCol: t.col, toRow: t.row)
            }
        }
    }
}

// MARK: - 3D Space View
struct Chess3DContainer: UIViewRepresentable {
    @ObservedObject var gameManager: GameManager
    
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = UIColor(red: 0.01, green: 0.01, blue: 0.03, alpha: 1.0)
        view.antialiasingMode = .multisampling4X
        gameManager.sceneView = view
        
        // Звезды
        let stars = SCNNode()
        for _ in 0..<160 {
            let star = SCNSphere(radius: 0.03)
            let m = SCNMaterial(); m.emission.contents = UIColor.white
            star.materials = [m]
            let sn = SCNNode(geometry: star)
            sn.position = SCNVector3(Float.random(in: -30...30), Float.random(in: -15...30), Float.random(in: -30...30))
            stars.addChildNode(sn)
        }
        scene.rootNode.addChildNode(stars)
        
        // Камера
        let orbit = SCNNode(); orbit.name = "orbitNode"
        let camNode = SCNNode(); let cam = SCNCamera()
        cam.bloomIntensity = 1.3; cam.bloomThreshold = 0.5
        camNode.camera = cam; camNode.position = SCNVector3(0, 11, 9.5)
        camNode.look(at: SCNVector3(0, 0, 0))
        orbit.addChildNode(camNode)
        scene.rootNode.addChildNode(orbit)
        view.pointOfView = camNode
        
        // Свет
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
        syncPieces(on: scene.rootNode)
        highlightSquares(on: scene.rootNode)
    }
    
    private func buildTexturedBoard(on root: SCNNode) {
        let board = SCNNode(); board.name = "boardNode"
        let woodImg = UIImage(named: "wood_texture.png")
        let marbleImg = UIImage(named: "marble_texture.png")
        
        for r in 0..<8 {
            for c in 0..<8 {
                let box = SCNBox(width: 1.0, height: 0.15, length: 1.0, chamferRadius: 0.02)
                let mat = SCNMaterial()
                mat.lightingModel = .physicallyBased
                if (r + c) % 2 != 0 {
                    mat.diffuse.contents = woodImg ?? UIColor(white: 0.08, alpha: 1)
                    mat.metalness.contents = 0.3
                    mat.roughness.contents = 0.4
                } else {
                    mat.diffuse.contents = marbleImg ?? UIColor(white: 0.88, alpha: 1)
                    mat.metalness.contents = 0.1
                    mat.roughness.contents = 0.5
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
            root.addChildNode(buildPieceNode(piece: p))
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
    
    private func buildPieceNode(piece: PieceModel) -> SCNNode {
        let root = SCNNode(); root.name = "piece_\(piece.id.uuidString)"
        let color = piece.side == .white ? UIColor(red: 1.0, green: 0.75, blue: 0.2, alpha: 1.0) : UIColor(red: 0.1, green: 0.85, blue: 1.0, alpha: 1.0)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.black
        mat.emission.contents = color
        mat.metalness.contents = 0.85; mat.roughness.contents = 0.15
        
        let isSel = gameManager.selectedPiece?.id == piece.id
        let baseHeight: Float = isSel ? 0.45 : 0.05
        
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

// MARK: - AR Tabletop View (Real ARKit with LiDAR Plane Tracking!)
struct ARChessContainer: UIViewRepresentable {
    @ObservedObject var gameManager: GameManager
    
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.autoenablesDefaultLighting = true
        arView.automaticallyUpdatesLighting = true
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
                anchor.addChildNode(buildPieceNode(piece: p))
            }
            anchor.enumerateChildNodes { node, _ in
                if let name = node.name, name.starts(with: "sq_") {
                    node.geometry?.firstMaterial?.emission.contents = UIColor.clear
                }
            }
            for m in gameManager.validMoves {
                if let sq = anchor.childNode(withName: "sq_\(m.col)_\(m.row)", recursively: true) {
                    sq.geometry?.firstMaterial?.emission.contents = UIColor.systemGreen.withAlphaComponent(0.45)
                }
            }
        }
    }
    
    private func buildPieceNode(piece: PieceModel) -> SCNNode {
        let root = SCNNode(); root.name = "piece_\(piece.id.uuidString)"
        let color = piece.side == .white ? UIColor.systemYellow : UIColor.systemCyan
        let mat = SCNMaterial(); mat.diffuse.contents = color; mat.metalness.contents = 0.8
        let cyl = SCNCylinder(radius: 0.3, height: 0.6); cyl.materials = [mat]
        let n = SCNNode(geometry: cyl)
        n.position = SCNVector3(Float(piece.col) - 3.5, 0.3, Float(piece.row) - 3.5)
        root.addChildNode(n)
        return root
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(gameManager: gameManager) }
    
    class Coordinator: NSObject {
        var gameManager: GameManager
        init(gameManager: GameManager) { self.gameManager = gameManager }
        
        func setupARTouch(on arView: ARSCNView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleARTap(_:)))
            arView.addGestureRecognizer(tap)
        }
        
        @objc func handleARTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = gesture.view as? ARSCNView else { return }
            let loc = gesture.location(in: arView)
            
            // Если доска еще не поставлена на стол — ставим ее по лучу в горизонтальную плоскость
            if gameManager.arBoardAnchorNode == nil {
                let query = arView.raycastQuery(from: loc, allowing: .estimatedPlane, alignment: .horizontal)
                if let q = query, let result = arView.session.raycast(q).first {
                    let anchorNode = SCNNode()
                    anchorNode.simdTransform = result.worldTransform
                    anchorNode.scale = SCNVector3(0.12, 0.12, 0.12) // Уменьшаем под размер стола
                    
                    // Доска
                    for r in 0..<8 {
                        for c in 0..<8 {
                            let box = SCNBox(width: 1.0, height: 0.1, length: 1.0, chamferRadius: 0.02)
                            let mat = SCNMaterial()
                            mat.diffuse.contents = (r + c) % 2 != 0 ? UIColor.darkGray : UIColor.white
                            box.materials = [mat]
                            let sq = SCNNode(geometry: box)
                            sq.name = "sq_\(c)_\(r)"
                            sq.position = SCNVector3(Float(c) - 3.5, 0, Float(r) - 3.5)
                            anchorNode.addChildNode(sq)
                        }
                    }
                    arView.scene.rootNode.addChildNode(anchorNode)
                    gameManager.arBoardAnchorNode = anchorNode
                    gameManager.statusText = "Доска установлена на столе! Делай ход!"
                    SoundEngine.shared.play("move")
                    return
                }
            }
            
            // Если доска уже стоит — стандартные ходы
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

// MARK: - Main Game UI
struct MainGameView: View {
    @StateObject private var gm = GameManager()
    @State private var showSaves: Bool = false
    
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
                // Главное меню
                ScrollView {
                    VStack(spacing: 16) {
                        Text("VIBE CHESS 3D")
                            .font(.system(size: 26, weight: .black, design: .monospaced))
                            .foregroundColor(.cyan)
                            .shadow(color: .cyan, radius: 8)
                        
                        Button(action: { showSaves = true }) {
                            HStack {
                                Image(systemName: "folder.fill")
                                Text("СОХРАНЕНИЯ (СЛОТЫ)")
                            }
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.yellow.opacity(0.15))
                            .cornerRadius(10)
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
                                Text("Золото").tag(Side.white)
                                Text("Циан").tag(Side.black)
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
                                .padding(.vertical, 13).background(Color.cyan).cornerRadius(12)
                        }
                    }
                    .padding(22)
                    .background(Color.black.opacity(0.88))
                    .cornerRadius(20)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.cyan.opacity(0.5), lineWidth: 1.5))
                    .padding(.horizontal, 22)
                    .padding(.top, 70)
                }
            } else {
                // Игровой HUD
                VStack {
                    HStack {
                        Button(action: { gm.inMenu = true }) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundColor(.white).padding(9).background(Color.black.opacity(0.75)).clipShape(Circle())
                        }
                        Spacer()
                        Text(gm.statusText)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(gm.isAlert ? .red : .cyan)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.black.opacity(0.8)).cornerRadius(10)
                        Spacer()
                        Button(action: { showSaves = true }) {
                            Image(systemName: "square.and.arrow.down")
                                .foregroundColor(.yellow).padding(9).background(Color.black.opacity(0.75)).clipShape(Circle())
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
            }
        }
        .sheet(isPresented: $showSaves) {
            SavesModalView(gm: gm)
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
                Section(header: Text("Сохранить текущую партию")) {
                    ForEach(1...3, id: \.self) { slotNum in
                        Button("Сохранить в Слот #\(slotNum)") {
                            gm.saveToSlot(slotId: "slot_\(slotNum)", title: "Слот #\(slotNum)")
                            dismiss()
                        }
                    }
                }
                
                Section(header: Text("Загрузить сохраненную партию")) {
                    if gm.saveSlots.isEmpty {
                        Text("Нет сохраненных партий").foregroundColor(.secondary)
                    } else {
                        ForEach(gm.saveSlots) { slot in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(slot.title).font(.headline)
                                    Text("Дата: \(slot.dateString) • Фигур: \(slot.pieces.count)")
                                        .font(.caption).foregroundColor(.secondary)
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
            .navigationTitle("Сохранения")
            .navigationBarItems(trailing: Button("Закрыть") { dismiss() })
        }
    }
}
