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

// MARK: - Advanced Audio Engine (Plays even in Silent Mode!)
class SoundEngine: NSObject {
    static let shared = SoundEngine()
    private var players: [String: AVAudioPlayer] = [:]
    private var bgPlayer: AVAudioPlayer?
    private let speechSynth = AVSpeechSynthesizer()
    
    override init() {
        super.init()
        setupAudioSession()
        loadSound("move")
        loadSound("capture")
        loadSound("select")
        loadSound("alarm")
        loadSound("laser")
        loadAmbient()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
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
            p.volume = 1.0
            p.play()
        } else {
            // Резервный системный щелчок
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
        utterance.pitchMultiplier = 0.85 // Низкий голос киборга
        speechSynth.speak(utterance)
    }
}

// MARK: - Themes & Shop
enum BoardTheme: String, CaseIterable, Identifiable {
    case cosmic = "Cosmic Void"
    case cyberpunk = "Cyberpunk 2077"
    case iceAndFire = "Лед и Пламя"
    case royalGold = "Royal Gold"
    
    var id: String { rawValue }
    var price: Int {
        switch self {
        case .cosmic: return 0
        case .cyberpunk: return 100
        case .iceAndFire: return 200
        case .royalGold: return 350
        }
    }
    
    var whiteColor: UIColor {
        switch self {
        case .cosmic: return UIColor(red: 1.0, green: 0.75, blue: 0.2, alpha: 1.0)
        case .cyberpunk: return UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0)
        case .iceAndFire: return UIColor(red: 0.2, green: 0.9, blue: 1.0, alpha: 1.0)
        case .royalGold: return UIColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 1.0)
        }
    }
    
    var blackColor: UIColor {
        switch self {
        case .cosmic: return UIColor(red: 0.1, green: 0.8, blue: 1.0, alpha: 1.0)
        case .cyberpunk: return UIColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 1.0)
        case .iceAndFire: return UIColor(red: 1.0, green: 0.25, blue: 0.05, alpha: 1.0)
        case .royalGold: return UIColor(white: 0.1, alpha: 1.0)
        }
    }
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

enum GameMode: String, CaseIterable, Identifiable {
    case vsBot = "1 Игрок (vs Бот)"
    case passAndPlay = "2 Игрока (Вдвоем)"
    var id: String { rawValue }
}

enum BotDifficulty: String, CaseIterable, Identifiable {
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
    
    // История для отката ходов (Undo)
    private var moveHistory: [[PieceModel]] = []
    @Published var undoCount: Int = 3
    @Published var teleportCount: Int = 1
    
    // Экономика и Настройки
    @Published var credits: Int = 150
    @Published var currentTheme: BoardTheme = .cosmic
    @Published var unlockedThemes: [String] = [BoardTheme.cosmic.rawValue]
    
    @Published var sfxEnabled: Bool = true
    @Published var voiceEnabled: Bool = true
    @Published var vfxEnabled: Bool = true
    
    weak var sceneView: SCNView?
    private let saveKey = "VibeChess_SavedState"
    
