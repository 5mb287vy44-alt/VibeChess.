import SwiftUI
import SceneKit
import ARKit

@main
struct VibeChessApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ChessView: UIViewRepresentable {
    func makeUIView(context: Context) -> ARSCNView {
        let sceneView = ARSCNView()
        sceneView.scene = SCNScene()
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = false
        sceneView.backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        
        sceneView.defaultCameraController.pointOfView?.camera?.bloomIntensity = 1.0
        
        let light = SCNLight()
        light.type = .directional
        light.castsShadow = true
        light.shadowMode = .deferred
        light.shadowSampleCount = 16
        
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(5, 10, 5)
        lightNode.look(at: SCNVector3Zero)
        sceneView.scene?.rootNode.addChildNode(lightNode)
        
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 200
        sceneView.scene?.rootNode.addChildNode(ambientLight)
        
        let boardNode = SCNNode()
        for row in 0..<8 {
            for col in 0..<8 {
                let square = SCNBox(width: 1.0, height: 0.1, length: 1.0, chamferRadius: 0.02)
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                
                if (row + col) % 2 != 0 {
                    material.diffuse.contents = UIColor.black
                    material.metalness.contents = 1.0
                    material.roughness.contents = 0.05
                } else {
                    material.diffuse.contents = UIColor(white: 0.9, alpha: 1)
                    material.metalness.contents = 0.1
                    material.roughness.contents = 0.8
                }
                
                square.materials = [material]
                let squareNode = SCNNode(geometry: square)
                squareNode.position = SCNVector3(CGFloat(row) - 3.5, 0, CGFloat(col) - 3.5)
                boardNode.addChildNode(squareNode)
            }
        }
        sceneView.scene?.rootNode.addChildNode(boardNode)
        
        let pawn = SCNCylinder(radius: 0.3, height: 0.8)
        let neonMat = SCNMaterial()
        neonMat.diffuse.contents = UIColor.black
        neonMat.emission.contents = UIColor.systemCyan
        pawn.materials = [neonMat]
        
        let pawnNode = SCNNode(geometry: pawn)
        pawnNode.position = SCNVector3(0, 0.45, 0)
        sceneView.scene?.rootNode.addChildNode(pawnNode)
        
        return sceneView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
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
