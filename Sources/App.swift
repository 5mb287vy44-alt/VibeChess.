import SwiftUI
import SceneKit
import AVFoundation
import AudioToolbox
import UIKit

// MARK: - Sound Engine
class SoundManager {
    static let shared = SoundManager()
    private var players: [String: AVAudioPlayer] = [:]
    private var bgPlayer: AVAudioPlayer?
    
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        loadSound(name: "move")
        loadSound(name: "capture")
        loadSound(name: "select")
        loadSound(name: "alarm")
        loadAmbient()
    }
    
    private func loadSound(name: String) {
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
            bgPlayer?.play()
        }
    }
    
    func play(_ name: String) {
        if let p = players[name] {
            p.currentTime = 0
            p.play()
        } else {
            // Резервный системный звук
            switch name {
            case "select": AudioServicesPlaySystemSound(1104)
            case "move": AudioServicesPlaySystemSound(1057)
            case "capture": AudioServicesPlaySystemSound(1073)
            case "alarm": AudioServicesPlaySystemSound(1053)
            default: break
            }
        }
    }
}

// MARK: - Chess Enums & Models
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
    
    weak var sceneView: SCNView?
    private let saveKey = "VibeChess_SavedState"
    
    init() {
        loadSavedGame()
    }
    
    func startNewGame(mode: GameMode, side: Side, diff: BotDifficulty) {
        self.mode = mode
        self.playerSide = side
        self.difficulty = diff
        self.currentTurn = .white
        self.inMenu = false
        self.cheatModeActive = false
        self.statusText = mode == .vsBot ? (side == .white ? "Твой ход (Золото)" : "Ход бота...") : "Ход Белых (Золото)"
        resetBoard()
        saveGame()
        
        if mode == .vsBot && currentTurn != playerSide {
            triggerBotMove()
        }
    }
    
    func resetBoard() {
        pieces.removeAll()
        // Белые (Золото) — ряды 0-1
        for c in 0..<8 { pieces.append(PieceModel(type: .pawn, side: .white, col: c, row: 1)) }
        let backWhite: [PieceType] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for c in 0..<8 { pieces.append(PieceModel(type: backWhite[c], side: .white, col: c, row: 0)) }
        
        // Черные (Циан) — ряды 6-7
        for c in 0..<8 { pieces.append(PieceModel(type: .pawn, side: .black, col: c, row: 6)) }
        let backBlack: [PieceType] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for c in 0..<8 { pieces.append(PieceModel(type: backBlack[c], side: .black, col: c, row: 7)) }
    }
    
    func selectPiece(_ piece: PieceModel) {
        // Можно выбирать только фигуры стороны, чей сейчас ход
        guard piece.side == currentTurn else { return }
        if mode == .vsBot && currentTurn != playerSide { return }
        
        selectedPiece = piece
        SoundManager.shared.play("select")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        
        if cheatModeActive {
            // В режиме шулера доступны абсолютно все клетки
            var allSquares: [(col: Int, row: Int)] = []
            for c in 0..<8 {
                for r in 0..<8 {
                    if !(c == piece.col && r == piece.row) { allSquares.append((c, r)) }
                }
            }
            validMoves = allSquares
        } else {
            validMoves = calculateLegalMoves(for: piece)
        }
    }
    
    func calculateLegalMoves(for piece: PieceModel) -> [(col: Int, row: Int)] {
        var moves: [(col: Int, row: Int)] = []
        for c in 0..<8 {
            for r in 0..<8 {
                if isPathClearAndValid(piece: piece, toCol: c, toRow: r) {
                    moves.append((c, r))
                }
            }
        }
        return moves
    }
    
    // Полноценная проверка препятствий на пути
    func isPathClearAndValid(piece: PieceModel, toCol: Int, toRow: Int) -> Bool {
        if piece.col == toCol && piece.row == toRow { return false }
        let targetOccupant = pieces.first { $0.col == toCol && $0.row == toRow }
        if let occ = targetOccupant, occ.side == piece.side { return false }
        
        let dx = toCol - piece.col
        let dy = toRow - piece.row
        let stepX = dx == 0 ? 0 : (dx > 0 ? 1 : -1)
        let stepY = dy == 0 ? 0 : (dy > 0 ? 1 : -1)
        
        switch piece.type {
        case .pawn:
            let dir = piece.side == .white ? 1 : -1
            let startRow = piece.side == .white ? 1 : 6
            if dx == 0 && dy == dir && targetOccupant == nil { return true }
            if dx == 0 && dy == dir * 2 && piece.row == startRow && targetOccupant == nil {
                let mid = pieces.first { $0.col == piece.col && $0.row == piece.row + dir }
                return mid == nil
            }
            if abs(dx) == 1 && dy == dir && targetOccupant != nil && targetOccupant?.side != piece.side { return true }
            return false
            
        case .knight:
            return (abs(dx) == 1 && abs(dy) == 2) || (abs(dx) == 2 && abs(dy) == 1)
            
        case .rook:
            if dx != 0 && dy != 0 { return false }
            return checkLineClear(fromCol: piece.col, fromRow: piece.row, toCol: toCol, toRow: toRow, stepX: stepX, stepY: stepY)
            
        case .bishop:
            if abs(dx) != abs(dy) { return false }
            return checkLineClear(fromCol: piece.col, fromRow: piece.row, toCol: toCol, toRow: toRow, stepX: stepX, stepY: stepY)
            
        case .queen:
            if (dx != 0 && dy != 0) && (abs(dx) != abs(dy)) { return false }
            return checkLineClear(fromCol: piece.col, fromRow: piece.row, toCol: toCol, toRow: toRow, stepX: stepX, stepY: stepY)
            
        case .king:
            return abs(dx) <= 1 && abs(dy) <= 1
        }
    }
    
    private func checkLineClear(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int, stepX: Int, stepY: Int) -> Bool {
        var currX = fromCol + stepX
        var currY = fromRow + stepY
        while currX != toCol || currY != toRow {
            if pieces.contains(where: { $0.col == currX && $0.row == currY }) { return false }
            currX += stepX
            currY += stepY
        }
        return true
    }
    
    func executeMove(toCol: Int, toRow: Int) {
        guard let p = selectedPiece, let idx = pieces.firstIndex(where: { $0.id == p.id }) else { return }
        
        // Проверка жульничества
        if cheatModeActive {
            let isLegal = calculateLegalMoves(for: p).contains { $0.col == toCol && $0.row == toRow }
            if !isLegal && Int.random(in: 1...100) <= 50 {
                // СПАЛИЛСЯ!
                SoundManager.shared.play("alarm")
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
            }
        }
        
        // Проверяем захват фигуры
        if let targetIdx = pieces.firstIndex(where: { $0.col == toCol && $0.row == toRow && $0.side != p.side }) {
            let captured = pieces[targetIdx]
            pieces.remove(at: targetIdx)
            SoundManager.shared.play("capture")
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            launchPhysicsBlast(for: captured.id)
        } else {
            SoundManager.shared.play("move")
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        
        pieces[idx].col = toCol
        pieces[idx].row = toRow
        selectedPiece = nil
        validMoves = []
        cheatModeActive = false
        
        // Смена хода
        currentTurn = (currentTurn == .white) ? .black : .white
        saveGame()
        
        if mode == .vsBot {
            if currentTurn == playerSide {
                statusText = "Твой ход!"
            } else {
                statusText = "Космический бот думает..."
                triggerBotMove()
            }
        } else {
            statusText = currentTurn == .white ? "Ход Белых (Золото)" : "Ход Черных (Циан)"
        }
    }
    
    // Физический выброс сбитой фигуры в космос
    private func launchPhysicsBlast(for pieceId: UUID) {
        guard let scene = sceneView?.scene,
              let node = scene.rootNode.childNode(withName: "piece_\(pieceId.uuidString)", recursively: true) else { return }
        
        let body = SCNPhysicsBody(type: .dynamic, shape: nil)
        body.mass = 1.5
        body.isAffectedByGravity = false
        node.physicsBody = body
        
        let blastX = Float.random(in: -8...8)
        let blastY = Float.random(in: 6...14)
        let blastZ = Float.random(in: -8...8)
        body.applyForce(SCNVector3(blastX, blastY, blastZ), asImpulse: true)
        body.applyTorque(SCNVector4(1, 0, 1, 10), asImpulse: true)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            node.removeFromParentNode()
        }
    }
    
    // Логика бота (Minimax + оценка позиции)
    func triggerBotMove() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
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
                    if self.difficulty == .hard {
                        score += (8 - abs(3 - m.col) - abs(3 - m.row)) // Борьба за центр
                    }
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
            } else {
                self.statusText = "Мат! Победил игрок!"
            }
        }
    }
    
    // Сохранение и загрузка
    private func saveGame() {
        if let data = try? JSONEncoder().encode(pieces) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }
    
    private func loadSavedGame() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let saved = try? JSONDecoder().decode([PieceModel].self, from: data), !saved.isEmpty {
            self.pieces = saved
        }
    }
}

