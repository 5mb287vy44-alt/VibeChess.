import SwiftUI
import SceneKit
import UIKit

// MARK: - App Entry
@main
struct VibeChessApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Game State Manager
class ChessGameManager: ObservableObject {
    @Published var alertText: String = "Перетаскивай фигуры. Можно жульничать!"
    @Published var isAlertActive: Bool = false
    
    func triggerCheatAlert() {
        alertText = "⚠️ ПОЙМАН ЗА ЖУЛЬНИЧЕСТВОМ! ШТРАФ! ⚠️"
        isAlertActive = true
        
        // Жесткая вибрация iPhone (Taptic Engine)
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.error)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.alertText = "Следим за твоими ходами..."
            self.isAlertActive = false
        }
    }
    
    func triggerDropSuccess() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
    }
    
    func triggerLift() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }
}

// MARK: - 3D Scene View
struct ChessSceneView: UIViewRepresentable {
    @ObservedObject var gameManager: ChessGameManager
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        let scene = SCNScene()
        sceneView.scene = scene
        sceneView.backgroundColor = UIColor.black
        sceneView.antialiasingMode = .multisampling4X
        
        // 1. Космос: процедурные звезды вокруг
        let starsNode = SCNNode()
        for _ in 0..<120 {
            let star = SCNSphere(radius: 0.04)
            let starMat = SCNMaterial()
            starMat.emission.contents = UIColor.white
            star.materials = [starMat]
            let starNode = SCNNode(geometry: star)
            starNode.position = SCNVector3(
                Float.random(in: -20...20),
                Float.random(in: -10...20),
                Float.random(in: -20...20)
            )
            starsNode.addChildNode(starNode)
        }
        scene.rootNode.addChildNode(starsNode)
        