    init() {
        loadData()
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
        self.teleportCount = 1
        self.statusText = mode == .vsBot ? (side == .white ? "Твой ход (Золото)" : "Ход бота...") : "Ход Белых"
        resetBoard()
        moveHistory = [pieces]
        saveData()
        
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
    
    // Перк 1: Откат хода (Undo)
    func performUndo() {
        guard undoCount > 0, moveHistory.count > 1 else { return }
        moveHistory.removeLast()
        if let previousState = moveHistory.last {
            pieces = previousState
            undoCount -= 1
            currentTurn = playerSide
            selectedPiece = nil
            validMoves = []
            statusText = "Ход отменен! Осталось откатов: \(undoCount)"
            SoundEngine.shared.play("select", enabled: sfxEnabled)
            SoundEngine.shared.speak("Квантовый откат выполнен.", enabled: voiceEnabled)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
    
    // Перк 2: Заморозка ИИ
    func freezeOpponent() {
        SoundEngine.shared.speak("Система соперника заморожена.", enabled: voiceEnabled)
        SoundEngine.shared.play("laser", enabled: sfxEnabled)
        statusText = "ИИ заморожен! Ходи снова!"
        currentTurn = playerSide
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
                SoundEngine.shared.speak("Внимание! Обнаружен саботаж!", enabled: voiceEnabled)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                statusText = "🚨 СПАЛИЛСЯ НА ЖУЛЬНИЧЕСТВЕ! ХОД ОТМЕНЕН!"
                isAlert = true
                selectedPiece = nil
                validMoves = []
                cheatModeActive = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.statusText = "Игра продолжается..."
                    self.isAlert = false
                }
                return
            } else if !isLegal {
                credits += 25 // Награда за дерзкое жульничество
            }
        }
        
        // Взятие фигуры противника
        if let targetIdx = pieces.firstIndex(where: { $0.col == toCol && $0.row == toRow && $0.side != p.side }) {
            let captured = pieces[targetIdx]
            pieces.remove(at: targetIdx)
            SoundEngine.shared.play("capture", enabled: sfxEnabled)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            
            if vfxEnabled {
                triggerLaserAndExplosion(atCol: toCol, atRow: toRow, targetId: captured.id)
            } else {
                launchPhysicsBlast(for: captured.id)
            }
            credits += 10
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
        saveData()
        
        if mode == .vsBot {
            if currentTurn == playerSide {
                statusText = "Твой ход!"
            } else {
                statusText = "Космический бот думает..."
                triggerBotMove()
            }
        } else {
            statusText = currentTurn == .white ? "Ход Белых" : "Ход Черных"
        }
    }
    
    // Эффект удара орбитального лазера и распада
    private func triggerLaserAndExplosion(atCol: Int, atRow: Int, targetId: UUID) {
        guard let scene = sceneView?.scene else { return }
        SoundEngine.shared.play("laser", enabled: sfxEnabled)
        
        // Луч лазера
        let laser = SCNCylinder(radius: 0.08, height: 25.0)
        let lMat = SCNMaterial()
        lMat.diffuse.contents = UIColor.clear
        lMat.emission.contents = UIColor.cyan
        laser.materials = [lMat]
        let laserNode = SCNNode(geometry: laser)
        laserNode.position = SCNVector3(Float(atCol) - 3.5, 12.5, Float(atRow) - 3.5)
        scene.rootNode.addChildNode(laserNode)
        
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.4
        laserNode.opacity = 0.0
        SCNTransaction.commit()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            laserNode.removeFromParentNode()
            self.launchPhysicsBlast(for: targetId)
        }
    }
    
    private func launchPhysicsBlast(for pieceId: UUID) {
        guard let scene = sceneView?.scene,
              let node = scene.rootNode.childNode(withName: "piece_\(pieceId.uuidString)", recursively: true) else { return }
        let body = SCNPhysicsBody(type: .dynamic, shape: nil)
        body.mass = 1.5
        body.isAffectedByGravity = false
        node.physicsBody = body
        body.applyForce(SCNVector3(Float.random(in: -8...8), Float.random(in: 8...14), Float.random(in: -8...8)), asImpulse: true)
        body.applyTorque(SCNVector4(1, 0, 1, 10), asImpulse: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { node.removeFromParentNode() }
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
    
    func buyTheme(_ theme: BoardTheme) {
        if credits >= theme.price && !unlockedThemes.contains(theme.rawValue) {
            credits -= theme.price
            unlockedThemes.append(theme.rawValue)
            currentTheme = theme
            saveData()
            SoundEngine.shared.play("select", enabled: sfxEnabled)
        }
    }
    
    private func saveData() {
        if let data = try? JSONEncoder().encode(pieces) { UserDefaults.standard.set(data, forKey: saveKey) }
        UserDefaults.standard.set(credits, forKey: "Vibe_Credits")
        UserDefaults.standard.set(unlockedThemes, forKey: "Vibe_UnlockedThemes")
        UserDefaults.standard.set(currentTheme.rawValue, forKey: "Vibe_CurrentTheme")
    }
    
    private func loadData() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let saved = try? JSONDecoder().decode([PieceModel].self, from: data) { self.pieces = saved }
        credits = UserDefaults.standard.integer(forKey: "Vibe_Credits")
        if credits == 0 { credits = 150 } // Стартовый капитал
        if let th = UserDefaults.standard.stringArray(forKey: "Vibe_UnlockedThemes") { unlockedThemes = th }
        if let cur = UserDefaults.standard.string(forKey: "Vibe_CurrentTheme"), let ct = BoardTheme(rawValue: cur) { currentTheme = ct }
    }
}

// MARK: - SceneKit Container (Supports 3D and AR!)
struct Chess3DContainer: UIViewRepresentable {
    @ObservedObject var gameManager: GameManager
    
