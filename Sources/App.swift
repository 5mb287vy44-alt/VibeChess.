import SwiftUI
import SceneKit
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

// MARK: - Chess Logic & Bot Types
enum PieceKind { case pawn, rook, knight, bishop, queen, king }
enum PieceSide { case player, bot }

struct ChessPieceData: Equatable {
    var id: UUID = UUID()
    var kind: PieceKind
    var side: PieceSide
    var col: Int
    var row: Int
}

enum BotDifficulty: String, CaseIterable, Identifiable {
    case easy = "Новичок"
    case medium = "Любитель"
    case hard = "Гроссмейстер"
    var id: String { rawValue }
}

// MARK: - Game State Manager
class GameManager: ObservableObject {
    @Published var pieces: [ChessPieceData] = []
    @Published var selectedPiece: ChessPieceData? = nil
    @Published var validMoves: [(col: Int, row: Int)] = []
    @Published var isPlayerTurn: Bool = true
    @Published var statusText: String = "Твой ход! (Белые/Золото)"
    @Published var isAlert: Bool = false
    @Published var difficulty: BotDifficulty = .medium
    @Published var inMenu: Bool = true
    
    // Ссылка на сцену для анимаций
    weak var sceneView: SCNView?
    
    func startNewGame(diff: BotDifficulty) {
        self.difficulty = diff
        self.inMenu = false
        self.isPlayerTurn = true
        self.statusText = "Твой ход! Сложность: \(diff.rawValue)"
        self.resetBoard()
    }
    
    func resetBoard() {
        pieces.removeAll()
        // Расстановка игрока (Золото, ряды 0-1)
        for c in 0..<8 {
            pieces.append(ChessPieceData(kind: .pawn, side: .player, col: c, row: 1))
        }
        let playerBack: [PieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for c in 0..<8 {
            pieces.append(ChessPieceData(kind: playerBack[c], side: .player, col: c, row: 0))
        }
        
        // Расстановка бота (Циан, ряды 6-7)
        for c in 0..<8 {
            pieces.append(ChessPieceData(kind: .pawn, side: .bot, col: c, row: 6))
        }
        let botBack: [PieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for c in 0..<8 {
            pieces.append(ChessPieceData(kind: botBack[c], side: .bot, col: c, row: 7))
        }
    }
    
    // Проверка допустимости хода по базовым правилам шахмат
    func getLegalMoves(for piece: ChessPieceData) -> [(col: Int, row: Int)] {
        var moves: [(col: Int, row: Int)] = []
        for c in 0..<8 {
            for r in 0..<8 {
                if isValidMove(piece: piece, targetCol: c, targetRow: r) {
                    moves.append((col: c, row: r))
                }
            }
        }
        return moves
    }
    
    func isValidMove(piece: ChessPieceData, targetCol: Int, targetRow: Int) -> Bool {
        if piece.col == targetCol && piece.row == targetRow { return false }
        let occupied = pieces.first { $0.col == targetCol && $0.row == targetRow }
        if let occ = occupied, occ.side == piece.side { return false }
        
        let dx = targetCol - piece.col
        let dy = targetRow - piece.row
        let absX = abs(dx)
        let absY = abs(dy)
        
        switch piece.kind {
        case .pawn:
            let dir = piece.side == .player ? 1 : -1
            if dx == 0 && dy == dir && occupied == nil { return true }
            if dx == 0 && dy == dir * 2 && piece.row == (piece.side == .player ? 1 : 6) && occupied == nil { return true }
            if absX == 1 && dy == dir && occupied != nil && occupied?.side != piece.side { return true }
            return false
        case .rook:
            return dx == 0 || dy == 0
        case .knight:
            return (absX == 1 && absY == 2) || (absX == 2 && absY == 1)
        case .bishop:
            return absX == absY
        case .queen:
            return dx == 0 || dy == 0 || absX == absY
        case .king:
            return absX <= 1 && absY <= 1
        }
    }
    
    // Ход ИИ (бота)
    func makeBotMove() {
        guard !isPlayerTurn else { return }
        statusText = "Бот вычисляет ход..."
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            let botPieces = self.pieces.filter { $0.side == .bot }
            
            var chosenPiece: ChessPieceData?
            var chosenMove: (col: Int, row: Int)?
            
            if self.difficulty == .easy {
                // Случайный ход
                let shuffled = botPieces.shuffled()
                for p in shuffled {
                    let moves = self.getLegalMoves(for: p)
                    if let m = moves.randomElement() {
                        chosenPiece = p
                        chosenMove = m
                        break
                    }
                }
            } else {
                // Умный поиск (атака фигур игрока с приоритетом)
                var bestScore = -9999
                for p in botPieces {
                    let moves = self.getLegalMoves(for: p)
                    for m in moves {
                        var score = 0
                        if let target = self.pieces.first(where: { $0.col == m.col && $0.row == m.row && $0.side == .player }) {
                            switch target.kind {
                            case .pawn: score += 10
                            case .knight, .bishop: score += 30
                            case .rook: score += 50
                            case .queen: score += 90
                            case .king: score += 900
                            }
                        }
                        if self.difficulty == .hard {
                            // Центр доски ценнее
                            let centerDistance = abs(3 - m.col) + abs(3 - m.row)
                            score += (10 - centerDistance)
                        }
                        if score > bestScore || chosenPiece == nil {
                            bestScore = score
                            chosenPiece = p
                            chosenMove = m
                        }
                    }
                }
            }
            
            if let p = chosenPiece, let m = chosenMove {
                self.executeMove(pieceId: p.id, targetCol: m.col, targetRow: m.row, isBot: true)
            } else {
                self.statusText = "Шах и мат! Ты победил!"
            }
        }
    }
    
    func executeMove(pieceId: UUID, targetCol: Int, targetRow: Int, isBot: Bool) {
        guard let idx = pieces.firstIndex(where: { $0.id == pieceId }) else { return }
        
        // Взятие фигуры противника
        if let targetIdx = pieces.firstIndex(where: { $0.col == targetCol && $0.row == targetRow && $0.side != pieces[idx].side }) {
            pieces.remove(at: targetIdx)
            AudioServicesPlaySystemSound(1057) // Звук взятия
        } else {
            AudioServicesPlaySystemSound(1104) // Звук хода
        }
        
        pieces[idx].col = targetCol
        pieces[idx].row = targetRow
        
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
        isPlayerTurn.toggle()
        if isPlayerTurn {
            statusText = "Твой ход!"
        } else {
            statusText = "Ход космического бота..."
            makeBotMove()
        }
    }
    
    func caughtCheating() {
        statusText = "⚠️ СПАЛИЛСЯ! ШТРАФ! ⚠️"
        isAlert = true
        AudioServicesPlaySystemSound(1053) // Звук ошибки / сирена
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.statusText = "Твой ход (играй честно или осторожно!)"
            self.isAlert = false
        }
    }
}