// MARK: - SceneKit 3D View
struct Chess3DContainer: UIViewRepresentable {
    @ObservedObject var gameManager: GameManager
    
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = UIColor(red: 0.01, green: 0.01, blue: 0.03, alpha: 1.0)
        view.antialiasingMode = .multisampling4X
        gameManager.sceneView = view
        
        // 150 космических звезд
        let starsNode = SCNNode()
        for _ in 0..<150 {
            let star = SCNSphere(radius: 0.03)
            let m = SCNMaterial()
            m.emission.contents = UIColor.white
            star.materials = [m]
            let n = SCNNode(geometry: star)
            n.position = SCNVector3(Float.random(in: -30...30), Float.random(in: -15...30), Float.random(in: -30...30))
            starsNode.addChildNode(n)
        }
        scene.rootNode.addChildNode(starsNode)
        
        // Камера
        let orbit = SCNNode()
        orbit.name = "orbitNode"
        let cameraNode = SCNNode()
        let cam = SCNCamera()
        cam.bloomIntensity = 1.4
        cam.bloomThreshold = 0.5
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 11, 9.5)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        orbit.addChildNode(cameraNode)
        scene.rootNode.addChildNode(orbit)
        view.pointOfView = cameraNode
        
        // Свет
        let sun = SCNLight()
        sun.type = .directional
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowSampleCount = 16
        sun.shadowColor = UIColor.black.withAlphaComponent(0.85)
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.position = SCNVector3(7, 16, 7)
        sunNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(sunNode)
        
        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 260
        let ambNode = SCNNode()
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)
        
        // Доска 8x8 с физической поверхностью
        let board = SCNNode()
        board.name = "boardNode"
        for r in 0..<8 {
            for c in 0..<8 {
                let box = SCNBox(width: 1.0, height: 0.15, length: 1.0, chamferRadius: 0.02)
                let mat = SCNMaterial()
                mat.lightingModel = .physicallyBased
                if (r + c) % 2 != 0 {
                    mat.diffuse.contents = UIColor(white: 0.07, alpha: 1)
                    mat.metalness.contents = 0.95
                    mat.roughness.contents = 0.05
                } else {
                    mat.diffuse.contents = UIColor(white: 0.88, alpha: 1)
                    mat.metalness.contents = 0.1
                    mat.roughness.contents = 0.65
                }
                box.materials = [mat]
                let sqNode = SCNNode(geometry: box)
                sqNode.name = "sq_\(c)_\(r)"
                sqNode.position = SCNVector3(Float(c) - 3.5, 0, Float(r) - 3.5)
                sqNode.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
                board.addChildNode(sqNode)
            }
        }
        scene.rootNode.addChildNode(board)
        
        context.coordinator.setupTouch(on: view)
        return view
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let scene = uiView.scene else { return }
        
        // Очищаем старые фигуры (кроме тех, что улетают в космос)
        scene.rootNode.enumerateChildNodes { node, _ in
            if let name = node.name, name.starts(with: "piece_"), node.physicsBody == nil {
                node.removeFromParentNode()
            }
        }
        
        // Рисуем актуальные фигуры
        for p in gameManager.pieces {
            let pNode = buildPieceNode(piece: p)
            scene.rootNode.addChildNode(pNode)
        }
        
        // Подсветка клеток и выбранной фигуры
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
    
    private func buildPieceNode(piece: PieceModel) -> SCNNode {
        let root = SCNNode()
        root.name = "piece_\(piece.id.uuidString)"
        
        let color = piece.side == .white ?
            UIColor(red: 1.0, green: 0.72, blue: 0.18, alpha: 1.0) :
            UIColor(red: 0.1, green: 0.82, blue: 1.0, alpha: 1.0)
        
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.black
        mat.emission.contents = color
        mat.metalness.contents = 0.85
        mat.roughness.contents = 0.15
        
        let isSel = gameManager.selectedPiece?.id == piece.id
        let baseHeight: Float = isSel ? 0.45 : 0.05
        
        let base = SCNCylinder(radius: 0.35, height: 0.15)
        base.materials = [mat]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(0, 0.075, 0)
        root.addChildNode(baseNode)
        
        switch piece.type {
        case .pawn:
            let body = SCNCone(topRadius: 0.14, bottomRadius: 0.28, height: 0.45)
            body.materials = [mat]
            let bNode = SCNNode(geometry: body)
            bNode.position = SCNVector3(0, 0.35, 0)
            let head = SCNSphere(radius: 0.16)
            head.materials = [mat]
            let hNode = SCNNode(geometry: head)
            hNode.position = SCNVector3(0, 0.65, 0)
            root.addChildNode(bNode); root.addChildNode(hNode)
        case .rook:
            let tower = SCNCylinder(radius: 0.3, height: 0.65)
            tower.materials = [mat]
            let tNode = SCNNode(geometry: tower)
            tNode.position = SCNVector3(0, 0.45, 0)
            let crown = SCNBox(width: 0.55, height: 0.15, length: 0.55, chamferRadius: 0.02)
            crown.materials = [mat]
            let cNode = SCNNode(geometry: crown)
            cNode.position = SCNVector3(0, 0.8, 0)
            root.addChildNode(tNode); root.addChildNode(cNode)
        case .knight:
            let body = SCNCylinder(radius: 0.25, height: 0.4)
            body.materials = [mat]
            let bNode = SCNNode(geometry: body)
            bNode.position = SCNVector3(0, 0.35, 0)
            let head = SCNBox(width: 0.25, height: 0.4, length: 0.42, chamferRadius: 0.05)
            head.materials = [mat]
            let hNode = SCNNode(geometry: head)
            hNode.position = SCNVector3(0, 0.68, 0.1)
            hNode.eulerAngles.x = 0.3
            root.addChildNode(bNode); root.addChildNode(hNode)
        case .bishop:
            let body = SCNCone(topRadius: 0.12, bottomRadius: 0.26, height: 0.6)
            body.materials = [mat]
            let bNode = SCNNode(geometry: body)
            bNode.position = SCNVector3(0, 0.45, 0)
            let tip = SCNSphere(radius: 0.14)
            tip.materials = [mat]
            let tNode = SCNNode(geometry: tip)
            tNode.position = SCNVector3(0, 0.8, 0)
            root.addChildNode(bNode); root.addChildNode(tNode)
        case .queen:
            let body = SCNCone(topRadius: 0.2, bottomRadius: 0.3, height: 0.8)
            body.materials = [mat]
            let bNode = SCNNode(geometry: body)
            bNode.position = SCNVector3(0, 0.55, 0)
            let crown = SCNTorus(ringRadius: 0.22, pipeRadius: 0.06)
            crown.materials = [mat]
            let cNode = SCNNode(geometry: crown)
            cNode.position = SCNVector3(0, 0.98, 0)
            root.addChildNode(bNode); root.addChildNode(cNode)
        case .king:
            let body = SCNCylinder(radius: 0.3, height: 0.85)
            body.materials = [mat]
            let bNode = SCNNode(geometry: body)
            bNode.position = SCNVector3(0, 0.58, 0)
            let crossV = SCNBox(width: 0.08, height: 0.25, length: 0.08, chamferRadius: 0.01)
            crossV.materials = [mat]
            let vNode = SCNNode(geometry: crossV)
            vNode.position = SCNVector3(0, 1.12, 0)
            let crossH = SCNBox(width: 0.22, height: 0.08, length: 0.08, chamferRadius: 0.01)
            crossH.materials = [mat]
            let hNode = SCNNode(geometry: crossH)
            hNode.position = SCNVector3(0, 1.15, 0)
            root.addChildNode(bNode); root.addChildNode(vNode); root.addChildNode(hNode)
        }
        
        root.position = SCNVector3(Float(piece.col) - 3.5, baseHeight, Float(piece.row) - 3.5)
        return root
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(gameManager: gameManager)
    }
    
    class Coordinator: NSObject {
        var gameManager: GameManager
        
        init(gameManager: GameManager) {
            self.gameManager = gameManager
        }
        
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
            
            // Нажали на фигуру
            if let hit = hits.first(where: { $0.node.name?.starts(with: "piece_") == true || $0.node.parent?.name?.starts(with: "piece_") == true }) {
                let pNode = hit.node.name?.starts(with: "piece_") == true ? hit.node : hit.node.parent!
                let uuidStr = String(pNode.name!.dropFirst(6))
                
                if let piece = gameManager.pieces.first(where: { $0.id.uuidString == uuidStr }) {
                    if piece.side == gameManager.currentTurn {
                        gameManager.selectPiece(piece)
                        return
                    } else if gameManager.selectedPiece != nil && gameManager.validMoves.contains(where: { $0.col == piece.col && $0.row == piece.row }) {
                        // Взятие фигуры противника
                        gameManager.executeMove(toCol: piece.col, toRow: piece.row)
                        return
                    }
                }
            }
            
            // Нажали на клетку доски
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

// MARK: - Main UI View
struct MainGameView: View {
    @StateObject private var gm = GameManager()
    
    var body: some View {
        ZStack {
            Chess3DContainer(gameManager: gm)
                .ignoresSafeArea()
            
            if gm.inMenu {
                // Меню выбора режимов
                ScrollView {
                    VStack(spacing: 20) {
                        Text("VIBE CHESS 3D")
                            .font(.system(size: 28, weight: .black, design: .monospaced))
                            .foregroundColor(.cyan)
                            .shadow(color: .cyan, radius: 8)
                        
                        // Выбор режима
                        VStack(alignment: .leading, spacing: 8) {
                            Text("РЕЖИМ ИГРЫ:")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                            Picker("", selection: $gm.mode) {
                                ForEach(GameMode.allCases) { m in Text(m.rawValue).tag(m) }
                            }
                            .pickerStyle(.segmented)
                        }
                        
                        // Выбор стороны
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ИГРАТЬ ЗА:")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                            Picker("", selection: $gm.playerSide) {
                                Text("Золото (Белые)").tag(Side.white)
                                Text("Циан (Черные)").tag(Side.black)
                            }
                            .pickerStyle(.segmented)
                        }
                        
                        // Выбор сложности (если с ботом)
                        if gm.mode == .vsBot {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("СЛОЖНОСТЬ БОТА:")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                                Picker("", selection: $gm.difficulty) {
                                    ForEach(BotDifficulty.allCases) { d in Text(d.rawValue).tag(d) }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        
                        // Кнопки запуска
                        Button(action: {
                            gm.startNewGame(mode: gm.mode, side: gm.playerSide, diff: gm.difficulty)
                        }) {
                            Text("НАЧАТЬ НОВУЮ ПАРТИЮ")
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.cyan)
                                .cornerRadius(12)
                        }
                        
                        if !gm.pieces.isEmpty {
                            Button(action: { gm.inMenu = false }) {
                                Text("ПРОДОЛЖИТЬ ИГРУ")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.white.opacity(0.15))
                                    .cornerRadius(12)
                            }
                        }
                    }
                    .padding(24)
                    .background(Color.black.opacity(0.88))
                    .cornerRadius(20)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.cyan.opacity(0.5), lineWidth: 1.5))
                    .padding(.horizontal, 24)
                    .padding(.top, 80)
                }
            } else {
                // Игровой интерфейс
                VStack {
                    HStack {
                        Button(action: { gm.inMenu = true }) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.75))
                                .clipShape(Circle())
                        }
                        
                        Spacer()
                        
                        Text(gm.statusText)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(gm.isAlert ? .red : .cyan)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(gm.isAlert ? Color.red : Color.cyan.opacity(0.4), lineWidth: 1))
                        
                        Spacer()
                        
                        // Сброс камеры
                        Button(action: { resetCamera() }) {
                            Image(systemName: "camera.metering.center.weighted")
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.75))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 45)
                    
                    Spacer()
                    
                    // Кнопка жульничества
                    HStack {
                        Button(action: {
                            gm.cheatModeActive.toggle()
                            if gm.cheatModeActive {
                                gm.statusText = "⚠️ РЕЖИМ ШУЛЕРА! ХОДИ КУДА ХОЧЕШЬ!"
                                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            } else {
                                gm.statusText = "Честный режим"
                            }
                        }) {
                            HStack {
                                Image(systemName: gm.cheatModeActive ? "exclamationmark.shield.fill" : "shield")
                                Text(gm.cheatModeActive ? "ШУЛЕР (АКТИВЕН)" : "Сжульничать")
                            }
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(gm.cheatModeActive ? .black : .red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(gm.cheatModeActive ? Color.red : Color.black.opacity(0.75))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.6), lineWidth: 1.5))
                        }
                        
                        Spacer()
                        
                        Text("Тапни фигуру ➔ Тапни клетку")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 25)
                }
            }
        }
    }
    
    private func resetCamera() {
        if let orbit = gm.sceneView?.scene?.rootNode.childNode(withName: "orbitNode", recursively: true) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            orbit.eulerAngles = SCNVector3Zero
            SCNTransaction.commit()
        }
    }
}