    func makeUIView(context: Context) -> SCNView {
        if gameManager.isARMode && ARWorldTrackingConfiguration.isSupported {
            let arView = ARSCNView()
            let scene = SCNScene()
            arView.scene = scene
            arView.autoenablesDefaultLighting = true
            gameManager.sceneView = arView
            
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]
            arView.session.run(config)
            
            setupBoard(in: scene, theme: gameManager.currentTheme)
            context.coordinator.setupTouch(on: arView)
            return arView
        } else {
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
            
            // Камера и орбита
            let orbit = SCNNode(); orbit.name = "orbitNode"
            let camNode = SCNNode(); let cam = SCNCamera()
            cam.bloomIntensity = 1.3; cam.bloomThreshold = 0.5
            camNode.camera = cam; camNode.position = SCNVector3(0, 11, 9.5)
            camNode.look(at: SCNVector3(0, 0, 0))
            orbit.addChildNode(camNode)
            scene.rootNode.addChildNode(orbit)
            view.pointOfView = camNode
            
            // Освещение
            let sun = SCNLight(); sun.type = .directional; sun.castsShadow = true
            sun.shadowMode = .deferred; sun.shadowSampleCount = 16
            let sunNode = SCNNode(); sunNode.light = sun; sunNode.position = SCNVector3(7, 16, 7)
            sunNode.look(at: SCNVector3Zero)
            scene.rootNode.addChildNode(sunNode)
            
            let amb = SCNLight(); amb.type = .ambient; amb.intensity = 260
            let ambNode = SCNNode(); ambNode.light = amb
            scene.rootNode.addChildNode(ambNode)
            
            setupBoard(in: scene, theme: gameManager.currentTheme)
            context.coordinator.setupTouch(on: view)
            return view
        }
    }
    
    private func setupBoard(in scene: SCNScene, theme: BoardTheme) {
        let board = SCNNode(); board.name = "boardNode"
        for r in 0..<8 {
            for c in 0..<8 {
                let box = SCNBox(width: 1.0, height: 0.15, length: 1.0, chamferRadius: 0.02)
                let mat = SCNMaterial(); mat.lightingModel = .physicallyBased
                if (r + c) % 2 != 0 {
                    mat.diffuse.contents = UIColor(white: 0.08, alpha: 1)
                    mat.metalness.contents = 0.95; mat.roughness.contents = 0.05
                } else {
                    mat.diffuse.contents = UIColor(white: 0.88, alpha: 1)
                    mat.metalness.contents = 0.1; mat.roughness.contents = 0.65
                }
                box.materials = [mat]
                let sq = SCNNode(geometry: box)
                sq.name = "sq_\(c)_\(r)"
                sq.position = SCNVector3(Float(c) - 3.5, 0, Float(r) - 3.5)
                sq.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
                board.addChildNode(sq)
            }
        }
        scene.rootNode.addChildNode(board)
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let scene = uiView.scene else { return }
        
        scene.rootNode.enumerateChildNodes { node, _ in
            if let name = node.name, name.starts(with: "piece_"), node.physicsBody == nil {
                node.removeFromParentNode()
            }
        }
        for p in gameManager.pieces {
            scene.rootNode.addChildNode(buildPieceNode(piece: p, theme: gameManager.currentTheme))
        }
        
        scene.rootNode.enumerateChildNodes { node, _ in
            if let name = node.name, name.starts(with: "sq_") {
                node.geometry?.firstMaterial?.emission.contents = UIColor.clear
            }
        }
        for m in gameManager.validMoves {
            if let sq = scene.rootNode.childNode(withName: "sq_\(m.col)_\(m.row)", recursively: true) {
                sq.geometry?.firstMaterial?.emission.contents = UIColor.systemGreen.withAlphaComponent(0.45)
            }
        }
    }
    
