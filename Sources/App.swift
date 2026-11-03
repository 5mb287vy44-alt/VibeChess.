import SwiftUI
import SceneKit

@main
struct VibeChessApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ChessView: UIViewRepresentable {
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        let scene = SCNScene()
        sceneView.scene = scene
        sceneView.allowsCameraControl = true // Свободное вращение доски пальцами
        sceneView.autoenablesDefaultLighting = false
        sceneView.backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        
        // 1. Создаем собственную камеру со свечением
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.bloomIntensity = 1.0
        camera.bloomThreshold = 0.5
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 9, 8)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
        
        // 2. Направленный свет и мягкие тени
        let light = SCNLight()
        light.type = .directional
        light.castsShadow = true
        light.shadowMode = .deferred
        light.shadowSampleCount = 16
        
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(5, 10, 5)
        lightNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(lightNode)
        
        // 3. Фоновый свет
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 200
        scene.rootNode.addChildNode(ambientLight)
        
        // 4. Генерация шахматной доски (Мрамор и Стекло)
        let boardNode = SCNNode()
        for row in 0..<8 {
            for col in 0..<8 {
                let square = SCNBox(width: 1.0, height: 0.1, length: 1.0, chamferRadius: 0.02)
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                
                if (row + col) % 2 != 0 {
                    // Черное стекло
                    material.diffuse.contents = UIColor.black
                    material.metalness.contents = 1.0
                    material.roughness.contents = 0.05
                } else {
                    // Белый матовый мрамор
                    material.diffuse.contents = UIColor(white: 0.9, alpha: 1)
                    material.metalness.contents = 0.1
                    material.roughness.contents = 0.8
                }
                
                square.materials = [material]
                let squareNode = SCNNode(geometry: square)
                // Исправлены типы Float для компилятора iOS
                squareNode.position = SCNVector3(Float(row) - 3.5, 0, Float(col) - 3.5)
                boardNode.addChildNode(squareNode)
            }
        }
        scene.rootNode.addChildNode(boardNode)
        
        // 5. Неоновая светящаяся пешка
        let pawn = SCNCylinder(radius: 0.3, height: 0.8)
        let neonMat = SCNMaterial()
        neonMat.diffuse.contents = UIColor.black
        neonMat.emission.contents = UIColor.systemCyan
        pawn.materials = [neonMat]
        
        let pawnNode = SCNNode(geometry: pawn)
        pawnNode.position = SCNVector3(0, 0.45, 0)
        scene.rootNode.addChildNode(pawnNode)
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        ZStack {
            ChessView()
                .ignoresSafeArea()
            
            VStack {
                Spacer()
                Text("VibeChess: Alpha")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                    .padding(.bottom, 40)
            }
        }
    }
}