// MARK: - 3D Scene Implementation
struct SceneKitChessContainer: UIViewRepresentable {
    @ObservedObject var gameManager: GameManager
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        let scene = SCNScene()
        sceneView.scene = scene
        sceneView.backgroundColor = UIColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1.0)
        sceneView.antialiasingMode = .multisampling4X
        gameManager.sceneView = sceneView
        
        // Космос со звездами
        let starsNode = SCNNode()
        for _ in 0..<150 {
            let star = SCNSphere(radius: 0.035)
            let mat = SCNMaterial()
            mat.emission.contents = UIColor.white
            star.materials = [mat]
            let starNode = SCNNode(geometry: star)
            starNode.position = SCNVector3(
                Float.random(in: -25...25),
                Float.random(in: -10...25),
                Float.random(in: -25...25)
            )
            starsNode.addChildNode(starNode)
        }
        scene.rootNode.addChildNode(starsNode)
        
        // Камера и орбита
        let orbit = SCNNode()
        orbit.name = "orbitNode"
        let cameraNode = SCNNode()
        let cam = SCNCamera()
        cam.bloomIntensity = 1.3
        cam.bloomThreshold = 0.5
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 11, 9)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        orbit.addChildNode(cameraNode)
        scene.rootNode.addChildNode(orbit)
        sceneView.pointOfView = cameraNode
        
        // Свет
        let sun = SCNLight()
        sun.type = .directional
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowSampleCount = 16
        sun.shadowColor = UIColor.black.withAlphaComponent(0.8)
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.position = SCNVector3(8, 15, 8)
        sunNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(sunNode)
        
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 240
        let ambNode = SCNNode()
        ambNode.light = ambient
        scene.rootNode.addChildNode(ambNode)
        
        // Доска 8x8
        let board = SCNNode()
        board.name = "boardNode"
        for r in 0..<8 {
            for c in 0..<8 {
                let box = SCNBox(width: 1.0, height: 0.15, length: 1.0, chamferRadius: 0.02)
                let mat = SCNMaterial()
                mat.lightingModel = .physicallyBased
                if (r + c) % 2 != 0 {
                    mat.diffuse.contents = UIColor(white: 0.08, alpha: 1)
                    mat.metalness.contents = 0.95
                    mat.roughness.contents = 0.05
                } else {
                    mat.diffuse.contents = UIColor(white: 0.9, alpha: 1)
                    mat.metalness.contents = 0.1
                    mat.roughness.contents = 0.6
                }
                box.materials = [mat]
                let sqNode = SCNNode(geometry: box)
                sqNode.name = "square_\(c)_\(r)"
                sqNode.position = SCNVector3(Float(c) - 3.5, 0, Float(r) - 3.5)
                board.addChildNode(sqNode)
            }
        }
        scene.rootNode.addChildNode(board)
        
        context.coordinator.setupGestures(on: sceneView)
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let scene = uiView.scene else { return }
        
        // Синхронизация 3D фигур с данными игры
        scene.rootNode.enumerateChildNodes { node, _ in
            if node.name?.starts(with: "piece_") == true {
                node.removeFromParentNode()
            }
        }
        
        for piece in gameManager.pieces {
            let pieceNode = createRealChessPieceNode(piece: piece)
            scene.rootNode.addChildNode(pieceNode)
        }
        
        // Подсветка ходов
        highlightValidSquares(on: scene)
    }
    
    private func highlightValidSquares(on scene: SCNScene) {
        // Сброс свечения клеток
        scene.rootNode.enumerateChildNodes { node, _ in
            if let name = node.name, name.starts(with: "square_") {
                node.geometry?.firstMaterial?.emission.contents = UIColor.clear
            }
        }
        
        // Подсветка зеленым разрешенных ходов
        for m in gameManager.validMoves {
            if let sq = scene.rootNode.childNode(withName: "square_\(m.col)_\(m.row)", recursively: true) {
                sq.geometry?.firstMaterial?.emission.contents = UIColor.systemGreen.withAlphaComponent(0.4)
            }
        }
    }
    
    // Генерация детальных шахматных фигур
    private func createRealChessPieceNode(piece: ChessPieceData) -> SCNNode {
        let root = SCNNode()
        root.name = "piece_\(piece.id.uuidString)"
        
        let color = piece.side == .player ?
            UIColor(red: 1.0, green: 0.7, blue: 0.2, alpha: 1.0) : // Золото игрока
            UIColor(red: 0.1, green: 0.8, blue: 1.0, alpha: 1.0)   // Неон бота
        
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.black
        mat.emission.contents = color
        mat.metalness.contents = 0.8
        mat.roughness.contents = 0.2
        
        // Подставка фигуры
        let base = SCNCylinder(radius: 0.35, height: 0.15)
        base.materials = [mat]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(0, 0.075, 0)
        root.addChildNode(baseNode)
        
        switch piece.kind {
        case .pawn:
            let body = SCNCone(topRadius: 0.15, bottomRadius: 0.28, height: 0.45)
            body.materials = [mat]
            let bodyNode = SCNNode(geometry: body)
            bodyNode.position = SCNVector3(0, 0.35, 0)
            let head = SCNSphere(radius: 0.16)
            head.materials = [mat]
            let headNode = SCNNode(geometry: head)
            headNode.position = SCNVector3(0, 0.65, 0)
            root.addChildNode(bodyNode)
            root.addChildNode(headNode)
            
        case .rook: // Ладья с зубцами
            let tower = SCNCylinder(radius: 0.3, height: 0.65)
            tower.materials = [mat]
            let towerNode = SCNNode(geometry: tower)
            towerNode.position = SCNVector3(0, 0.45, 0)
            let crown = SCNBox(width: 0.55, height: 0.15, length: 0.55, chamferRadius: 0.02)
            crown.materials = [mat]
            let crownNode = SCNNode(geometry: crown)
            crownNode.position = SCNVector3(0, 0.8, 0)
            root.addChildNode(towerNode)
            root.addChildNode(crownNode)
            
        case .knight: // Конь
            let body = SCNCylinder(radius: 0.25, height: 0.4)
            body.materials = [mat]
            let bodyNode = SCNNode(geometry: body)
            bodyNode.position = SCNVector3(0, 0.35, 0)
            let head = SCNBox(width: 0.25, height: 0.4, length: 0.4, chamferRadius: 0.05)
            head.materials = [mat]
            let headNode = SCNNode(geometry: head)
            headNode.position = SCNVector3(0, 0.7, 0.1)
            headNode.eulerAngles.x = 0.3
            root.addChildNode(bodyNode)
            root.addChildNode(headNode)
            
        case .bishop: // Слон
            let body = SCNCone(topRadius: 0.12, bottomRadius: 0.26, height: 0.6)
            body.materials = [mat]
            let bodyNode = SCNNode(geometry: body)
            bodyNode.position = SCNVector3(0, 0.45, 0)
            let tip = SCNSphere(radius: 0.14)
            tip.materials = [mat]
            let tipNode = SCNNode(geometry: tip)
            tipNode.position = SCNVector3(0, 0.8, 0)
            root.addChildNode(bodyNode)
            root.addChildNode(tipNode)
            
        case .queen: // Ферзь
            let body = SCNCone(topRadius: 0.2, bottomRadius: 0.3, height: 0.8)
            body.materials = [mat]
            let bodyNode = SCNNode(geometry: body)
            bodyNode.position = SCNVector3(0, 0.55, 0)
            let crown = SCNTorus(ringRadius: 0.22, pipeRadius: 0.06)
            crown.materials = [mat]
            let crownNode = SCNNode(geometry: crown)
            crownNode.position = SCNVector3(0, 0.98, 0)
            root.addChildNode(bodyNode)
            root.addChildNode(crownNode)
            
        case .king: // Король с крестом
            let body = SCNCylinder(radius: 0.3, height: 0.85)
            body.materials = [mat]
            let bodyNode = SCNNode(geometry: body)
            bodyNode.position = SCNVector3(0, 0.58, 0)
            let crossV = SCNBox(width: 0.08, height: 0.25, length: 0.08, chamferRadius: 0.01)
            crossV.materials = [mat]
            let crossVNode = SCNNode(geometry: crossV)
            crossVNode.position = SCNVector3(0, 1.12, 0)
            let crossH = SCNBox(width: 0.22, height: 0.08, length: 0.08, chamferRadius: 0.01)
            crossH.materials = [mat]
            let crossHNode = SCNNode(geometry: crossH)
            crossHNode.position = SCNVector3(0, 1.15, 0)
            root.addChildNode(bodyNode)
            root.addChildNode(crossVNode)
            root.addChildNode(crossHNode)
        }
        
        root.position = SCNVector3(Float(piece.col) - 3.5, 0.05, Float(piece.row) - 3.5)
        return root
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(gameManager: gameManager)
    }
    
    // MARK: - Gestures & Interactions
    class Coordinator: NSObject {
        var gameManager: GameManager
        var selectedNode: SCNNode?
        var originalPos: SCNVector3 = SCNVector3Zero
        var initialCol: Int = 0
        var initialRow: Int = 0
        var isOrbiting: Bool = false
        
        init(gameManager: GameManager) {
            self.gameManager = gameManager
        }
        
        func setupGestures(on sceneView: SCNView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            sceneView.addGestureRecognizer(pan)
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let loc = gesture.location(in: view)
            
            switch gesture.state {
            case .began:
                guard gameManager.isPlayerTurn else { return }
                let hits = view.hitTest(loc, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
                
                // Нажатие на фигуру
                if let hit = hits.first(where: { $0.node.name?.starts(with: "piece_") == true || $0.node.parent?.name?.starts(with: "piece_") == true }) {
                    let pNode = hit.node.name?.starts(with: "piece_") == true ? hit.node : hit.node.parent!
                    let uuidStr = String(pNode.name!.dropFirst(6))
                    
                    if let piece = gameManager.pieces.first(where: { $0.id.uuidString == uuidStr && $0.side == .player }) {
                        selectedNode = pNode
                        originalPos = pNode.position
                        initialCol = piece.col
                        initialRow = piece.row
                        isOrbiting = false
                        
                        gameManager.selectedPiece = piece
                        gameManager.validMoves = gameManager.getLegalMoves(for: piece)
                        
                        // Звук подъема и анимация
                        AudioServicesPlaySystemSound(1104)
                        SCNTransaction.begin()
                        SCNTransaction.animationDuration = 0.2
                        pNode.position.y += 1.4
                        pNode.eulerAngles.z = 0.2
                        SCNTransaction.commit()
                        return
                    }
                }
                
                // Нажатие на космос — вращаем камеру
                isOrbiting = true
                selectedNode = nil
                gameManager.selectedPiece = nil
                gameManager.validMoves = []
                
            case .changed:
                if let node = selectedNode {
                    let translation = gesture.translation(in: view)
                    node.position.x = originalPos.x + Float(translation.x) * 0.02
                    node.position.z = originalPos.z + Float(translation.y) * 0.02
                } else if isOrbiting {
                    let t = gesture.translation(in: view)
                    if let orbit = view.scene?.rootNode.childNode(withName: "orbitNode", recursively: true) {
                        orbit.eulerAngles.y -= Float(t.x) * 0.005
                        orbit.eulerAngles.x = max(-0.8, min(0.4, orbit.eulerAngles.x - Float(t.y) * 0.005))
                    }
                    gesture.setTranslation(.zero, in: view)
                }
                
            case .ended, .cancelled:
                guard let node = selectedNode, let piece = gameManager.selectedPiece else { return }
                
                let targetCol = max(0, min(7, Int(round(node.position.x + 3.5))))
                let targetRow = max(0, min(7, Int(round(node.position.z + 3.5))))
                
                let isLegal = gameManager.validMoves.contains { $0.col == targetCol && $0.row == targetRow }
                let isCheat = !isLegal
                
                // Детектор шулера (шанс спалиться 40% при жульничестве)
                let caught = isCheat && (Int.random(in: 1...100) <= 40)
                
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.25
                node.eulerAngles.z = 0
                
                if caught {
                    // СПАЛИЛСЯ!
                    node.position = originalPos
                    gameManager.caughtCheating()
                } else {
                    // Успешный ход
                    node.position = SCNVector3(Float(targetCol) - 3.5, 0.05, Float(targetRow) - 3.5)
                    gameManager.executeMove(pieceId: piece.id, targetCol: targetCol, targetRow: targetRow, isBot: false)
                }
                SCNTransaction.commit()
                
                selectedNode = nil
                gameManager.selectedPiece = nil
                gameManager.validMoves = []
                
            default:
                break
            }
        }
    }
}