        // 2. Камера и освещение
        let orbitNode = SCNNode()
        orbitNode.name = "orbitNode"
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.bloomIntensity = 1.2
        camera.bloomThreshold = 0.4
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 11, 9)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        orbitNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(orbitNode)
        sceneView.pointOfView = cameraNode
        
        // Источник света сверхновой (тени)
        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.castsShadow = true
        sunLight.shadowMode = .deferred
        sunLight.shadowSampleCount = 16
        sunLight.shadowColor = UIColor.black.withAlphaComponent(0.8)
        let sunNode = SCNNode()
        sunNode.light = sunLight
        sunNode.position = SCNVector3(8, 14, 8)
        sunNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(sunNode)
        
        // Фоновый космический свет
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 180
        scene.rootNode.addChildNode(ambientLight)
        
        // 3. Шахматная доска
        let boardNode = SCNNode()
        boardNode.name = "board"
        for row in 0..<8 {
            for col in 0..<8 {
                let square = SCNBox(width: 1.0, height: 0.15, length: 1.0, chamferRadius: 0.02)
                let mat = SCNMaterial()
                mat.lightingModel = .physicallyBased
                if (row + col) % 2 != 0 {
                    // Обсидиан / Черная дыра
                    mat.diffuse.contents = UIColor(white: 0.05, alpha: 1)
                    mat.metalness.contents = 0.95
                    mat.roughness.contents = 0.05
                } else {
                    // Звездный мрамор
                    mat.diffuse.contents = UIColor(white: 0.85, alpha: 1)
                    mat.metalness.contents = 0.2
                    mat.roughness.contents = 0.7
                }
                square.materials = [mat]
                let node = SCNNode(geometry: square)
                node.position = SCNVector3(Float(col) - 3.5, 0, Float(row) - 3.5)
                boardNode.addChildNode(node)
            }
        }
        scene.rootNode.addChildNode(boardNode)
        
        // 4. Генерация всех 32 фигур
        setupPieces(on: scene)
        
        // 5. Жесты управления (таскать фигуры / вращать космос)
        context.coordinator.setupGestures(on: sceneView)
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(gameManager: gameManager)
    }
    
    // MARK: - Piece Generator
    private func setupPieces(on scene: SCNScene) {
        let goldColor = UIColor(red: 1.0, green: 0.6, blue: 0.1, alpha: 1.0) // Солнечные
        let cyanColor = UIColor(red: 0.1, green: 0.8, blue: 1.0, alpha: 1.0) // Пульсары
        
        for col in 0..<8 {
            // Пешки
            createPiece(type: .pawn, color: goldColor, col: col, row: 1, on: scene)
            createPiece(type: .pawn, color: cyanColor, col: col, row: 6, on: scene)
        }
        
        let backRow: [PieceType] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for col in 0..<8 {
            createPiece(type: backRow[col], color: goldColor, col: col, row: 0, on: scene)
            createPiece(type: backRow[col], color: cyanColor, col: col, row: 7, on: scene)
        }
    }
    
    enum PieceType { case pawn, rook, knight, bishop, queen, king }
    
    private func createPiece(type: PieceType, color: UIColor, col: Int, row: Int, on scene: SCNScene) {
        let geom: SCNGeometry
        var height: Float = 0.8
        
        switch type {
        case .pawn:
            geom = SCNCylinder(radius: 0.25, height: 0.6)
            height = 0.6
        case .rook:
            geom = SCNBox(width: 0.6, height: 0.8, length: 0.6, chamferRadius: 0.05)
            height = 0.8
        case .knight:
            geom = SCNCone(topRadius: 0.1, bottomRadius: 0.35, height: 0.9)
            height = 0.9
        case .bishop:
            geom = SCNCone(topRadius: 0.05, bottomRadius: 0.3, height: 1.0)
            height = 1.0
        case .queen:
            geom = SCNCylinder(radius: 0.35, height: 1.2)
            height = 1.2
        case .king:
            geom = SCNBox(width: 0.6, height: 1.3, length: 0.6, chamferRadius: 0.1)
            height = 1.3
        }
        
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.black
        mat.emission.contents = color
        mat.metalness.contents = 0.8
        mat.roughness.contents = 0.2
        geom.materials = [mat]
        
        let node = SCNNode(geometry: geom)
        node.name = "chess_piece"
        node.position = SCNVector3(Float(col) - 3.5, height / 2.0 + 0.08, Float(row) - 3.5)
        scene.rootNode.addChildNode(node)
    }
    
    // MARK: - Coordinator for Touch & Drag
    class Coordinator: NSObject {
        var gameManager: ChessGameManager
        var selectedNode: SCNNode?
        var originalPosition: SCNVector3 = SCNVector3Zero
        var initialCol: Int = 0
        var initialRow: Int = 0
        var isOrbiting: Bool = false
        
        init(gameManager: ChessGameManager) {
            self.gameManager = gameManager
        }
        
        func setupGestures(on sceneView: SCNView) {
            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            sceneView.addGestureRecognizer(panGesture)
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let sceneView = gesture.view as? SCNView else { return }
            let location = gesture.location(in: sceneView)
            
            switch gesture.state {
            case .began:
                let hits = sceneView.hitTest(location, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
                // Ищем, нажали ли на фигуру
                if let hitPiece = hits.first(where: { $0.node.name == "chess_piece" }) {
                    selectedNode = hitPiece.node
                    originalPosition = hitPiece.node.position
                    initialCol = Int(round(originalPosition.x + 3.5))
                    initialRow = Int(round(originalPosition.z + 3.5))
                    isOrbiting = false
                    
                    // Эффект взятия в руку: подъем в воздух и легкий наклон
                    gameManager.triggerLift()
                    SCNTransaction.begin()
                    SCNTransaction.animationDuration = 0.2
                    selectedNode?.position.y += 1.2
                    selectedNode?.eulerAngles.z = 0.2
                    SCNTransaction.commit()
                } else {
                    // Касание космоса — вращаем камеру
                    isOrbiting = true
                    selectedNode = nil
                }
                
            case .changed:
                if let piece = selectedNode {
                    // Тащим фигуру через воздух
                    let translation = gesture.translation(in: sceneView)
                    let sensitivity: Float = 0.02
                    piece.position.x = originalPosition.x + Float(translation.x) * sensitivity
                    piece.position.z = originalPosition.z + Float(translation.y) * sensitivity
                } else if isOrbiting {
                    // Вращение космической камеры
                    let translation = gesture.translation(in: sceneView)
                    if let orbit = sceneView.scene?.rootNode.childNode(withName: "orbitNode", recursively: true) {
                        orbit.eulerAngles.y -= Float(translation.x) * 0.005
                        orbit.eulerAngles.x = max(-0.8, min(0.4, orbit.eulerAngles.x - Float(translation.y) * 0.005))
                    }
                    gesture.setTranslation(.zero, in: sceneView)
                }
                
            case .ended, .cancelled:
                guard let piece = selectedNode else { return }
                
                // Вычисляем новую клетку
                let targetCol = max(0, min(7, Int(round(piece.position.x + 3.5))))
                let targetRow = max(0, min(7, Int(round(piece.position.z + 3.5))))
                
                let dist = abs(targetCol - initialCol) + abs(targetRow - initialRow)
                
                // Механика «Шулера»: если ход дикий (прыжок более чем на 2 клетки), есть 40% шанс спалиться
                let isIllegal = dist > 2
                let caughtCheating = isIllegal && (Int.random(in: 1...100) <= 45)
                
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.3
                piece.eulerAngles.z = 0
                
                if caughtCheating {
                    // СПАЛИЛСЯ! Штраф и возврат на базу
                    piece.position = originalPosition
                    gameManager.triggerCheatAlert()
                } else {
                    // Успешный ход (или успешное жульничество)
                    piece.position.x = Float(targetCol) - 3.5
                    piece.position.z = Float(targetRow) - 3.5
                    piece.position.y = originalPosition.y
                    gameManager.triggerDropSuccess()
                }
                SCNTransaction.commit()
                selectedNode = nil
                
            default:
                break
            }
        }
    }
}

// MARK: - Main Interface Overlay
struct ContentView: View {
    @StateObject private var gameManager = ChessGameManager()
    
    var body: some View {
        ZStack {
            ChessSceneView(gameManager: gameManager)
                .ignoresSafeArea()
            
            VStack {
                // Плашка уведомлений и статуса
                Text(gameManager.alertText)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(gameManager.isAlertActive ? .red : .cyan)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(gameManager.isAlertActive ? Color.red : Color.cyan.opacity(0.4), lineWidth: 1.5)
                    )
                    .cornerRadius(12)
                    .padding(.top, 50)
                    .animation(.easeInOut, value: gameManager.isAlertActive)
                
                Spacer()
                
                // Подсказка снизу
                HStack {
                    Label("Космос: крути пальцем", systemImage: "hand.draw")
                    Spacer()
                    Label("Фигуры: хватай и кидай", systemImage: "hand.tap")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.bottom, 25)
            }
        }
    }
}