    private func buildPieceNode(piece: PieceModel, theme: BoardTheme) -> SCNNode {
        let root = SCNNode()
        root.name = "piece_\(piece.id.uuidString)"
        let color = piece.side == .white ? theme.whiteColor : theme.blackColor
        
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

// MARK: - Main UI, Settings & Shop
struct MainGameView: View {
    @StateObject private var gm = GameManager()
    @State private var showSettings: Bool = false
    @State private var showShop: Bool = false
    
    var body: some View {
        ZStack {
            Chess3DContainer(gameManager: gm)
                .ignoresSafeArea()
            
            if gm.inMenu {
                // Главное меню
                ScrollView {
                    VStack(spacing: 18) {
                        Text("VIBE CHESS 3D")
                            .font(.system(size: 26, weight: .black, design: .monospaced))
                            .foregroundColor(.cyan)
                            .shadow(color: .cyan, radius: 8)
                        
                        HStack {
                            Label("\(gm.credits) КР", systemImage: "bitcoinsign.circle.fill")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow)
                            Spacer()
                            Button("МАГАЗИН") { showShop = true }
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                            Button("НАСТРОЙКИ") { showSettings = true }
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("РЕЖИМ:")
                                .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                            Picker("", selection: $gm.mode) {
                                ForEach(GameMode.allCases) { m in Text(m.rawValue).tag(m) }
                            }.pickerStyle(.segmented)
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("СТОРОНА:")
                                .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                            Picker("", selection: $gm.playerSide) {
                                Text("Золото").tag(Side.white)
                                Text("Циан").tag(Side.black)
                            }.pickerStyle(.segmented)
                        }
                        
                        if gm.mode == .vsBot {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("СЛОЖНОСТЬ:")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                                Picker("", selection: $gm.difficulty) {
                                    ForEach(BotDifficulty.allCases) { d in Text(d.rawValue).tag(d) }
                                }.pickerStyle(.segmented)
                            }
                        }
                        
                        // Кнопка переключения в AR
                        Toggle(isOn: $gm.isARMode) {
                            Label("AR-Режим (на столе)", systemImage: "camera.viewfinder")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                        }
                        .padding(.vertical, 4)
                        
                        Button(action: {
                            gm.startNewGame(mode: gm.mode, side: gm.playerSide, diff: gm.difficulty)
                        }) {
                            Text("НАЧАТЬ ПАРТИЮ")
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundColor(.black).frame(maxWidth: .infinity)
                                .padding(.vertical, 13).background(Color.cyan).cornerRadius(12)
                        }
                        
                        // AirDrop / Поделиться
                        Button(action: { shareApp() }) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("AirDrop / Поделиться игрой")
                            }
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding(22)
                    .background(Color.black.opacity(0.88))
                    .cornerRadius(20)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.cyan.opacity(0.5), lineWidth: 1.5))
                    .padding(.horizontal, 20)
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
                        Button(action: { gm.performUndo() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.uturn.backward")
                                Text("\(gm.undoCount)")
                            }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow).padding(8).background(Color.black.opacity(0.75)).cornerRadius(10)
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 45)
                    
                    Spacer()
                    
                    // Панель перков шулера
                    HStack(spacing: 10) {
                        Button(action: { gm.cheatModeActive.toggle() }) {
                            Text(gm.cheatModeActive ? "ШУЛЕР ⚠️" : "Сжульничать")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(gm.cheatModeActive ? .black : .red)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(gm.cheatModeActive ? Color.red : Color.black.opacity(0.75))
                                .cornerRadius(10)
                        }
                        
                        Button(action: { gm.freezeOpponent() }) {
                            Text("❄️ Заморозка ИИ")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan).padding(.horizontal, 10).padding(.vertical, 8)
                                .background(Color.black.opacity(0.75)).cornerRadius(10)
                        }
                    }
                    .padding(.bottom, 25)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(gm: gm)
        }
        .sheet(isPresented: $showShop) {
            ShopView(gm: gm)
        }
    }
    
    private func shareApp() {
        let text = "🚀 Зацени мои 3D-шахматы с ИИ и шулерством! Скачивай тут: https://github.com/5mb287vy44-alt/VibeChess./releases"
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
    }
}

// MARK: - Settings Modal
struct SettingsView: View {
    @ObservedObject var gm: GameManager
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Аудио")) {
                    Toggle("Звуковые эффекты", isOn: $gm.sfxEnabled)
                    Toggle("Голос робота-комментатора", isOn: $gm.voiceEnabled)
                }
                Section(header: Text("Графика")) {
                    Toggle("Лазерные лучи и VFX", isOn: $gm.vfxEnabled)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarItems(trailing: Button("Готово") { dismiss() })
        }
    }
}

// MARK: - Shop Modal
struct ShopView: View {
    @ObservedObject var gm: GameManager
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            List(BoardTheme.allCases) { theme in
                HStack {
                    VStack(alignment: .leading) {
                        Text(theme.rawValue).font(.headline)
                        Text(gm.unlockedThemes.contains(theme.rawValue) ? "Куплено" : "Цена: \(theme.price) КР")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if gm.currentTheme == theme {
                        Text("АКТИВЕН").font(.caption).bold().foregroundColor(.green)
                    } else if gm.unlockedThemes.contains(theme.rawValue) {
                        Button("Выбрать") { gm.currentTheme = theme }
                    } else {
                        Button("Купить") { gm.buyTheme(theme) }
                            .disabled(gm.credits < theme.price)
                    }
                }
            }
            .navigationTitle("Магазин Скинов (\(gm.credits) КР)")
            .navigationBarItems(trailing: Button("Закрыть") { dismiss() })
        }
    }
}