// MARK: - Main Game UI Overlay & Menu
struct MainGameView: View {
    @StateObject private var gameManager = GameManager()
    
    var body: some View {
        ZStack {
            // 3D Холст
            SceneKitChessContainer(gameManager: gameManager)
                .ignoresSafeArea()
            
            if gameManager.inMenu {
                // Главное меню
                VStack(spacing: 24) {
                    Text("COSMIC CHESS")
                        .font(.system(size: 32, weight: .black, design: .monospaced))
                        .foregroundColor(.cyan)
                        .shadow(color: .cyan.opacity(0.8), radius: 10)
                    
                    Text("3D Шахматы с ИИ и шулерством")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                    
                    VStack(spacing: 12) {
                        Text("ВЫБЕРИ СЛОЖНОСТЬ БОТА:")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                        
                        ForEach(BotDifficulty.allCases) { diff in
                            Button(action: {
                                gameManager.startNewGame(diff: diff)
                            }) {
                                HStack {
                                    Text(diff.rawValue)
                                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .background(Color.cyan.opacity(0.2))
                                .cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.5), lineWidth: 1))
                            }
                        }
                    }
                    .frame(maxWidth: 280)
                }
                .padding(30)
                .background(Color.black.opacity(0.85))
                .cornerRadius(24)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.cyan.opacity(0.6), lineWidth: 2))
                .shadow(radius: 20)
                
            } else {
                // Игровой оверлей
                VStack {
                    // Верхняя панель
                    HStack {
                        Button(action: { gameManager.inMenu = true }) {
                            Image(systemName: "line.3.horizontal")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }
                        
                        Spacer()
                        
                        // Статус игры
                        Text(gameManager.statusText)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(gameManager.isAlert ? .red : .cyan)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(gameManager.isAlert ? Color.red : Color.cyan.opacity(0.3), lineWidth: 1))
                        
                        Spacer()
                        
                        // Сброс камеры
                        Button(action: { resetCamera() }) {
                            Image(systemName: "camera.metering.center.weighted")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 45)
                    
                    Spacer()
                    
                    // Нижняя панель помощи
                    HStack {
                        Label("Зеленый: ход по правилам", systemImage: "checkmark.circle")
                        Spacer()
                        Label("В космос: риск шулерства", systemImage: "exclamationmark.triangle")
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 25)
                }
            }
        }
    }
    
    private func resetCamera() {
        if let orbit = gameManager.sceneView?.scene?.rootNode.childNode(withName: "orbitNode", recursively: true) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            orbit.eulerAngles = SCNVector3Zero
            SCNTransaction.commit()
        }
    }
}
