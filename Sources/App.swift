import SwiftUI
import SceneKit
import ARKit
import AVFoundation
import AudioToolbox
import CoreMotion
import UIKit

enum Side: String, Codable {
    case white, black
    var opposite: Side { self == .white ? .black : .white }
    var title: String { self == .white ? "Белые" : "Чёрные" }
}

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

enum GameMode: String, CaseIterable, Identifiable, Codable {
    case vsBot = "1 Игрок (vs Бот)"
    case passAndPlay = "2 Игрока (Вдвоем)"
    var id: String { rawValue }
}

enum ControlMode: String, CaseIterable, Identifiable, Codable {
    case tap = "Нажатие"
    case drag = "Руками (Физика)"
    var id: String { rawValue }
}

enum BotDifficulty: String, CaseIterable, Identifiable, Codable {
    case easy = "Новичок"
    case medium = "Тактик"
    case hard = "Гроссмейстер"
    var id: String { rawValue }
}

enum GraphicsQuality: String, CaseIterable, Identifiable, Codable {
    case standard = "Стандарт"
    case high = "Высокое"
    case ultra = "Ультра"
    var id: String { rawValue }
}

enum GameResult: Equatable {
    case checkmate(winner: Side)
    case stalemate
    case insufficient
    case fiftyMove
    case repetition
    case timeout(loser: Side)

    var title: String {
        switch self {
        case .checkmate(let w): return "Мат! Победили \(w == .white ? "белые" : "чёрные")"
        case .stalemate: return "Пат — ничья"
        case .insufficient: return "Ничья: мало материала"
        case .fiftyMove: return "Ничья: правило 50 ходов"
        case .repetition: return "Ничья: троекратное повторение"
        case .timeout(let l): return "Время вышло! Победили \(l == .white ? "чёрные" : "белые")"
        }
    }
}

struct Move: Equatable, Codable {
    var from: Int
    var to: Int
    var promo: Int = 0
}

struct PositionKey: Hashable {
    var sq: [Int8]
    var whiteToMove: Bool
    var castle: UInt8
    var ep: Int
}

struct ChessBoard: Codable, Equatable {
    var sq: [Int8]
    var whiteToMove: Bool
    var castle: UInt8
    var ep: Int
    var halfmove: Int
    var fullmove: Int

    static func initial() -> ChessBoard {
        var b = ChessBoard(sq: [Int8](repeating: 0, count: 64), whiteToMove: true,
                           castle: 0b1111, ep: -1, halfmove: 0, fullmove: 1)
        let back: [Int8] = [4, 2, 3, 5, 6, 3, 2, 4]
        for c in 0..<8 {
            b.sq[c] = back[c]
            b.sq[8 + c] = 1
            b.sq[48 + c] = -1
            b.sq[56 + c] = -back[c]
        }
        return b
    }

    var key: PositionKey {
        return PositionKey(sq: sq, whiteToMove: whiteToMove, castle: castle, ep: ep)
    }

    fileprivate static let knightOffsets: [(Int, Int)] = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    fileprivate static let kingOffsets: [(Int, Int)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    fileprivate static let diagDirs: [(Int, Int)] = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    fileprivate static let lineDirs: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    fileprivate static let allDirs: [(Int, Int)] = [(1, 1), (1, -1), (-1, 1), (-1, -1), (1, 0), (-1, 0), (0, 1), (0, -1)]

    fileprivate static func castleMask(_ s: Int) -> UInt8 {
        switch s {
        case 0: return 0b1101
        case 7: return 0b1110
        case 4: return 0b1100
        case 56: return 0b0111
        case 63: return 0b1011
        case 60: return 0b0011
        default: return 0b1111
        }
    }

    func kingSquare(white: Bool) -> Int {
        let k: Int8 = white ? 6 : -6
        for s in 0..<64 where sq[s] == k { return s }
        return -1
    }

    func inCheck(white: Bool) -> Bool {
        let k = kingSquare(white: white)
        if k < 0 { return false }
        return isAttacked(k, byWhite: !white)
    }

    func isAttacked(_ s: Int, byWhite: Bool) -> Bool {
        let c = s & 7
        let r = s >> 3
        let pawn: Int8 = byWhite ? 1 : -1
        let pr = byWhite ? r - 1 : r + 1
        if pr >= 0 && pr < 8 {
            if c > 0 && sq[pr * 8 + c - 1] == pawn { return true }
            if c < 7 && sq[pr * 8 + c + 1] == pawn { return true }
        }
        let knight: Int8 = byWhite ? 2 : -2
        for (dc, dr) in ChessBoard.knightOffsets {
            let nc = c + dc
            let nr = r + dr
            if nc >= 0 && nc < 8 && nr >= 0 && nr < 8 && sq[nr * 8 + nc] == knight { return true }
        }
        let king: Int8 = byWhite ? 6 : -6
        for (dc, dr) in ChessBoard.kingOffsets {
            let nc = c + dc
            let nr = r + dr
            if nc >= 0 && nc < 8 && nr >= 0 && nr < 8 && sq[nr * 8 + nc] == king { return true }
        }
        let bishop: Int8 = byWhite ? 3 : -3
        let rook: Int8 = byWhite ? 4 : -4
        let queen: Int8 = byWhite ? 5 : -5
        for (dc, dr) in ChessBoard.diagDirs {
            var nc = c + dc
            var nr = r + dr
            while nc >= 0 && nc < 8 && nr >= 0 && nr < 8 {
                let p = sq[nr * 8 + nc]
                if p != 0 {
                    if p == bishop || p == queen { return true }
                    break
                }
                nc += dc
                nr += dr
            }
        }
        for (dc, dr) in ChessBoard.lineDirs {
            var nc = c + dc
            var nr = r + dr
            while nc >= 0 && nc < 8 && nr >= 0 && nr < 8 {
                let p = sq[nr * 8 + nc]
                if p != 0 {
                    if p == rook || p == queen { return true }
                    break
                }
                nc += dc
                nr += dr
            }
        }
        return false
    }

    func isCapture(_ m: Move) -> Bool {
        if sq[m.to] != 0 { return true }
        return abs(Int(sq[m.from])) == 1 && (m.from & 7) != (m.to & 7)
    }

    func pseudoLegalMoves() -> [Move] {
        var moves: [Move] = []
        moves.reserveCapacity(48)
        let white = whiteToMove
        for s in 0..<64 {
            let p = Int(sq[s])
            if p == 0 || (p > 0) != white { continue }
            let type = abs(p)
            let c = s & 7
            let r = s >> 3
            switch type {
            case 1:
                let dir = white ? 1 : -1
                let startRow = white ? 1 : 6
                let promoRow = white ? 7 : 0
                let nr = r + dir
                if nr >= 0 && nr < 8 {
                    let t = nr * 8 + c
                    if sq[t] == 0 {
                        if nr == promoRow {
                            for pr in [5, 4, 3, 2] { moves.append(Move(from: s, to: t, promo: pr)) }
                        } else {
                            moves.append(Move(from: s, to: t))
                            if r == startRow {
                                let t2 = (r + 2 * dir) * 8 + c
                                if sq[t2] == 0 { moves.append(Move(from: s, to: t2)) }
                            }
                        }
                    }
                    for dc in [-1, 1] {
                        let nc = c + dc
                        if nc < 0 || nc > 7 { continue }
                        let t = nr * 8 + nc
                        let target = Int(sq[t])
                        if target != 0 && (target > 0) != white {
                            if nr == promoRow {
                                for pr in [5, 4, 3, 2] { moves.append(Move(from: s, to: t, promo: pr)) }
                            } else {
                                moves.append(Move(from: s, to: t))
                            }
                        } else if target == 0 && t == ep {
                            moves.append(Move(from: s, to: t))
                        }
                    }
                }
            case 2, 6:
                let offsets = (type == 2) ? ChessBoard.knightOffsets : ChessBoard.kingOffsets
                for (dc, dr) in offsets {
                    let nc = c + dc
                    let nr = r + dr
                    if nc < 0 || nc > 7 || nr < 0 || nr > 7 { continue }
                    let t = nr * 8 + nc
                    let target = Int(sq[t])
                    if target == 0 || (target > 0) != white { moves.append(Move(from: s, to: t)) }
                }
                if type == 6 { addCastling(&moves, from: s, white: white) }
            default:
                let dirs = (type == 3) ? ChessBoard.diagDirs : ((type == 4) ? ChessBoard.lineDirs : ChessBoard.allDirs)
                for (dc, dr) in dirs {
                    var nc = c + dc
                    var nr = r + dr
                    while nc >= 0 && nc < 8 && nr >= 0 && nr < 8 {
                        let t = nr * 8 + nc
                        let target = Int(sq[t])
                        if target == 0 {
                            moves.append(Move(from: s, to: t))
                        } else {
                            if (target > 0) != white { moves.append(Move(from: s, to: t)) }
                            break
                        }
                        nc += dc
                        nr += dr
                    }
                }
            }
        }
        return moves
    }

    private func addCastling(_ moves: inout [Move], from s: Int, white: Bool) {
        if white && s == 4 {
            if (castle & 1) != 0 && sq[5] == 0 && sq[6] == 0 && sq[7] == 4 {
                let safe = !isAttacked(4, byWhite: false) && !isAttacked(5, byWhite: false) && !isAttacked(6, byWhite: false)
                if safe { moves.append(Move(from: 4, to: 6)) }
            }
            if (castle & 2) != 0 && sq[3] == 0 && sq[2] == 0 && sq[1] == 0 && sq[0] == 4 {
                let safe = !isAttacked(4, byWhite: false) && !isAttacked(3, byWhite: false) && !isAttacked(2, byWhite: false)
                if safe { moves.append(Move(from: 4, to: 2)) }
            }
        } else if !white && s == 60 {
            if (castle & 4) != 0 && sq[61] == 0 && sq[62] == 0 && sq[63] == -4 {
                let safe = !isAttacked(60, byWhite: true) && !isAttacked(61, byWhite: true) && !isAttacked(62, byWhite: true)
                if safe { moves.append(Move(from: 60, to: 62)) }
            }
            if (castle & 8) != 0 && sq[59] == 0 && sq[58] == 0 && sq[57] == 0 && sq[56] == -4 {
                let safe = !isAttacked(60, byWhite: true) && !isAttacked(59, byWhite: true) && !isAttacked(58, byWhite: true)
                if safe { moves.append(Move(from: 60, to: 58)) }
            }
        }
    }

    func legalMoves() -> [Move] {
        let pseudo = pseudoLegalMoves()
        var result: [Move] = []
        result.reserveCapacity(pseudo.count)
        let white = whiteToMove
        for m in pseudo {
            var nb = self
            nb.apply(m)
            if !nb.inCheck(white: white) { result.append(m) }
        }
        return result
    }

    mutating func apply(_ m: Move) {
        let piece = sq[m.from]
        let type = abs(Int(piece))
        let white = piece > 0
        let captured = sq[m.to]
        let fromCol = m.from & 7
        let toCol = m.to & 7
        if type == 1 || captured != 0 { halfmove = 0 } else { halfmove += 1 }
        if type == 1 && captured == 0 && fromCol != toCol {
            sq[(m.from >> 3) * 8 + toCol] = 0
        }
        sq[m.to] = piece
        sq[m.from] = 0
        if type == 1 && m.promo != 0 {
            sq[m.to] = Int8(white ? m.promo : -m.promo)
        }
        var newEp = -1
        if type == 1 && abs(m.to - m.from) == 16 { newEp = (m.from + m.to) / 2 }
        if type == 6 && abs(toCol - fromCol) == 2 {
            let base = (m.from >> 3) * 8
            if toCol == 6 {
                sq[base + 5] = sq[base + 7]
                sq[base + 7] = 0
            } else {
                sq[base + 3] = sq[base]
                sq[base] = 0
            }
        }
        castle &= ChessBoard.castleMask(m.from) & ChessBoard.castleMask(m.to)
        ep = newEp
        if !white { fullmove += 1 }
        whiteToMove.toggle()
    }

    func insufficientMaterial() -> Bool {
        var minors = 0
        for s in 0..<64 {
            let t = abs(Int(sq[s]))
            if t == 0 || t == 6 { continue }
            if t == 2 || t == 3 { minors += 1 } else { return false }
        }
        return minors <= 1
    }
}

func squareName(_ s: Int) -> String {
    let files = ["a", "b", "c", "d", "e", "f", "g", "h"]
    return files[s & 7] + String((s >> 3) + 1)
}

func describeMove(_ m: Move, before: ChessBoard, after: ChessBoard) -> String {
    let letters = ["", "", "К", "С", "Л", "Ф", "Кр"]
    let p = abs(Int(before.sq[m.from]))
    var s: String
    if p == 6 && abs((m.to & 7) - (m.from & 7)) == 2 {
        s = ((m.to & 7) == 6) ? "O-O" : "O-O-O"
    } else {
        s = (p >= 1 && p <= 6) ? letters[p] : ""
        s += squareName(m.from)
        s += before.isCapture(m) ? "×" : "–"
        s += squareName(m.to)
        if m.promo >= 2 && m.promo <= 5 { s += "=" + letters[m.promo] }
    }
    if after.inCheck(white: after.whiteToMove) {
        s += after.legalMoves().isEmpty ? "#" : "+"
    }
    return s
}

final class ChessAI {
    private var deadline = Date()
    private var aborted = false
    private var nodes = 0
    private static let mate = 100000
    private static let inf = 1000000
    private static let values: [Int] = [0, 100, 320, 330, 500, 900, 0]

    private static let pawnPST: [Int] = [
         0,  0,  0,  0,  0,  0,  0,  0,
        50, 50, 50, 50, 50, 50, 50, 50,
        10, 10, 20, 30, 30, 20, 10, 10,
         5,  5, 10, 25, 25, 10,  5,  5,
         0,  0,  0, 20, 20,  0,  0,  0,
         5, -5,-10,  0,  0,-10, -5,  5,
         5, 10, 10,-20,-20, 10, 10,  5,
         0,  0,  0,  0,  0,  0,  0,  0]
    private static let knightPST: [Int] = [
        -50,-40,-30,-30,-30,-30,-40,-50,
        -40,-20,  0,  0,  0,  0,-20,-40,
        -30,  0, 10, 15, 15, 10,  0,-30,
        -30,  5, 15, 20, 20, 15,  5,-30,
        -30,  0, 15, 20, 20, 15,  0,-30,
        -30,  5, 10, 15, 15, 10,  5,-30,
        -40,-20,  0,  5,  5,  0,-20,-40,
        -50,-40,-30,-30,-30,-30,-40,-50]
    private static let bishopPST: [Int] = [
        -20,-10,-10,-10,-10,-10,-10,-20,
        -10,  0,  0,  0,  0,  0,  0,-10,
        -10,  0,  5, 10, 10,  5,  0,-10,
        -10,  5,  5, 10, 10,  5,  5,-10,
        -10,  0, 10, 10, 10, 10,  0,-10,
        -10, 10, 10, 10, 10, 10, 10,-10,
        -10,  5,  0,  0,  0,  0,  5,-10,
        -20,-10,-10,-10,-10,-10,-10,-20]
    private static let rookPST: [Int] = [
          0,  0,  0,  0,  0,  0,  0,  0,
          5, 10, 10, 10, 10, 10, 10,  5,
         -5,  0,  0,  0,  0,  0,  0, -5,
         -5,  0,  0,  0,  0,  0,  0, -5,
         -5,  0,  0,  0,  0,  0,  0, -5,
         -5,  0,  0,  0,  0,  0,  0, -5,
         -5,  0,  0,  0,  0,  0,  0, -5,
          0,  0,  0,  5,  5,  0,  0,  0]
    private static let queenPST: [Int] = [
        -20,-10,-10, -5, -5,-10,-10,-20,
        -10,  0,  0,  0,  0,  0,  0,-10,
        -10,  0,  5,  5,  5,  5,  0,-10,
         -5,  0,  5,  5,  5,  5,  0, -5,
          0,  0,  5,  5,  5,  5,  0, -5,
        -10,  5,  5,  5,  5,  5,  0,-10,
        -10,  0,  5,  0,  0,  0,  0,-10,
        -20,-10,-10, -5, -5,-10,-10,-20]
    private static let kingMidPST: [Int] = [
        -30,-40,-40,-50,-50,-40,-40,-30,
        -30,-40,-40,-50,-50,-40,-40,-30,
        -30,-40,-40,-50,-50,-40,-40,-30,
        -30,-40,-40,-50,-50,-40,-40,-30,
        -20,-30,-30,-40,-40,-30,-30,-20,
        -10,-20,-20,-20,-20,-20,-20,-10,
         20, 20,  0,  0,  0,  0, 20, 20,
         20, 30, 10,  0,  0, 10, 30, 20]
    private static let kingEndPST: [Int] = [
        -50,-40,-30,-20,-20,-30,-40,-50,
        -30,-20,-10,  0,  0,-10,-20,-30,
        -30,-10, 20, 30, 30, 20,-10,-30,
        -30,-10, 30, 40, 40, 30,-10,-30,
        -30,-10, 30, 40, 40, 30,-10,-30,
        -30,-10, 20, 30, 30, 20,-10,-30,
        -30,-30,  0,  0,  0,  0,-30,-30,
        -50,-30,-30,-30,-30,-30,-30,-50]

    static func evaluateWhite(_ b: ChessBoard) -> Int {
        var npm = 0
        for s in 0..<64 {
            let t = abs(Int(b.sq[s]))
            if t >= 2 && t <= 5 { npm += values[t] }
        }
        let endgame = npm <= 2600
        var score = 0
        for s in 0..<64 {
            let p = Int(b.sq[s])
            if p == 0 { continue }
            let t = abs(p)
            let white = p > 0
            let r = s >> 3
            let c = s & 7
            let idx = white ? (7 - r) * 8 + c : r * 8 + c
            var v = values[t]
            switch t {
            case 1: v += pawnPST[idx]
            case 2: v += knightPST[idx]
            case 3: v += bishopPST[idx]
            case 4: v += rookPST[idx]
            case 5: v += queenPST[idx]
            default: v += endgame ? kingEndPST[idx] : kingMidPST[idx]
            }
            score += white ? v : -v
        }
        return score
    }

    private func evaluate(_ b: ChessBoard) -> Int {
        let w = ChessAI.evaluateWhite(b)
        return b.whiteToMove ? w : -w
    }

    private func orderScore(_ m: Move, _ b: ChessBoard) -> Int {
        var s = 0
        let victim = abs(Int(b.sq[m.to]))
        let attacker = abs(Int(b.sq[m.from]))
        if victim != 0 {
            s += 10 * ChessAI.values[victim] - ChessAI.values[attacker] + 1000
        } else if attacker == 1 && (m.from & 7) != (m.to & 7) {
            s += 1000 + 900
        }
        if m.promo != 0 { s += ChessAI.values[m.promo] }
        return s
    }

    private func ordered(_ moves: [Move], _ b: ChessBoard) -> [Move] {
        var scored: [(Int, Move)] = []
        scored.reserveCapacity(moves.count)
        for m in moves { scored.append((orderScore(m, b), m)) }
        scored.sort { $0.0 > $1.0 }
        return scored.map { $0.1 }
    }

    private func checkTime() {
        nodes += 1
        if nodes & 1023 == 0 && Date() > deadline { aborted = true }
    }

    private func negamax(_ b: ChessBoard, depth: Int, alpha: Int, beta: Int, ply: Int) -> Int {
        checkTime()
        if aborted { return 0 }
        if b.halfmove >= 100 { return 0 }
        if depth <= 0 { return quiesce(b, alpha: alpha, beta: beta, qdepth: 0) }
        let moves = b.legalMoves()
        if moves.isEmpty {
            return b.inCheck(white: b.whiteToMove) ? -(ChessAI.mate - ply) : 0
        }
        var a = alpha
        for m in ordered(moves, b) {
            var nb = b
            nb.apply(m)
            let score = -negamax(nb, depth: depth - 1, alpha: -beta, beta: -a, ply: ply + 1)
            if aborted { return 0 }
            if score >= beta { return beta }
            if score > a { a = score }
        }
        return a
    }

    private func quiesce(_ b: ChessBoard, alpha: Int, beta: Int, qdepth: Int) -> Int {
        checkTime()
        if aborted { return 0 }
        let stand = evaluate(b)
        if qdepth >= 6 { return stand }
        if stand >= beta { return beta }
        var a = max(alpha, stand)
        var tactical: [Move] = []
        for m in b.pseudoLegalMoves() where b.isCapture(m) || m.promo != 0 { tactical.append(m) }
        for m in ordered(tactical, b) {
            var nb = b
            nb.apply(m)
            if nb.inCheck(white: !nb.whiteToMove) { continue }
            let score = -quiesce(nb, alpha: -beta, beta: -a, qdepth: qdepth + 1)
            if aborted { return 0 }
            if score >= beta { return beta }
            if score > a { a = score }
        }
        return a
    }

    func bestMove(board: ChessBoard, maxDepth: Int, time: Double) -> Move? {
        let legal = board.legalMoves()
        if legal.isEmpty { return nil }
        if legal.count == 1 { return legal[0] }
        deadline = Date().addingTimeInterval(time)
        aborted = false
        nodes = 0
        var best = legal[0]
        var list = ordered(legal, board)
        var depth = 1
        while depth <= maxDepth {
            var bestThis: Move? = nil
            var bestScore = -ChessAI.inf
            var alpha = -ChessAI.inf
            for m in list {
                var nb = board
                nb.apply(m)
                let score = -negamax(nb, depth: depth - 1, alpha: -ChessAI.inf, beta: -alpha, ply: 1)
                if aborted { break }
                if score > bestScore {
                    bestScore = score
                    bestThis = m
                }
                if score > alpha { alpha = score }
            }
            if aborted { break }
            if let b = bestThis {
                best = b
                if let i = list.firstIndex(of: b) {
                    list.remove(at: i)
                    list.insert(b, at: 0)
                }
            }
            if bestScore > ChessAI.mate - 200 { break }
            depth += 1
        }
        return best
    }

    func chooseMove(board: ChessBoard, difficulty: BotDifficulty) -> Move? {
        let legal = board.legalMoves()
        if legal.isEmpty { return nil }
        switch difficulty {
        case .easy:
            if Int.random(in: 0..<100) < 30 { return legal.randomElement() }
            return bestMove(board: board, maxDepth: 2, time: 0.6)
        case .medium:
            return bestMove(board: board, maxDepth: 3, time: 1.2)
        case .hard:
            return bestMove(board: board, maxDepth: 6, time: 2.5)
        }
    }
}

final class SoundEngine: NSObject {
    static let shared = SoundEngine()
    private var players: [String: AVAudioPlayer] = [:]
    private var bgPlayer: AVAudioPlayer?
    private let speechSynth = AVSpeechSynthesizer()

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        for n in ["move", "capture", "blackhole", "select", "click", "check", "win"] { loadSound(n) }
        players["blackhole"]?.volume = 0.9
        players["select"]?.volume = 0.75
        players["click"]?.volume = 0.75
        if let url = Bundle.main.url(forResource: "ambient", withExtension: "wav") {
            bgPlayer = try? AVAudioPlayer(contentsOf: url)
            bgPlayer?.numberOfLoops = -1
            bgPlayer?.volume = 0.30
            bgPlayer?.prepareToPlay()
        }
    }

    private func loadSound(_ name: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            players[name] = try? AVAudioPlayer(contentsOf: url)
            players[name]?.prepareToPlay()
        }
    }

    func play(_ name: String, enabled: Bool = true) {
        guard enabled else { return }
        DispatchQueue.main.async {
            if let p = self.players[name] {
                p.currentTime = 0
                p.play()
            } else {
                AudioServicesPlaySystemSound(1104)
            }
        }
    }

    func toggleMusic(_ on: Bool) {
        DispatchQueue.main.async {
            if on { self.bgPlayer?.play() } else { self.bgPlayer?.pause() }
        }
    }

    func speak(_ text: String, enabled: Bool = true) {
        guard enabled else { return }
        DispatchQueue.main.async {
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: "ru-RU")
            u.rate = 0.48
            u.pitchMultiplier = 0.9
            self.speechSynth.speak(u)
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let sender: String
    let text: String
}

struct PromotionRequest: Equatable {
    var from: Int
    var to: Int
    var white: Bool
}

struct HistoryEntry {
    var board: ChessBoard
    var prevLastMove: Move?
    var prevNotation: String
}

struct SaveSlot: Identifiable, Codable {
    var id: String
    var title: String
    var dateString: String
    var board: ChessBoard
    var playerSide: Side
    var mode: GameMode
    var difficulty: BotDifficulty
    var timeControl: TimeControl
    var whiteSeconds: Int
    var blackSeconds: Int
    var lastMove: Move?
}

final class GameManager: ObservableObject {
    @Published var inMenu = true
    @Published var isPaused = false
    @Published var statusText = "Выбери режим и начни партию"
    @Published var lastMoveNotation = "Начало партии"
    @Published var isARMode = false {
        didSet {
            if isARMode && controlMode == .drag { controlMode = .tap }
        }
    }
    @Published var isAnimating = false
    @Published var isThinking = false
    @Published var isCheckNow = false
    @Published var turnIsWhite = true
    @Published var gameResult: GameResult? = nil
    @Published var pendingPromotion: PromotionRequest? = nil
    @Published var undoCount = 3
    @Published var whiteSeconds = 300
    @Published var blackSeconds = 300
    @Published var isClockActive = false
    @Published var saveSlots: [SaveSlot] = []
    @Published var isAdviceThinking = false
    @Published var chat: [ChatMessage] = [
        ChatMessage(sender: "Гроссмейстер AI", text: "Приветствую! Играем по правилам FIDE. Выбери фигуру — доступные поля подсветятся зелёным.")
    ]

    @Published var playerSide: Side = .white { didSet { saveSettings() } }
    @Published var mode: GameMode = .vsBot { didSet { saveSettings() } }
    @Published var controlMode: ControlMode = .tap {
        didSet {
            saveSettings()
            applyControlMode()
        }
    }
    @Published var difficulty: BotDifficulty = .hard { didSet { saveSettings() } }
    @Published var timeControl: TimeControl = .rapid5 { didSet { saveSettings() } }
    @Published var sfxEnabled = true { didSet { saveSettings() } }
    @Published var musicEnabled = true { didSet { saveSettings(); SoundEngine.shared.toggleMusic(musicEnabled) } }
    @Published var voiceEnabled = true { didSet { saveSettings() } }
    @Published var showHints = true { didSet { saveSettings(); refreshHighlights() } }
    @Published var gyroEnabled = false {
        didSet {
            saveSettings()
            space.setGyroEnabled(gyroEnabled)
        }
    }
    @Published var graphicsQuality: GraphicsQuality = .ultra {
        didSet {
            saveSettings()
            space.applyQuality(graphicsQuality)
        }
    }

    let boardCtl = BoardController()
    let space = SpaceScene()
    weak var arSceneView: ARSCNView?
    var arBoardAnchorNode: SCNNode?

    private var board = ChessBoard.initial()
    private var history: [HistoryEntry] = []
    private var positionCounts: [PositionKey: Int] = [:]
    private var selectedSquare: Int? = nil
    private var legalForSelected: [Move] = []
    private var lastMove: Move? = nil
    private var gameToken = 0
    private var pendingBotMove: Move? = nil
    private var isLoadingSettings = false
    private var draggingSourceSquare: Int? = nil

    init() {
        isLoadingSettings = true
        loadSettings()
        isLoadingSettings = false
        loadSavesFromDisk()
        positionCounts = [board.key: 1]
        boardCtl.reset(board: board, flipped: false)
        space.applyQuality(graphicsQuality)
        space.setGyroEnabled(gyroEnabled)
        applyControlMode()
        SoundEngine.shared.toggleMusic(musicEnabled)
    }

    var isHumanTurn: Bool {
        if mode == .passAndPlay { return true }
        return board.whiteToMove == (playerSide == .white)
    }

    var shouldFlipCamera: Bool { mode == .vsBot && playerSide == .black }
    var hasAutoSave: Bool { saveSlots.contains { $0.id == "auto" } }

    private func saveSettings() {
        if isLoadingSettings { return }
        let d = UserDefaults.standard
        d.set(sfxEnabled, forKey: "Vibe_Sfx")
        d.set(musicEnabled, forKey: "Vibe_Music")
        d.set(voiceEnabled, forKey: "Vibe_Voice")
        d.set(showHints, forKey: "Vibe_Hints")
        d.set(gyroEnabled, forKey: "Vibe_Gyro")
        d.set(controlMode.rawValue, forKey: "Vibe_CtrlMode")
        d.set(graphicsQuality.rawValue, forKey: "Vibe_Quality")
        d.set(mode.rawValue, forKey: "Vibe_Mode")
        d.set(difficulty.rawValue, forKey: "Vibe_Diff")
        d.set(timeControl.rawValue, forKey: "Vibe_Time")
        d.set(playerSide.rawValue, forKey: "Vibe_Side2")
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        if d.object(forKey: "Vibe_Sfx") != nil { sfxEnabled = d.bool(forKey: "Vibe_Sfx") }
        if d.object(forKey: "Vibe_Music") != nil { musicEnabled = d.bool(forKey: "Vibe_Music") }
        if d.object(forKey: "Vibe_Voice") != nil { voiceEnabled = d.bool(forKey: "Vibe_Voice") }
        if d.object(forKey: "Vibe_Hints") != nil { showHints = d.bool(forKey: "Vibe_Hints") }
        if d.object(forKey: "Vibe_Gyro") != nil { gyroEnabled = d.bool(forKey: "Vibe_Gyro") }
        if let m = d.string(forKey: "Vibe_CtrlMode"), let v = ControlMode(rawValue: m) { controlMode = v }
        if let m = d.string(forKey: "Vibe_Quality"), let v = GraphicsQuality(rawValue: m) { graphicsQuality = v }
        if let m = d.string(forKey: "Vibe_Mode"), let v = GameMode(rawValue: m) { mode = v }
        if let m = d.string(forKey: "Vibe_Diff"), let v = BotDifficulty(rawValue: m) { difficulty = v }
        if let m = d.string(forKey: "Vibe_Time"), let v = TimeControl(rawValue: m) { timeControl = v }
        if let m = d.string(forKey: "Vibe_Side2"), let v = Side(rawValue: m) { playerSide = v }
    }

    func applyControlMode() {
        let usePhysics = (controlMode == .drag && !isARMode)
        space.setOrbitalMotionPaused(usePhysics)
        boardCtl.setPhysicsEnabled(usePhysics, board: board)
    }

    func toggleControlMode() {
        controlMode = (controlMode == .tap) ? .drag : .tap
        SoundEngine.shared.play("click", enabled: sfxEnabled)
    }

    func realignPhysicsPieces() {
        boardCtl.reset(board: board, flipped: shouldFlipCamera)
        refreshHighlights()
        SoundEngine.shared.play("select", enabled: sfxEnabled)
    }

    func startNewGame() {
        gameToken += 1
        pendingBotMove = nil
        draggingSourceSquare = nil
        board = ChessBoard.initial()
        history.removeAll()
        positionCounts = [board.key: 1]
        selectedSquare = nil
        legalForSelected = []
        lastMove = nil
        gameResult = nil
        pendingPromotion = nil
        isAnimating = false
        isThinking = false
        isPaused = false
        isCheckNow = false
        undoCount = 3
        lastMoveNotation = "Партия началась"
        let t = timeControl.initialSeconds
        whiteSeconds = t
        blackSeconds = t
        isClockActive = (timeControl != .infinite)
        inMenu = false
        boardCtl.reset(board: board, flipped: shouldFlipCamera)
        applyControlMode()
        space.focus(flipped: shouldFlipCamera)
        refreshHighlights()
        updateStatus()
        autoSave()
        if mode == .vsBot && playerSide == .black {
            SoundEngine.shared.speak("Белые ходят первыми.", enabled: voiceEnabled)
            triggerBotMove()
        } else {
            SoundEngine.shared.speak("Твой ход.", enabled: voiceEnabled)
        }
    }

    func continueGame() {
        if let slot = saveSlots.first(where: { $0.id == "auto" }) { loadFromSlot(slot) }
    }

    func pauseGame() {
        if inMenu { return }
        isPaused = true
    }

    func resumeGame() {
        isPaused = false
        if let m = pendingBotMove {
            pendingBotMove = nil
            play(m)
        }
    }

    func exitToMenu() {
        gameToken += 1
        pendingBotMove = nil
        draggingSourceSquare = nil
        boardCtl.endDrag(releaseVelocity: SCNVector3Zero)
        isThinking = false
        isAnimating = false
        isPaused = false
        selectedSquare = nil
        legalForSelected = []
        pendingPromotion = nil
        inMenu = true
        boardCtl.setLift(nil)
        boardCtl.setHighlights(selected: nil, targets: [:], last: nil, check: nil)
        space.startMenuOrbit()
    }

    func restartGame() {
        startNewGame()
    }

    func tapSquare(_ s: Int) {
        guard s >= 0, s < 64 else { return }
        guard !inMenu, !isPaused, !isAnimating, !isThinking, gameResult == nil, pendingPromotion == nil else { return }
        guard isHumanTurn else { return }
        if selectedSquare != nil && legalForSelected.contains(where: { $0.to == s }) {
            attemptMove(to: s)
            return
        }
        let piece = board.sq[s]
        if piece != 0 && (piece > 0) == board.whiteToMove {
            if selectedSquare == s {
                clearSelection()
            } else {
                select(s)
            }
        } else {
            clearSelection()
        }
    }

    func beginPieceDrag(square s: Int, atLocal: SCNVector3) -> Bool {
        guard controlMode == .drag, !isARMode, !inMenu, !isPaused, !isAnimating else { return false }
        guard s >= 0, s < 64 else { return false }
        guard boardCtl.beginDrag(square: s, atLocal: atLocal) else { return false }
        draggingSourceSquare = s
        if !isThinking, gameResult == nil, pendingPromotion == nil, isHumanTurn {
            let p = board.sq[s]
            if p != 0 && (p > 0) == board.whiteToMove {
                selectedSquare = s
                legalForSelected = board.legalMoves().filter { $0.from == s }
                refreshHighlights()
            }
        }
        SoundEngine.shared.play("select", enabled: sfxEnabled)
        return true
    }

    func updatePieceDrag(toLocal: SCNVector3) {
        boardCtl.updateDrag(toLocal: toLocal)
    }

    func endPieceDrag(atLocal: SCNVector3?, releaseVelocity: SCNVector3) {
        boardCtl.endDrag(releaseVelocity: releaseVelocity)
        guard let from = draggingSourceSquare else { return }
        draggingSourceSquare = nil

        if let loc = atLocal,
           !inMenu, !isPaused, !isAnimating, !isThinking, gameResult == nil, pendingPromotion == nil, isHumanTurn {
            let p = board.sq[from]
            if p != 0 && (p > 0) == board.whiteToMove {
                let col = Int(round(loc.x + 3.5))
                let row = Int(round(3.5 - loc.z))
                if col >= 0 && col < 8 && row >= 0 && row < 8 {
                    let targetSq = row * 8 + col
                    let tp = boardCtl.pos(targetSq)
                    let dx = loc.x - tp.x
                    let dz = loc.z - tp.z
                    if (dx * dx + dz * dz) < 0.65 * 0.65,
                       legalForSelected.contains(where: { $0.from == from && $0.to == targetSq }) {
                        selectedSquare = from
                        attemptMove(to: targetSq)
                        return
                    }
                }
            }
        }
    }

    func knockOverPiece(at square: Int, viewDir: SCNVector3) {
        guard controlMode == .drag, !isARMode, !inMenu, !isPaused, !isAnimating else { return }
        boardCtl.topplePiece(at: square, viewDir: viewDir)
        SoundEngine.shared.play("click", enabled: sfxEnabled)
        haptic(.medium)
    }

    private func select(_ s: Int) {
        selectedSquare = s
        legalForSelected = board.legalMoves().filter { $0.from == s }
        if controlMode == .tap { boardCtl.setLift(s) }
        SoundEngine.shared.play("select", enabled: sfxEnabled)
        refreshHighlights()
    }

    private func clearSelection() {
        if selectedSquare == nil { return }
        selectedSquare = nil
        legalForSelected = []
        boardCtl.setLift(nil)
        refreshHighlights()
    }

    private func attemptMove(to t: Int) {
        guard let from = selectedSquare else { return }
        let candidates = legalForSelected.filter { $0.to == t }
        guard let first = candidates.first else { return }
        if candidates.count > 1 {
            pendingPromotion = PromotionRequest(from: from, to: t, white: board.sq[from] > 0)
            return
        }
        play(first)
    }

    func choosePromotion(_ type: Int) {
        guard let req = pendingPromotion else { return }
        pendingPromotion = nil
        if let m = legalForSelected.first(where: { $0.from == req.from && $0.to == req.to && $0.promo == type }) {
            play(m)
        }
    }

    func cancelPromotion() {
        pendingPromotion = nil
    }

    private func play(_ m: Move) {
        guard !isAnimating, gameResult == nil else { return }
        let before = board
        var after = before
        after.apply(m)
        let capture = before.isCapture(m)
        let note = describeMove(m, before: before, after: after)

        history.append(HistoryEntry(board: before, prevLastMove: lastMove, prevNotation: lastMoveNotation))
        board = after
        lastMove = m
        lastMoveNotation = note
        selectedSquare = nil
        legalForSelected = []
        isAnimating = true
        isCheckNow = false
        boardCtl.setHighlights(selected: nil, targets: [:], last: m, check: nil)

        SoundEngine.shared.play(capture ? "capture" : "move", enabled: sfxEnabled)
        if capture {
            let tok = gameToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self = self, self.gameToken == tok else { return }
                SoundEngine.shared.play("blackhole", enabled: self.sfxEnabled)
            }
        }
        haptic(capture ? .heavy : .medium)
        if m.promo != 0 { SoundEngine.shared.speak("Пешка превращается!", enabled: voiceEnabled) }

        let token = gameToken
        boardCtl.animate(move: m, before: before, after: after) { [weak self] in
            guard let self = self, self.gameToken == token else { return }
            self.finishMove()
        }
    }

    private func finishMove() {
        isAnimating = false
        isCheckNow = board.inCheck(white: board.whiteToMove)
        positionCounts[board.key, default: 0] += 1
        evaluateGameState()
        refreshHighlights()
        if gameResult != nil { return }
        if isCheckNow {
            SoundEngine.shared.play("check", enabled: sfxEnabled)
            SoundEngine.shared.speak("Шах!", enabled: voiceEnabled)
        } else {
            SoundEngine.shared.play("click", enabled: sfxEnabled)
        }
        updateStatus()
        autoSave()
        if mode == .vsBot && !isHumanTurn { triggerBotMove() }
    }

    private func evaluateGameState() {
        let legal = board.legalMoves()
        if legal.isEmpty {
            if isCheckNow {
                endGame(.checkmate(winner: board.whiteToMove ? .black : .white))
            } else {
                endGame(.stalemate)
            }
        } else if board.insufficientMaterial() {
            endGame(.insufficient)
        } else if board.halfmove >= 100 {
            endGame(.fiftyMove)
        } else if (positionCounts[board.key] ?? 0) >= 3 {
            endGame(.repetition)
        }
    }

    private func endGame(_ result: GameResult) {
        gameToken += 1
        gameResult = result
        isThinking = false
        isAnimating = false
        pendingBotMove = nil
        selectedSquare = nil
        legalForSelected = []
        statusText = result.title
        SoundEngine.shared.play("win", enabled: sfxEnabled)
        SoundEngine.shared.speak(result.title, enabled: voiceEnabled)
        haptic(.heavy)
        if case .checkmate = result { boardCtl.celebrate() }
        saveSlots.removeAll { $0.id == "auto" }
        persistSlots()
    }

    private func updateStatus() {
        turnIsWhite = board.whiteToMove
        if let r = gameResult {
            statusText = r.title
            return
        }
        let side = board.whiteToMove ? "Белые" : "Чёрные"
        if mode == .vsBot {
            if isHumanTurn {
                statusText = isCheckNow ? "Шах! Твой ход" : "Твой ход"
            } else {
                statusText = "Гроссмейстер думает…"
            }
        } else {
            statusText = isCheckNow ? "Шах! Ходят \(side.lowercased())" : "Ходят \(side.lowercased())"
        }
    }

    private func refreshHighlights() {
        var targets: [Int: Bool] = [:]
        if showHints {
            for m in legalForSelected { targets[m.to] = board.isCapture(m) }
        }
        var checkSq: Int? = nil
        if isCheckNow {
            let k = board.kingSquare(white: board.whiteToMove)
            if k >= 0 { checkSq = k }
        }
        boardCtl.setHighlights(selected: selectedSquare, targets: targets, last: lastMove, check: checkSq)
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func triggerBotMove() {
        guard !inMenu, gameResult == nil, mode == .vsBot, !isHumanTurn, !isThinking else { return }
        isThinking = true
        updateStatus()
        let snapshot = board
        let diff = difficulty
        let token = gameToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ai = ChessAI()
            let mv = ai.chooseMove(board: snapshot, difficulty: diff)
            DispatchQueue.main.async {
                guard let self = self, self.gameToken == token, !self.inMenu, self.gameResult == nil else { return }
                self.isThinking = false
                guard let m = mv else { return }
                if self.isPaused || self.isAnimating {
                    self.pendingBotMove = m
                    return
                }
                self.play(m)
            }
        }
    }

    func performUndo() {
        guard !isAnimating, !isThinking, undoCount > 0, !history.isEmpty, pendingPromotion == nil else { return }
        gameToken += 1
        pendingBotMove = nil
        while let entry = history.popLast() {
            let k = board.key
            if let n = positionCounts[k] {
                if n <= 1 { positionCounts.removeValue(forKey: k) } else { positionCounts[k] = n - 1 }
            }
            board = entry.board
            lastMove = entry.prevLastMove
            lastMoveNotation = entry.prevNotation
            if mode == .passAndPlay || isHumanTurn { break }
        }
        undoCount -= 1
        gameResult = nil
        selectedSquare = nil
        legalForSelected = []
        isCheckNow = board.inCheck(white: board.whiteToMove)
        if timeControl != .infinite {
            whiteSeconds = max(whiteSeconds, 15)
            blackSeconds = max(blackSeconds, 15)
        }
        boardCtl.reset(board: board, flipped: shouldFlipCamera)
        refreshHighlights()
        updateStatus()
        statusText = "Ход отменён. " + statusText
        SoundEngine.shared.play("select", enabled: sfxEnabled)
        haptic(.medium)
        if mode == .vsBot && !isHumanTurn { triggerBotMove() }
    }

    func onClockTick() {
        guard isClockActive, !inMenu, !isPaused, gameResult == nil, pendingPromotion == nil else { return }
        if board.whiteToMove {
            if whiteSeconds > 0 { whiteSeconds -= 1 }
            if whiteSeconds == 0 { endGame(.timeout(loser: .white)) }
        } else {
            if blackSeconds > 0 { blackSeconds -= 1 }
            if blackSeconds == 0 { endGame(.timeout(loser: .black)) }
        }
    }

    func saveToSlot(slotId: String, title: String, silent: Bool = false) {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        let slot = SaveSlot(id: slotId, title: title, dateString: f.string(from: Date()), board: board,
                            playerSide: playerSide, mode: mode, difficulty: difficulty, timeControl: timeControl,
                            whiteSeconds: whiteSeconds, blackSeconds: blackSeconds, lastMove: lastMove)
        saveSlots.removeAll { $0.id == slotId }
        saveSlots.append(slot)
        persistSlots()
        if !silent { SoundEngine.shared.play("select", enabled: sfxEnabled) }
    }

    func deleteSlot(_ id: String) {
        saveSlots.removeAll { $0.id == id }
        persistSlots()
    }

    private func autoSave() {
        if gameResult != nil { return }
        saveToSlot(slotId: "auto", title: "Автосейв", silent: true)
    }

    private func persistSlots() {
        if let data = try? JSONEncoder().encode(saveSlots) {
            UserDefaults.standard.set(data, forKey: "Vibe_Slots2")
        }
    }

    private func loadSavesFromDisk() {
        if let data = UserDefaults.standard.data(forKey: "Vibe_Slots2"),
           let s = try? JSONDecoder().decode([SaveSlot].self, from: data) {
            saveSlots = s.filter { $0.board.sq.count == 64 }
        }
    }

    func loadFromSlot(_ slot: SaveSlot) {
        guard slot.board.sq.count == 64 else { return }
        gameToken += 1
        pendingBotMove = nil
        mode = slot.mode
        difficulty = slot.difficulty
        playerSide = slot.playerSide
        timeControl = slot.timeControl
        board = slot.board
        history.removeAll()
        positionCounts = [board.key: 1]
        lastMove = slot.lastMove
        selectedSquare = nil
        legalForSelected = []
        whiteSeconds = slot.whiteSeconds
        blackSeconds = slot.blackSeconds
        isClockActive = (slot.timeControl != .infinite)
        gameResult = nil
        pendingPromotion = nil
        isAnimating = false
        isThinking = false
        isPaused = false
        isCheckNow = board.inCheck(white: board.whiteToMove)
        undoCount = 3
        lastMoveNotation = "Партия загружена"
        inMenu = false
        boardCtl.reset(board: board, flipped: shouldFlipCamera)
        applyControlMode()
        space.focus(flipped: shouldFlipCamera)
        refreshHighlights()
        updateStatus()
        SoundEngine.shared.play("select", enabled: sfxEnabled)
        evaluateGameState()
        if gameResult == nil && mode == .vsBot && !isHumanTurn { triggerBotMove() }
    }

    func sendUserMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        chat.append(ChatMessage(sender: "Ты", text: trimmed))
        let lower = trimmed.lowercased()
        if lower.contains("лучш") || lower.contains("ход") || lower.contains("совет") {
            requestAdvice()
        } else if lower.contains("оцен") || lower.contains("шанс") || lower.contains("позици") {
            requestEvaluation()
        } else {
            reply("Следи за безопасностью короля, развивай фигуры и занимай центр.")
        }
    }

    private func reply(_ text: String) {
        chat.append(ChatMessage(sender: "Гроссмейстер AI", text: text))
        SoundEngine.shared.speak(text, enabled: voiceEnabled)
    }

    private func requestAdvice() {
        if inMenu || gameResult != nil {
            reply("Сначала начни партию.")
            return
        }
        if isAdviceThinking { return }
        isAdviceThinking = true
        let snap = board
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ai = ChessAI()
            let mv = ai.bestMove(board: snap, maxDepth: 4, time: 1.5)
            var text = "Ходов нет."
            if let m = mv {
                var after = snap
                after.apply(m)
                text = "Советую сыграть " + describeMove(m, before: snap, after: after) + "."
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAdviceThinking = false
                self.reply(text)
            }
        }
    }

    private func requestEvaluation() {
        let cp = ChessAI.evaluateWhite(board)
        let pawns = Double(cp) / 100.0
        let num = String(format: "%+.2f", pawns)
        if abs(cp) < 40 {
            reply("Позиция примерно равная (\(num)).")
        } else if cp > 0 {
            reply("Перевес у белых: \(num).")
        } else {
            reply("Перевес у чёрных: \(num).")
        }
    }

    func attachBoardToSpace() {
        arBoardAnchorNode = nil
        boardCtl.root.removeFromParentNode()
        boardCtl.root.position = SCNVector3Zero
        boardCtl.root.eulerAngles = SCNVector3Zero
        space.boardMount.addChildNode(boardCtl.root)
        applyControlMode()
    }

    func attachBoard(to node: SCNNode) {
        boardCtl.root.removeFromParentNode()
        boardCtl.root.position = SCNVector3Zero
        boardCtl.root.eulerAngles = SCNVector3Zero
        node.addChildNode(boardCtl.root)
        boardCtl.setPhysicsEnabled(false, board: board)
    }
}

struct TextureCache {
    static let wood = load("wood_texture")
    static let woodNormal = load("wood_normal")
    static let woodRough = load("wood_rough")
    static let marble = load("marble_texture")
    static let marbleNormal = load("marble_normal")
    static let marbleRough = load("marble_rough")
    static let pieceWhite = load("piece_white")
    static let pieceBlack = load("piece_black")
    static let pieceNormal = load("piece_normal")
    static let pieceRough = load("piece_rough")
    static let mercury = load("mercury_texture")
    static let mercuryNormal = load("mercury_normal")
    static let venus = load("venus_texture")
    static let earth = load("earth_texture")
    static let earthClouds = load("earth_clouds")
    static let mars = load("mars_texture")
    static let marsNormal = load("mars_normal")
    static let moon = load("moon_texture")
    static let moonNormal = load("moon_normal")
    static let jupiter = load("jupiter_texture")
    static let saturn = load("saturn_texture")
    static let saturnRing = load("saturn_ring")
    static let uranus = load("uranus_texture")
    static let uranusRing = load("uranus_ring")
    static let neptune = load("neptune_texture")
    static let pluto = load("pluto_texture")
    static let asteroid = load("asteroid_texture")
    static let asteroidNormal = load("asteroid_normal")
    static let sun = load("sun_texture")
    static let sky = load("sky_nebula")
    static let env = load("env_studio")
    static let glow = load("fx_glow")
    static let glowWarm = load("fx_glow_warm")
    static let dust = load("fx_dust")
    static let spark = load("fx_spark")
    static let streak = load("fx_streak")
    static let burst = load("fx_burst")
    static let beam = load("fx_beam")
    static let halo = load("fx_halo")
    static let haloWarm = load("fx_halo_warm")
    static let blackholeDisk = load("fx_blackhole_disk")
    static let blackholeRing = load("fx_blackhole_ring")
    static let nebulaCyan = load("fx_nebula_cyan")
    static let nebulaPurple = load("fx_nebula_purple")
    static let nebulaGold = load("fx_nebula_gold")
    static let nebulaEmerald = load("fx_nebula_emerald")
    static let nebulaCrimson = load("fx_nebula_crimson")
    static let cometTail = load("fx_comet_tail")
    static let shockwave = load("fx_shockwave")
    static let flareRing = load("fx_flare_ring")
    static let hlCyan = load("hl_tile_cyan")
    static let hlYellow = load("hl_tile_yellow")
    static let hlRed = load("hl_tile_red")
    static let hlHint = load("hl_tile_hint")
    static let hlDot = load("hl_dot_green")
    static let hlRing = load("hl_ring_red")

    private static func load(_ name: String) -> UIImage? {
        if let path = Bundle.main.path(forResource: name, ofType: "png") { return UIImage(contentsOfFile: path) }
        return UIImage(named: name)
    }
}

enum Lathe {
    static func geometry(_ profile: [(Float, Float)], segments: Int = 64) -> SCNGeometry {
        let n = profile.count
        var segN: [(Float, Float)] = []
        var cum = [Float](repeating: 0, count: n)
        for i in 0..<(n - 1) {
            let dr = profile[i + 1].0 - profile[i].0
            let dy = profile[i + 1].1 - profile[i].1
            let len = max(0.0001, (dr * dr + dy * dy).squareRoot())
            segN.append((dy / len, -dr / len))
            cum[i + 1] = cum[i] + len
        }
        let total = max(0.0001, cum[n - 1])
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        for i in 0..<n {
            var nn = segN[min(i, n - 2)]
            if i > 0 && i < n - 1 {
                let a = segN[i - 1]
                let b = segN[i]
                let sx = a.0 + b.0
                let sy = a.1 + b.1
                let l = (sx * sx + sy * sy).squareRoot()
                if l > 0.0001 { nn = (sx / l, sy / l) }
            }
            let r = profile[i].0
            let y = profile[i].1
            let v = CGFloat(cum[i] / total)
            for j in 0...segments {
                let a = Float(j) / Float(segments) * 2 * Float.pi
                let c = cos(a)
                let s = sin(a)
                vertices.append(SCNVector3(r * c, y, r * s))
                normals.append(SCNVector3(nn.0 * c, nn.1, nn.0 * s))
                uvs.append(CGPoint(x: CGFloat(j) / CGFloat(segments), y: v))
            }
        }
        var indices: [Int32] = []
        let cols = segments + 1
        for i in 0..<(n - 1) {
            for j in 0..<segments {
                let a = Int32(i * cols + j)
                let b = Int32((i + 1) * cols + j)
                let c = Int32(i * cols + j + 1)
                let d = Int32((i + 1) * cols + j + 1)
                indices.append(contentsOf: [a, b, c, c, b, d])
            }
        }
        let vs = SCNGeometrySource(vertices: vertices)
        let ns = SCNGeometrySource(normals: normals)
        let ts = SCNGeometrySource(textureCoordinates: uvs)
        let el = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vs, ns, ts], elements: [el])
    }
}

enum PieceBuilder {
    private static var templates: [Int: SCNNode] = [:]

    static func height(for code: Int8) -> Float {
        switch abs(Int(code)) {
        case 1: return 0.89
        case 2: return 1.15
        case 3: return 1.35
        case 4: return 1.08
        case 5: return 1.42
        default: return 1.54
        }
    }

    static func node(for code: Int8) -> SCNNode {
        let key = Int(code)
        if let t = templates[key] { return t.clone() }
        let t = build(code)
        templates[key] = t
        return t.clone()
    }

    static let gold: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(red: 1.0, green: 0.78, blue: 0.32, alpha: 1)
        m.metalness.contents = 1.0
        m.roughness.contents = 0.16
        m.clearCoat.contents = 0.85
        m.clearCoatRoughness.contents = 0.04
        m.shaderModifiers = [
            SCNShaderModifierEntryPoint.fragment:
                "#pragma body\nfloat3 n = normalize(_surface.normal);\nfloat3 v = normalize(_surface.view);\nfloat rim = pow(1.0 - saturate(abs(dot(n, v))), 3.2);\nfloat glint = pow(saturate(dot(reflect(-v, n), normalize(float3(-0.2, 0.7, -0.7)))), 18.0);\n_output.color.rgb += float3(1.0, 0.82, 0.38) * (rim * 0.25 + glint * 0.35);\n"
        ]
        return m
    }()

    private static func bodyMaterial(white: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        let tf = SCNMatrix4MakeScale(2, 1.5, 1)
        let tex = white ? TextureCache.pieceWhite : TextureCache.pieceBlack
        if let img = tex {
            m.diffuse.contents = img
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = tf
        } else {
            m.diffuse.contents = white ? UIColor(red: 0.90, green: 0.86, blue: 0.78, alpha: 1) : UIColor(red: 0.12, green: 0.10, blue: 0.09, alpha: 1)
        }
        if let nm = TextureCache.pieceNormal {
            m.normal.contents = nm
            m.normal.wrapS = .repeat
            m.normal.wrapT = .repeat
            m.normal.contentsTransform = tf
            m.normal.intensity = 0.65
        }
        if let rm = TextureCache.pieceRough {
            m.roughness.contents = rm
            m.roughness.wrapS = .repeat
            m.roughness.wrapT = .repeat
            m.roughness.contentsTransform = tf
        } else {
            m.roughness.contents = white ? 0.18 : 0.11
        }
        m.metalness.contents = white ? 0.02 : 0.24
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.045
        m.shaderModifiers = [
            SCNShaderModifierEntryPoint.fragment: white
                ? "#pragma body\nfloat3 n = normalize(_surface.normal);\nfloat3 v = normalize(_surface.view);\nfloat fres = pow(1.0 - saturate(abs(dot(n, v))), 3.6);\n_output.color.rgb += float3(1.0, 0.88, 0.68) * fres * 0.10 + float3(0.32, 0.56, 0.96) * fres * 0.08;\n"
                : "#pragma body\nfloat3 n = normalize(_surface.normal);\nfloat3 v = normalize(_surface.view);\nfloat fres = pow(1.0 - saturate(abs(dot(n, v))), 3.2);\n_output.color.rgb += float3(0.95, 0.75, 0.42) * fres * 0.18 + float3(0.35, 0.65, 1.0) * fres * 0.16;\n"
        ]
        return m
    }

    private static func lathe(_ p: [(Float, Float)], _ mat: SCNMaterial) -> SCNNode {
        let g = Lathe.geometry(p)
        g.materials = [mat]
        return SCNNode(geometry: g)
    }

    private static func ring(_ radius: CGFloat, _ pipe: CGFloat, _ y: Float) -> SCNNode {
        let t = SCNTorus(ringRadius: radius, pipeRadius: pipe)
        t.ringSegmentCount = 48
        t.pipeSegmentCount = 10
        t.materials = [gold]
        let n = SCNNode(geometry: t)
        n.position = SCNVector3(0, y, 0)
        return n
    }

    private static func ball(_ r: CGFloat, _ x: Float, _ y: Float, _ z: Float, _ mat: SCNMaterial) -> SCNNode {
        let s = SCNSphere(radius: r)
        s.segmentCount = 24
        s.materials = [mat]
        let n = SCNNode(geometry: s)
        n.position = SCNVector3(x, y, z)
        return n
    }

    private static let pawnProfile: [(Float, Float)] = [
        (0, 0), (0.38, 0), (0.38, 0.04), (0.36, 0.06),
        (0.36, 0.075), (0.32, 0.095), (0.31, 0.12), (0.26, 0.14),
        (0.22, 0.17), (0.155, 0.26), (0.125, 0.38), (0.12, 0.46),
        (0.2, 0.485), (0.215, 0.505), (0.2, 0.525), (0.125, 0.55),
        (0.11, 0.58), (0.15, 0.62), (0.18, 0.68), (0.19, 0.74),
        (0.17, 0.8), (0.12, 0.85), (0.06, 0.875), (0, 0.885)
    ]
    private static let rookProfile: [(Float, Float)] = [
        (0, 0), (0.38, 0), (0.38, 0.04), (0.36, 0.06),
        (0.36, 0.075), (0.32, 0.095), (0.31, 0.12), (0.26, 0.14),
        (0.235, 0.16), (0.21, 0.24), (0.195, 0.4), (0.19, 0.58),
        (0.205, 0.6), (0.27, 0.64), (0.29, 0.665), (0.29, 0.69),
        (0.265, 0.71), (0.265, 0.92), (0.3, 0.93), (0.3, 1),
        (0.235, 1), (0.235, 0.94), (0, 0.94)
    ]
    private static let bishopProfile: [(Float, Float)] = [
        (0, 0), (0.38, 0), (0.38, 0.04), (0.36, 0.06),
        (0.36, 0.075), (0.32, 0.095), (0.31, 0.12), (0.26, 0.14),
        (0.22, 0.17), (0.165, 0.3), (0.125, 0.45), (0.12, 0.58),
        (0.2, 0.605), (0.215, 0.625), (0.2, 0.645), (0.125, 0.67),
        (0.13, 0.7), (0.19, 0.76), (0.22, 0.86), (0.21, 0.96),
        (0.17, 1.06), (0.11, 1.15), (0.07, 1.2), (0.09, 1.225),
        (0.09, 1.255), (0.065, 1.285), (0.03, 1.31), (0, 1.315)
    ]
    private static let queenProfile: [(Float, Float)] = [
        (0, 0), (0.38, 0), (0.38, 0.04), (0.36, 0.06),
        (0.36, 0.075), (0.32, 0.095), (0.31, 0.12), (0.26, 0.14),
        (0.23, 0.18), (0.17, 0.32), (0.135, 0.5), (0.125, 0.68),
        (0.21, 0.7), (0.225, 0.73), (0.205, 0.76), (0.135, 0.79),
        (0.17, 0.86), (0.22, 0.96), (0.265, 1.06), (0.29, 1.15),
        (0.3, 1.2), (0.26, 1.22), (0.2, 1.2), (0.12, 1.17),
        (0, 1.17)
    ]
    private static let kingProfile: [(Float, Float)] = [
        (0, 0), (0.38, 0), (0.38, 0.04), (0.36, 0.06),
        (0.36, 0.075), (0.32, 0.095), (0.31, 0.12), (0.26, 0.14),
        (0.23, 0.18), (0.175, 0.32), (0.14, 0.52), (0.13, 0.72),
        (0.22, 0.745), (0.235, 0.775), (0.215, 0.805), (0.14, 0.835),
        (0.185, 0.92), (0.235, 1.03), (0.265, 1.13), (0.275, 1.21),
        (0.235, 1.235), (0.15, 1.22), (0.07, 1.2), (0, 1.2)
    ]
    private static let knightProfile: [(Float, Float)] = [
        (0, 0), (0.38, 0), (0.38, 0.04), (0.36, 0.06),
        (0.36, 0.075), (0.32, 0.095), (0.31, 0.12), (0.26, 0.14),
        (0.235, 0.17), (0.205, 0.24), (0.19, 0.32), (0, 0.34)
    ]

    private static let knightHeadPts: [(CGFloat, CGFloat)] = [
        (-0.0438, 0), (0.0237, 0), (0.0827, 0.0028), (0.133, 0.0084),
        (0.1747, 0.0169), (0.2078, 0.0281), (0.2323, 0.0422), (0.2483, 0.0591),
        (0.2556, 0.0788), (0.2544, 0.1013), (0.252, 0.1244), (0.2486, 0.1481),
        (0.2441, 0.1725), (0.2384, 0.1975), (0.2317, 0.2231), (0.2239, 0.2494),
        (0.215, 0.2763), (0.205, 0.3038), (0.1983, 0.3294), (0.1948, 0.3531),
        (0.1947, 0.375), (0.1978, 0.395), (0.2042, 0.4131), (0.2139, 0.4294),
        (0.2269, 0.4437), (0.2431, 0.4562), (0.2605, 0.467), (0.2789, 0.4761),
        (0.2984, 0.4834), (0.3191, 0.4891), (0.3408, 0.493), (0.3636, 0.4952),
        (0.3875, 0.4956), (0.4125, 0.4944), (0.4355, 0.495), (0.4564, 0.4975),
        (0.4753, 0.5019), (0.4922, 0.5081), (0.507, 0.5162), (0.5198, 0.5262),
        (0.5306, 0.5381), (0.5394, 0.5519), (0.5458, 0.5656), (0.5498, 0.5794),
        (0.5516, 0.5931), (0.5509, 0.6069), (0.548, 0.6206), (0.5427, 0.6344),
        (0.535, 0.6481), (0.525, 0.6619), (0.5134, 0.6762), (0.5003, 0.6912),
        (0.4856, 0.7069), (0.4694, 0.7231), (0.4516, 0.74), (0.4322, 0.7575),
        (0.4113, 0.7756), (0.3888, 0.7944), (0.3675, 0.8125), (0.3475, 0.83),
        (0.3287, 0.8469), (0.3112, 0.8631), (0.295, 0.8787), (0.28, 0.8937),
        (0.2662, 0.9081), (0.2537, 0.9219), (0.2423, 0.9367), (0.232, 0.9527),
        (0.2228, 0.9697), (0.2147, 0.9878), (0.2077, 1.007), (0.2017, 1.0273),
        (0.1969, 1.0488), (0.1931, 1.0713), (0.1884, 1.0888), (0.1828, 1.1012),
        (0.1763, 1.1087), (0.1688, 1.1112), (0.1603, 1.1087), (0.1509, 1.1012),
        (0.1406, 1.0887), (0.1294, 1.0713), (0.1178, 1.0578), (0.1059, 1.0484),
        (0.0938, 1.0431), (0.0812, 1.0419), (0.0684, 1.0447), (0.0553, 1.0516),
        (0.0419, 1.0625), (0.0281, 1.0775), (0.0142, 1.0881), (0.0002, 1.0944),
        (-0.0141, 1.0962), (-0.0284, 1.0937), (-0.043, 1.0869), (-0.0577, 1.0756),
        (-0.0725, 1.06), (-0.0875, 1.04), (-0.1023, 1.0183), (-0.117, 0.9948),
        (-0.1316, 0.9697), (-0.1459, 0.9428), (-0.1602, 0.9142), (-0.1742, 0.8839),
        (-0.1881, 0.8519), (-0.2019, 0.8181), (-0.2152, 0.7833), (-0.228, 0.7473),
        (-0.2403, 0.7103), (-0.2522, 0.6722), (-0.2636, 0.633), (-0.2745, 0.5927),
        (-0.285, 0.5512), (-0.295, 0.5087), (-0.303, 0.4659), (-0.3089, 0.4228),
        (-0.3128, 0.3794), (-0.3147, 0.3356), (-0.3145, 0.2916), (-0.3123, 0.2472),
        (-0.3081, 0.2025), (-0.3019, 0.1575), (-0.288, 0.1181), (-0.2664, 0.0844),
        (-0.2372, 0.0563), (-0.2003, 0.0338), (-0.1558, 0.0169), (-0.1036, 0.0056)
    ]

    private static func knightHead(_ mat: SCNMaterial, white: Bool) -> SCNNode {
        let s: CGFloat = 0.72
        let p = UIBezierPath()
        for (i, pt) in knightHeadPts.enumerated() {
            let q = CGPoint(x: pt.0 * s, y: 0.34 + pt.1 * s)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.close()
        p.flatness = 0.05
        let shape = SCNShape(path: p, extrusionDepth: 0.30)
        shape.chamferRadius = 0.04
        shape.materials = [mat]
        let node = SCNNode(geometry: shape)
        let bb = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation(0, 0, (bb.min.z + bb.max.z) / 2)

        let holder = SCNNode()
        holder.addChildNode(node)
        let eyeMat = white ? bodyMaterial(white: false) : gold
        let ex = Float(0.33 * s)
        let ey = Float(0.34 + 0.68 * s)
        for z in [Float(-0.15), Float(0.15)] {
            holder.addChildNode(ball(0.032, ex, ey, z, eyeMat))
        }
        return holder
    }

    private static func build(_ code: Int8) -> SCNNode {
        let type = abs(Int(code))
        let white = code > 0
        let mat = bodyMaterial(white: white)
        let root = SCNNode()

        switch type {
        case 1:
            root.addChildNode(lathe(pawnProfile, mat))
            root.addChildNode(ring(0.214, 0.011, 0.505))
        case 2:
            root.addChildNode(lathe(knightProfile, mat))
            let head = knightHead(mat, white: white)
            head.eulerAngles.y = white ? Float.pi / 2 : -Float.pi / 2
            root.addChildNode(head)
            root.addChildNode(ring(0.192, 0.011, 0.32))
        case 3:
            root.addChildNode(lathe(bishopProfile, mat))
            root.addChildNode(ring(0.215, 0.011, 0.625))
            root.addChildNode(ring(0.128, 0.009, 0.69))
            root.addChildNode(ball(0.04, 0, 1.335, 0, gold))
        case 4:
            root.addChildNode(lathe(rookProfile, mat))
            root.addChildNode(ring(0.29, 0.012, 0.677))
            for k in 0..<8 {
                let a = Float(k) * Float.pi / 4
                let b = SCNBox(width: 0.06, height: 0.09, length: 0.10, chamferRadius: 0.008)
                b.materials = [mat]
                let bn = SCNNode(geometry: b)
                bn.position = SCNVector3(0.2675 * cos(a), 1.045, 0.2675 * sin(a))
                bn.eulerAngles.y = -a
                root.addChildNode(bn)
            }
        case 5:
            root.addChildNode(lathe(queenProfile, mat))
            root.addChildNode(ring(0.225, 0.012, 0.73))
            root.addChildNode(ring(0.292, 0.011, 1.19))
            root.addChildNode(ball(0.06, 0, 1.225, 0, gold))
            for k in 0..<9 {
                let a = Float(k) * 2 * Float.pi / 9
                let c = SCNCone(topRadius: 0, bottomRadius: 0.034, height: 0.16)
                c.materials = [mat]
                let cn = SCNNode(geometry: c)
                cn.position = SCNVector3(0.27 * cos(a), 1.29, 0.27 * sin(a))
                root.addChildNode(cn)
                root.addChildNode(ball(0.026, 0.27 * cos(a), 1.38, 0.27 * sin(a), gold))
            }
        default:
            root.addChildNode(lathe(kingProfile, mat))
            root.addChildNode(ring(0.235, 0.012, 0.775))
            root.addChildNode(ring(0.27, 0.011, 1.205))
            root.addChildNode(ball(0.055, 0, 1.235, 0, gold))
            let v = SCNBox(width: 0.075, height: 0.26, length: 0.075, chamferRadius: 0.015)
            v.materials = [gold]
            let vn = SCNNode(geometry: v)
            vn.position = SCNVector3(0, 1.40, 0)
            root.addChildNode(vn)
            let h = SCNBox(width: 0.21, height: 0.06, length: 0.075, chamferRadius: 0.015)
            h.materials = [gold]
            let hn = SCNNode(geometry: h)
            hn.position = SCNVector3(0, 1.46, 0)
            root.addChildNode(hn)
        }
        root.addChildNode(ring(0.362, 0.013, 0.068))
        return root.flattenedClone()
    }
}

final class BoardController {
    let root = SCNNode()
    private let squaresNode = SCNNode()
    private let piecesNode = SCNNode()
    private let labelsNode = SCNNode()
    private let fxNode = SCNNode()
    private let colliderNode = SCNNode()
    private var overlays: [SCNNode] = []
    private var overlayMats: [SCNMaterial] = []
    private var pieceNodes: [Int: SCNNode] = [:]
    private var labelContainers: [SCNNode] = []
    private var liftedSquare: Int? = nil
    private var animationToken = 0
    private var physicsActive = false
    private let restY: Float = 0.075

    private let dragLock = NSLock()
    private var draggedNode: SCNNode? = nil
    private var dragTargetLocal = SCNVector3Zero

    init() {
        root.addChildNode(squaresNode)
        root.addChildNode(piecesNode)
        root.addChildNode(labelsNode)
        root.addChildNode(fxNode)
        root.addChildNode(colliderNode)
        buildSquares()
        buildFrame()
        buildLabels()
    }

    func pos(_ s: Int) -> SCNVector3 {
        return SCNVector3(Float(s & 7) - 3.5, restY, 3.5 - Float(s >> 3))
    }

    static func squareIndex(from node: SCNNode) -> Int? {
        var cur: SCNNode? = node
        while let n = cur {
            if let name = n.name, name.hasPrefix("pc_") || name.hasPrefix("sq_") {
                return Int(name.dropFirst(3))
            }
            cur = n.parent
        }
        return nil
    }

    private func applyMap(_ prop: SCNMaterialProperty, _ image: UIImage?, _ transform: SCNMatrix4) {
        guard let img = image else { return }
        prop.contents = img
        prop.wrapS = .repeat
        prop.wrapT = .repeat
        prop.contentsTransform = transform
    }

    private func buildSquares() {
        let fresnelShader = "#pragma body\nfloat3 n = normalize(_surface.normal);\nfloat3 v = normalize(_surface.view);\nfloat fres = pow(1.0 - saturate(abs(dot(n, v))), 4.4);\n_output.color.rgb += float3(0.45, 0.65, 1.0) * fres * 0.07;\n"
        for s in 0..<64 {
            let c = s & 7
            let r = s >> 3
            let dark = (r + c) % 2 == 0
            let box = SCNBox(width: 1.0, height: 0.15, length: 1.0, chamferRadius: 0.012)
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            let ox = Float((s * 53) % 16) / 16.0
            let oy = Float((s * 29 + 7) % 16) / 16.0
            let tf = SCNMatrix4Mult(SCNMatrix4MakeScale(0.5, 0.5, 1), SCNMatrix4MakeTranslation(ox, oy, 0))
            if dark {
                if TextureCache.wood != nil {
                    applyMap(mat.diffuse, TextureCache.wood, tf)
                    applyMap(mat.normal, TextureCache.woodNormal, tf)
                    applyMap(mat.roughness, TextureCache.woodRough, tf)
                } else {
                    mat.diffuse.contents = UIColor(red: 0.35, green: 0.20, blue: 0.10, alpha: 1)
                    mat.roughness.contents = 0.40
                }
                mat.clearCoat.contents = 0.58
                mat.clearCoatRoughness.contents = 0.10
            } else {
                if TextureCache.marble != nil {
                    applyMap(mat.diffuse, TextureCache.marble, tf)
                    applyMap(mat.normal, TextureCache.marbleNormal, tf)
                    applyMap(mat.roughness, TextureCache.marbleRough, tf)
                } else {
                    mat.diffuse.contents = UIColor(red: 0.88, green: 0.85, blue: 0.78, alpha: 1)
                    mat.roughness.contents = 0.22
                }
                mat.clearCoat.contents = 0.94
                mat.clearCoatRoughness.contents = 0.035
            }
            mat.metalness.contents = 0.0
            mat.shaderModifiers = [SCNShaderModifierEntryPoint.fragment: fresnelShader]
            box.materials = [mat]
            let node = SCNNode(geometry: box)
            node.name = "sq_\(s)"
            node.position = SCNVector3(Float(c) - 3.5, 0, 3.5 - Float(r))
            squaresNode.addChildNode(node)

            let plane = SCNPlane(width: 0.96, height: 0.96)
            let om = SCNMaterial()
            om.lightingModel = .constant
            om.diffuse.contents = UIColor.green
            om.isDoubleSided = true
            om.writesToDepthBuffer = false
            plane.materials = [om]
            let on = SCNNode(geometry: plane)
            on.name = "sq_\(s)"
            on.eulerAngles.x = -Float.pi / 2
            on.position = SCNVector3(Float(c) - 3.5, 0.083, 3.5 - Float(r))
            on.renderingOrder = 10
            on.castsShadow = false
            on.isHidden = true
            squaresNode.addChildNode(on)
            overlays.append(on)
            overlayMats.append(om)
        }
    }

    private func buildFrame() {
        let fm = SCNMaterial()
        fm.lightingModel = .physicallyBased
        let tf = SCNMatrix4MakeScale(2.5, 0.5, 1)
        if TextureCache.wood != nil {
            applyMap(fm.diffuse, TextureCache.wood, tf)
            applyMap(fm.normal, TextureCache.woodNormal, tf)
            applyMap(fm.roughness, TextureCache.woodRough, tf)
            fm.multiply.contents = UIColor(red: 0.62, green: 0.46, blue: 0.36, alpha: 1)
        } else {
            fm.diffuse.contents = UIColor(red: 0.22, green: 0.13, blue: 0.08, alpha: 1)
            fm.roughness.contents = 0.4
        }
        fm.metalness.contents = 0.0
        fm.clearCoat.contents = 0.62
        fm.clearCoatRoughness.contents = 0.09
        let strips: [(CGFloat, CGFloat, Float, Float)] = [
            (9.9, 0.95, 0, 4.475), (9.9, 0.95, 0, -4.475), (0.95, 8.0, 4.475, 0), (0.95, 8.0, -4.475, 0)
        ]
        for (w, l, x, z) in strips {
            let b = SCNBox(width: w, height: 0.3, length: l, chamferRadius: 0.04)
            b.materials = [fm]
            let n = SCNNode(geometry: b)
            n.position = SCNVector3(x, restY - 0.15, z)
            root.addChildNode(n)
        }
        let slab = SCNBox(width: 10.5, height: 0.25, length: 10.5, chamferRadius: 0.06)
        slab.materials = [fm]
        let sn = SCNNode(geometry: slab)
        sn.position = SCNVector3(0, -0.35, 0)
        root.addChildNode(sn)

        let inlay: [(CGFloat, CGFloat, Float, Float)] = [
            (8.14, 0.05, 0, 4.045), (8.14, 0.05, 0, -4.045), (0.05, 8.14, 4.045, 0), (0.05, 8.14, -4.045, 0),
            (9.78, 0.04, 0, 4.88), (9.78, 0.04, 0, -4.88), (0.04, 9.78, 4.88, 0), (0.04, 9.78, -4.88, 0)
        ]
        for (w, l, x, z) in inlay {
            let b = SCNBox(width: w, height: 0.03, length: l, chamferRadius: 0.008)
            b.materials = [PieceBuilder.gold]
            let n = SCNNode(geometry: b)
            n.position = SCNVector3(x, restY + 0.002, z)
            n.castsShadow = false
            root.addChildNode(n)
        }
    }

    private func buildLabels() {
        let files = ["A", "B", "C", "D", "E", "F", "G", "H"]
        for c in 0..<8 {
            addLabel(files[c], x: Float(c) - 3.5, z: 4.45)
            addLabel(files[c], x: Float(c) - 3.5, z: -4.45)
        }
        for r in 0..<8 {
            addLabel(String(r + 1), x: 4.45, z: 3.5 - Float(r))
            addLabel(String(r + 1), x: -4.45, z: 3.5 - Float(r))
        }
    }

    private func addLabel(_ text: String, x: Float, z: Float) {
        let container = SCNNode()
        container.position = SCNVector3(x, 0.092, z)
        let plane = SCNPlane(width: 0.5, height: 0.5)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = BoardController.labelImage(text)
        m.isDoubleSided = true
        plane.materials = [m]
        let pn = SCNNode(geometry: plane)
        pn.eulerAngles.x = -Float.pi / 2
        pn.castsShadow = false
        container.addChildNode(pn)
        labelsNode.addChildNode(container)
        labelContainers.append(container)
    }

    static func labelImage(_ text: String) -> UIImage {
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 88, weight: .bold),
                .foregroundColor: UIColor(red: 1.0, green: 0.86, blue: 0.52, alpha: 1.0),
                .paragraphStyle: style
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let h = str.size().height
            str.draw(in: CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h))
        }
    }

    func setPhysicsEnabled(_ enabled: Bool, board: ChessBoard) {
        physicsActive = enabled
        endDrag(releaseVelocity: SCNVector3Zero)
        if enabled {
            colliderNode.position = SCNVector3(0, -0.125, 0)
            let box = SCNBox(width: 10.3, height: 0.4, length: 10.3, chamferRadius: 0)
            let body = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: box, options: nil))
            body.friction = 0.72
            body.restitution = 0.2
            body.categoryBitMask = 1
            body.collisionBitMask = 2
            body.contactTestBitMask = 0
            colliderNode.physicsBody = body
        } else {
            colliderNode.physicsBody = nil
        }
        rebuild(from: board)
    }

    private func attachPhysics(to node: SCNNode, code: Int8) {
        let h = PieceBuilder.height(for: code)
        let cyl = SCNCylinder(radius: 0.33, height: CGFloat(h))
        let cylShape = SCNPhysicsShape(geometry: cyl, options: nil)
        let offset = SCNMatrix4MakeTranslation(0, h * 0.5, 0)
        let shape = SCNPhysicsShape(shapes: [cylShape], transforms: [NSValue(scnMatrix4: offset)])
        let body = SCNPhysicsBody(type: .dynamic, shape: shape)
        body.mass = 1.25
        body.centerOfMassOffset = SCNVector3(0, h * 0.28, 0)
        body.friction = 0.72
        body.rollingFriction = 0.22
        body.restitution = 0.22
        body.damping = 0.16
        body.angularDamping = 0.26
        body.categoryBitMask = 2
        body.collisionBitMask = 1 | 2
        body.contactTestBitMask = 2
        node.physicsBody = body
    }

    func beginDrag(square s: Int, atLocal: SCNVector3) -> Bool {
        guard physicsActive, let node = pieceNodes[s], let body = node.physicsBody else { return false }
        dragLock.lock()
        draggedNode = node
        dragTargetLocal = SCNVector3(atLocal.x, restY + 0.50, atLocal.z)
        dragLock.unlock()
        body.isAffectedByGravity = false
        body.angularVelocityFactor = SCNVector3(0.25, 0.25, 0.25)
        body.clearAllForces()
        return true
    }

    func updateDrag(toLocal: SCNVector3) {
        dragLock.lock()
        dragTargetLocal = SCNVector3(toLocal.x, restY + 0.50, toLocal.z)
        dragLock.unlock()
    }

    func endDrag(releaseVelocity: SCNVector3) {
        dragLock.lock()
        let node = draggedNode
        draggedNode = nil
        dragLock.unlock()
        guard let n = node, let body = n.physicsBody else { return }
        body.isAffectedByGravity = true
        body.angularVelocityFactor = SCNVector3(1, 1, 1)
        let vx = min(14, max(-14, releaseVelocity.x))
        let vy = min(6, max(-6, releaseVelocity.y))
        let vz = min(14, max(-14, releaseVelocity.z))
        body.velocity = SCNVector3(vx, vy, vz)
    }

    func updateDraggedPiecePhysics() {
        dragLock.lock()
        let node = draggedNode
        let targetLocal = dragTargetLocal
        dragLock.unlock()
        guard let n = node, let body = n.physicsBody else { return }
        let targetWorld = root.convertPosition(targetLocal, to: nil)
        let curWorld = n.presentation.worldPosition
        let dx = targetWorld.x - curWorld.x
        let dy = targetWorld.y - curWorld.y
        let dz = targetWorld.z - curWorld.z
        let vx = min(22, max(-22, dx * 18.0))
        let vy = min(22, max(-22, dy * 18.0))
        let vz = min(22, max(-22, dz * 18.0))
        body.velocity = SCNVector3(vx, vy, vz)
        let e = n.presentation.eulerAngles
        let len = (e.x * e.x + e.z * e.z).squareRoot()
        if len > 0.02 {
            body.angularVelocity = SCNVector4(-e.x / len, 0, -e.z / len, len * 8.0)
        } else {
            body.angularVelocity = SCNVector4(0, 1, 0, 0)
        }
    }

    func topplePiece(at square: Int, viewDir: SCNVector3) {
        guard physicsActive, let n = pieceNodes[square], let body = n.physicsBody else { return }
        let len = max(0.001, (viewDir.x * viewDir.x + viewDir.z * viewDir.z).squareRoot())
        let dx = viewDir.x / len
        let dz = viewDir.z / len
        body.applyForce(SCNVector3(dx * 7.5, 2.2, dz * 7.5), at: SCNVector3(0, 0.85, 0), asImpulse: true)
        body.applyTorque(SCNVector4(dz, 0.35, -dx, 3.2), asImpulse: true)
    }

    func setFlipped(_ flipped: Bool) {
        let a: Float = flipped ? Float.pi : 0
        for c in labelContainers { c.eulerAngles.y = a }
    }

    func reset(board: ChessBoard, flipped: Bool) {
        animationToken += 1
        endDrag(releaseVelocity: SCNVector3Zero)
        for child in fxNode.childNodes { child.removeFromParentNode() }
        setFlipped(flipped)
        rebuild(from: board)
    }

    private func rebuild(from board: ChessBoard) {
        endDrag(releaseVelocity: SCNVector3Zero)
        for n in piecesNode.childNodes where n.name != "fly" { n.removeFromParentNode() }
        pieceNodes.removeAll()
        liftedSquare = nil
        for s in 0..<64 {
            let code = board.sq[s]
            if code == 0 { continue }
            let n = PieceBuilder.node(for: code)
            n.name = "pc_\(s)"
            n.position = pos(s)
            if physicsActive { attachPhysics(to: n, code: code) }
            piecesNode.addChildNode(n)
            pieceNodes[s] = n
        }
    }

    func setHighlights(selected: Int?, targets: [Int: Bool], last: Move?, check: Int?) {
        for o in overlays { o.isHidden = true }
        func show(_ s: Int, _ img: UIImage?, _ fallback: UIColor) {
            if s < 0 || s >= 64 { return }
            overlays[s].isHidden = false
            if let i = img {
                overlayMats[s].diffuse.contents = i
                overlayMats[s].transparency = 1.0
            } else {
                overlayMats[s].diffuse.contents = fallback
                overlayMats[s].transparency = 0.5
            }
        }
        if let l = last {
            show(l.from, TextureCache.hlYellow, UIColor.yellow)
            show(l.to, TextureCache.hlYellow, UIColor.yellow)
        }
        if let s = selected { show(s, TextureCache.hlCyan, UIColor.cyan) }
        for (s, isCapture) in targets {
            if isCapture {
                show(s, TextureCache.hlRing, UIColor.systemRed)
            } else {
                show(s, TextureCache.hlDot, UIColor.systemGreen)
            }
        }
        if let c = check { show(c, TextureCache.hlRed, UIColor.red) }
    }

    func setLift(_ s: Int?) {
        if physicsActive { liftedSquare = nil; return }
        if let old = liftedSquare, old != s, let n = pieceNodes[old] {
            n.removeAllActions()
            n.runAction(SCNAction.move(to: pos(old), duration: 0.12))
        }
        if let s = s, liftedSquare != s, let n = pieceNodes[s] {
            n.removeAllActions()
            let p = pos(s)
            n.runAction(SCNAction.move(to: SCNVector3(p.x, restY + 0.3, p.z), duration: 0.12))
        }
        liftedSquare = s
    }

    func spawnBlackHole(at square: Int) {
        let p = pos(square)
        let bh = SCNNode()
        bh.position = SCNVector3(p.x, restY + 0.025, p.z)
        bh.scale = SCNVector3(0.01, 0.01, 0.01)
        fxNode.addChildNode(bh)

        let voidSphere = SCNSphere(radius: 0.44)
        voidSphere.segmentCount = 36
        let voidMat = SCNMaterial()
        voidMat.lightingModel = .constant
        voidMat.diffuse.contents = UIColor.black
        voidMat.writesToDepthBuffer = true
        voidMat.shaderModifiers = [
            SCNShaderModifierEntryPoint.fragment:
                "#pragma body\nfloat3 n = normalize(_surface.normal);\nfloat3 v = normalize(_surface.view);\nfloat ndv = saturate(abs(dot(n, v)));\nfloat pulse = 0.88 + 0.18 * sin(scn_frame.time * 9.0);\nfloat photon = pow(1.0 - ndv, 4.2) * pulse;\nfloat innerRim = smoothstep(0.16, 0.0, ndv);\n_output.color.rgb = float3(1.0, 0.72, 0.30) * photon * 2.8 + float3(0.85, 0.55, 1.0) * innerRim * 1.6;\n"
        ]
        voidSphere.materials = [voidMat]
        let voidNode = SCNNode(geometry: voidSphere)
        voidNode.scale = SCNVector3(1.0, 0.56, 1.0)
        voidNode.position = SCNVector3(0, -0.01, 0)
        voidNode.renderingOrder = 15
        voidNode.castsShadow = false
        bh.addChildNode(voidNode)

        let lensPlane = SCNPlane(width: 1.55, height: 1.55)
        let lensMat = SCNMaterial()
        lensMat.lightingModel = .constant
        lensMat.diffuse.contents = TextureCache.blackholeRing ?? UIColor(red: 1.0, green: 0.75, blue: 0.4, alpha: 1)
        lensMat.blendMode = .add
        lensMat.writesToDepthBuffer = false
        lensMat.isDoubleSided = true
        lensPlane.materials = [lensMat]
        let lensNode = SCNNode(geometry: lensPlane)
        let bb = SCNBillboardConstraint()
        bb.freeAxes = SCNBillboardAxis.Y
        lensNode.constraints = [bb]
        lensNode.position = SCNVector3(0, 0.06, 0)
        lensNode.renderingOrder = 19
        lensNode.castsShadow = false
        bh.addChildNode(lensNode)

        let funnel = SCNCone(topRadius: 0.56, bottomRadius: 0.02, height: 1.05)
        funnel.radialSegmentCount = 36
        let funnelMat = SCNMaterial()
        funnelMat.lightingModel = .constant
        funnelMat.diffuse.contents = UIColor(red: 0.42, green: 0.16, blue: 0.85, alpha: 0.90)
        funnelMat.blendMode = .add
        funnelMat.writesToDepthBuffer = false
        funnelMat.isDoubleSided = true
        funnel.materials = [funnelMat]
        let funnelNode = SCNNode(geometry: funnel)
        funnelNode.position = SCNVector3(0, -0.53, 0)
        funnelNode.renderingOrder = 14
        funnelNode.castsShadow = false
        funnelNode.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 9.0, z: 0, duration: 1.0)))
        bh.addChildNode(funnelNode)

        let diskPlane = SCNPlane(width: 2.05, height: 2.05)
        let diskMat = SCNMaterial()
        diskMat.lightingModel = .constant
        diskMat.diffuse.contents = TextureCache.blackholeDisk ?? UIColor.orange
        diskMat.blendMode = .add
        diskMat.writesToDepthBuffer = false
        diskMat.isDoubleSided = true
        diskMat.shaderModifiers = [
            SCNShaderModifierEntryPoint.fragment:
                "#pragma body\nfloat2 uv = _surface.diffuseTexcoord;\nfloat ripple = 0.88 + 0.22 * sin(length(uv - float2(0.5)) * 28.0 - scn_frame.time * 10.0);\n_output.color.rgb *= ripple;\n"
        ]
        diskPlane.materials = [diskMat]
        let diskNode = SCNNode(geometry: diskPlane)
        diskNode.eulerAngles.x = -Float.pi / 2
        diskNode.position = SCNVector3(0, 0.015, 0)
        diskNode.renderingOrder = 18
        diskNode.castsShadow = false
        diskNode.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0, z: 10.5, duration: 1.0)))
        bh.addChildNode(diskNode)

        let innerRing = SCNNode(geometry: lensPlane)
        innerRing.eulerAngles = SCNVector3(-Float.pi / 2 + 0.25, 0, 0)
        innerRing.scale = SCNVector3(0.95, 0.95, 0.95)
        innerRing.position = SCNVector3(0, 0.045, 0)
        innerRing.renderingOrder = 20
        innerRing.castsShadow = false
        innerRing.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0, z: -8.0, duration: 1.0)))
        bh.addChildNode(innerRing)

        let underDisk = SCNNode(geometry: diskPlane)
        underDisk.eulerAngles.x = -Float.pi / 2
        underDisk.position = SCNVector3(0, -0.62, 0)
        underDisk.scale = SCNVector3(0.75, 0.75, 0.75)
        underDisk.renderingOrder = 16
        underDisk.castsShadow = false
        underDisk.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0, z: -8.5, duration: 1.0)))
        bh.addChildNode(underDisk)

        if let jetImg = TextureCache.beam {
            let jetPlane = SCNPlane(width: 0.24, height: 1.8)
            let jm = SCNMaterial()
            jm.lightingModel = .constant
            jm.diffuse.contents = jetImg
            jm.blendMode = .add
            jm.writesToDepthBuffer = false
            jm.isDoubleSided = true
            jetPlane.materials = [jm]
            let jetUp = SCNNode(geometry: jetPlane)
            jetUp.position = SCNVector3(0, 0.95, 0)
            jetUp.opacity = 0.45
            jetUp.renderingOrder = 17
            jetUp.castsShadow = false
            bh.addChildNode(jetUp)
        }
        if let swImg = TextureCache.shockwave {
            let swPlane = SCNPlane(width: 1.2, height: 1.2)
            let swm = SCNMaterial()
            swm.lightingModel = .constant
            swm.diffuse.contents = swImg
            swm.blendMode = .add
            swm.writesToDepthBuffer = false
            swm.isDoubleSided = true
            swPlane.materials = [swm]
            let sw = SCNNode(geometry: swPlane)
            sw.eulerAngles.x = -Float.pi / 2
            sw.position = SCNVector3(0, 0.02, 0)
            sw.scale = SCNVector3(0.3, 0.3, 0.3)
            sw.renderingOrder = 17
            sw.castsShadow = false
            bh.addChildNode(sw)
            sw.runAction(SCNAction.group([SCNAction.scale(to: 1.9, duration: 0.45), SCNAction.fadeOut(duration: 0.45)]))
        }
        if let glowImg = TextureCache.glowWarm {
            let gPlane = SCNPlane(width: 2.1, height: 2.1)
            let gMat = SCNMaterial()
            gMat.lightingModel = .constant
            gMat.diffuse.contents = glowImg
            gMat.blendMode = .add
            gMat.writesToDepthBuffer = false
            gMat.isDoubleSided = true
            gPlane.materials = [gMat]
            let gNode = SCNNode(geometry: gPlane)
            gNode.eulerAngles.x = -Float.pi / 2
            gNode.position = SCNVector3(0, 0.008, 0)
            gNode.opacity = 0.85
            gNode.renderingOrder = 17
            gNode.castsShadow = false
            bh.addChildNode(gNode)
        }

        let ps = SCNParticleSystem()
        ps.loops = false
        ps.emissionDuration = 0.62
        ps.birthRate = 340
        ps.particleLifeSpan = 0.44
        ps.particleLifeSpanVariation = 0.14
        ps.emitterShape = SCNTorus(ringRadius: 0.82, pipeRadius: 0.10)
        ps.birthLocation = .surface
        ps.birthDirection = .surfaceNormal
        ps.particleVelocity = -1.95
        ps.particleVelocityVariation = 0.65
        ps.acceleration = SCNVector3(0, -2.2, 0)
        ps.particleSize = 0.055
        ps.particleSizeVariation = 0.03
        ps.particleColor = UIColor(red: 1.0, green: 0.72, blue: 0.32, alpha: 1)
        ps.particleColorVariation = SCNVector4(0.18, 0.25, 0.30, 0)
        ps.blendMode = .additive
        ps.isLightingEnabled = false
        if let img = TextureCache.spark { ps.particleImage = img }
        let psHolder = SCNNode()
        psHolder.position = SCNVector3(0, 0.20, 0)
        psHolder.addParticleSystem(ps)
        psHolder.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 12.0, z: 0, duration: 1.0)))
        bh.addChildNode(psHolder)

        let open = SCNAction.scale(to: 1.0, duration: 0.16)
        open.timingMode = .easeOut
        let hold = SCNAction.wait(duration: 0.56)
        let collapse = SCNAction.group([
            SCNAction.scale(to: 0.01, duration: 0.24),
            SCNAction.fadeOut(duration: 0.24)
        ])
        collapse.timingMode = .easeIn
        bh.runAction(SCNAction.sequence([open, hold, collapse, SCNAction.removeFromParentNode()]))
    }

    func burst(at square: Int, color: UIColor, intensity: CGFloat = 1.0, height: Float = 0.45) {
        let ps = SCNParticleSystem()
        ps.loops = false
        ps.emissionDuration = 0.06
        ps.birthRate = 4200 * intensity
        ps.particleLifeSpan = 0.9
        ps.particleLifeSpanVariation = 0.4
        ps.particleVelocity = 3.0
        ps.particleVelocityVariation = 1.8
        ps.birthLocation = .volume
        ps.birthDirection = .random
        ps.emitterShape = SCNSphere(radius: 0.12)
        ps.acceleration = SCNVector3(0, -4.5, 0)
        ps.particleSize = 0.06
        ps.particleSizeVariation = 0.03
        ps.particleColor = color
        ps.blendMode = .additive
        ps.isLightingEnabled = false
        if let img = TextureCache.spark { ps.particleImage = img }
        let n = SCNNode()
        let p = pos(square)
        n.position = SCNVector3(p.x, p.y + height, p.z)
        n.addParticleSystem(ps)
        fxNode.addChildNode(n)
        n.runAction(SCNAction.sequence([SCNAction.wait(duration: 2.2), SCNAction.removeFromParentNode()]))
    }

    func celebrate() {
        let colors: [UIColor] = [
            UIColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 1),
            UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1),
            UIColor(red: 1.0, green: 0.45, blue: 0.75, alpha: 1),
            UIColor(red: 0.5, green: 1.0, blue: 0.6, alpha: 1)
        ]
        for i in 0..<8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.32) { [weak self] in
                guard let self = self else { return }
                self.burst(at: Int.random(in: 0..<64), color: colors[i % colors.count], intensity: 1.4, height: 2.6)
            }
        }
    }

    func animate(move m: Move, before: ChessBoard, after: ChessBoard, completion: @escaping () -> Void) {
        liftedSquare = nil
        endDrag(releaseVelocity: SCNVector3Zero)
        let token = animationToken
        var finished = false
        let finish: () -> Void = { [weak self] in
            if finished { return }
            finished = true
            guard let self = self, self.animationToken == token else { return }
            self.rebuild(from: after)
            completion()
        }

        guard let mover = pieceNodes[m.from] else {
            finish()
            return
        }
        pieceNodes[m.from] = nil
        mover.physicsBody = nil
        mover.removeAllActions()

        var capSq = -1
        if before.sq[m.to] != 0 {
            capSq = m.to
        } else if abs(Int(before.sq[m.from])) == 1 && (m.from & 7) != (m.to & 7) {
            capSq = (m.from >> 3) * 8 + (m.to & 7)
        }
        let hasCapture = capSq >= 0 && pieceNodes[capSq] != nil
        if capSq >= 0, let cap = pieceNodes[capSq] {
            pieceNodes[capSq] = nil
            cap.name = "fly"
            cap.physicsBody = nil
            cap.removeAllActions()
            spawnBlackHole(at: capSq)

            let shroud = SCNNode(geometry: SCNSphere(radius: 0.35))
            let sm = SCNMaterial()
            sm.lightingModel = .constant
            sm.diffuse.contents = UIColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 0.55)
            sm.blendMode = .add
            sm.writesToDepthBuffer = false
            shroud.geometry?.materials = [sm]
            shroud.position = SCNVector3(0, 0.55, 0)
            shroud.opacity = 0
            shroud.castsShadow = false
            cap.addChildNode(shroud)
            shroud.runAction(SCNAction.sequence([SCNAction.wait(duration: 0.10), SCNAction.fadeOpacity(to: 0.85, duration: 0.25)]))

            let startPos = pos(capSq)
            let shockLift = SCNAction.move(to: SCNVector3(startPos.x, restY + 0.16, startPos.z), duration: 0.08)
            shockLift.timingMode = .easeOut
            let baseRestY = self.restY
            let spaghettify = SCNAction.customAction(duration: 0.52) { node, elapsed in
                let u = Float(elapsed / 0.52)
                let accel = u * u
                let spin = accel * 16.0
                let radius = 0.09 * (1.0 - u) * sin(u * Float.pi)
                let sx = max(0.02, 1.0 - 0.94 * pow(u, 1.15))
                let sy = 1.0 + 2.35 * sin(u * Float.pi * 0.78) - 1.15 * accel
                node.scale = SCNVector3(sx, max(0.03, sy), sx)
                node.eulerAngles = SCNVector3(0.32 * u, spin, 0.22 * u)
                node.position = SCNVector3(
                    startPos.x + radius * cos(spin),
                    baseRestY + 0.16 - 1.08 * accel,
                    startPos.z + radius * sin(spin)
                )
                node.opacity = CGFloat(max(0.0, 1.0 - pow(u, 2.2)))
            }
            cap.runAction(SCNAction.sequence([shockLift, spaghettify, SCNAction.removeFromParentNode()]))
        }

        let fromCol = m.from & 7
        let toCol = m.to & 7
        if abs(Int(before.sq[m.from])) == 6 && abs(toCol - fromCol) == 2 {
            let base = (m.from >> 3) * 8
            let rookFrom = base + (toCol == 6 ? 7 : 0)
            let rookTo = base + (toCol == 6 ? 5 : 3)
            if let rook = pieceNodes[rookFrom] {
                pieceNodes[rookFrom] = nil
                rook.physicsBody = nil
                rook.removeAllActions()
                let rp = pos(rookTo)
                let up = SCNAction.move(to: SCNVector3(rook.position.x, restY + 0.5, rook.position.z), duration: 0.12)
                let glide = SCNAction.move(to: SCNVector3(rp.x, restY + 0.5, rp.z), duration: 0.28)
                let down = SCNAction.move(to: rp, duration: 0.12)
                rook.runAction(SCNAction.sequence([up, glide, down]))
            }
        }

        let target = pos(m.to)
        let lift = SCNAction.move(to: SCNVector3(mover.position.x, restY + 0.72, mover.position.z), duration: 0.14)
        let glide = SCNAction.move(to: SCNVector3(target.x, restY + 0.72, target.z), duration: hasCapture ? 0.38 : 0.28)
        let drop = SCNAction.move(to: target, duration: 0.14)
        lift.timingMode = .easeOut
        glide.timingMode = .easeInEaseOut
        drop.timingMode = .easeIn
        let done = SCNAction.run { _ in
            DispatchQueue.main.async { finish() }
        }
        mover.runAction(SCNAction.sequence([lift, glide, drop, done]))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { finish() }
    } 
}
    final class SpaceScene {
    let scene = SCNScene() 
    let boardMount = SCNNode()
    let orbit = SCNNode()
    private let pitch = SCNNode()
    private let gyroNode = SCNNode()
    private let camNode = SCNNode()
    private let solarSystem = SCNNode()
    private let boardOrbitPivot = SCNNode()
    private let boardAnchor = SCNNode()
    private let beamsNode = SCNNode()
    private let dustNode = SCNNode()
    private let beltsNode = SCNNode()
    private let nebulaeNode = SCNNode()
    private let skySphereNode = SCNNode()
    private let eventsNode = SCNNode()
    private var backLight: SCNLight? = nil
    private var keyLight: SCNLight? = nil
    private let baseCam = SCNVector3(0, 10.2, 10.4)
    private var zoom: Float = 1.0

    private let motionMgr = CMMotionManager()
    private var gyroEnabled = false
    private var gyroRef: CMAttitude? = nil
    private var lastEventTime: TimeInterval = 0
    private var lastMeteorTime: TimeInterval = 0
    private var currentQuality: GraphicsQuality = .ultra

    init() {
        scene.rootNode.addChildNode(solarSystem)
        scene.physicsWorld.gravity = SCNVector3(0, -14.0, 0)
        solarSystem.addChildNode(eventsNode)
        buildBackground()
        buildNebulae()
        buildStars()
        buildSun()
        buildPlanets()
        buildAsteroidBelt()
        buildKuiperBelt()
        buildComet()
        buildBoardRig()
        buildBeams(from: SCNVector3(0, -8.4, -44))
        buildDust()
        buildCameraAndLights()
        applyQuality(.ultra)
        startBoardFloat()
        startMenuOrbit()
    }

    var cameraNode: SCNNode { camNode }

    private func markSolarBody(_ node: SCNNode) {
        node.categoryBitMask = 2
        for c in node.childNodes { markSolarBody(c) }
    }

    func setGyroEnabled(_ enabled: Bool) {
        gyroEnabled = enabled
        gyroRef = nil
        if enabled {
            if motionMgr.isDeviceMotionAvailable {
                motionMgr.deviceMotionUpdateInterval = 1.0 / 60.0
                motionMgr.startDeviceMotionUpdates()
            }
        } else {
            motionMgr.stopDeviceMotionUpdates()
        }
    }

    func recalibrateGyro() {
        gyroRef = motionMgr.deviceMotion?.attitude.copy() as? CMAttitude
    }

    func updateFrame(atTime time: TimeInterval) {
        if gyroEnabled, let att = motionMgr.deviceMotion?.attitude {
            if gyroRef == nil { gyroRef = att.copy() as? CMAttitude }
            if let ref = gyroRef, let rel = att.copy() as? CMAttitude {
                rel.multiply(byInverseOf: ref)
                let targetPitch = Float(max(-0.26, min(0.26, rel.pitch * 0.45)))
                let targetYaw = Float(max(-0.30, min(0.30, -rel.roll * 0.45)))
                let cur = gyroNode.eulerAngles
                gyroNode.eulerAngles = SCNVector3(
                    cur.x + (targetPitch - cur.x) * 0.12,
                    cur.y + (targetYaw - cur.y) * 0.12,
                    0
                )
            }
        } else {
            let cur = gyroNode.eulerAngles
            if abs(cur.x) > 0.001 || abs(cur.y) > 0.001 {
                gyroNode.eulerAngles = SCNVector3(cur.x * 0.88, cur.y * 0.88, 0)
            }
        }

        if lastEventTime == 0 {
            lastEventTime = time - 3.2
            lastMeteorTime = time - 1.5
        }
        if time - lastEventTime > 4.6 {
            lastEventTime = time
            DispatchQueue.main.async { [weak self] in self?.spawnMeteorCollision() }
        }
        if time - lastMeteorTime > 2.9 {
            lastMeteorTime = time
            DispatchQueue.main.async { [weak self] in self?.spawnShootingStar() }
        }
    }

    func setOrbitalMotionPaused(_ paused: Bool) {
        if paused {
            boardOrbitPivot.removeAction(forKey: "boardOrbit")
            boardMount.removeAction(forKey: "float")
            boardMount.runAction(SCNAction.group([
                SCNAction.move(to: SCNVector3Zero, duration: 0.2),
                SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.2)
            ]))
        } else {
            if boardOrbitPivot.action(forKey: "boardOrbit") == nil {
                boardOrbitPivot.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: CGFloat(2 * Float.pi), z: 0, duration: 180)), forKey: "boardOrbit")
            }
            if boardMount.action(forKey: "float") == nil {
                startBoardFloat()
            }
        }
    }

    private func spawnMeteorCollision() {
        let ang = Float.random(in: 0...(2 * Float.pi))
        let r = Float.random(in: 50...88)
        let y = Float.random(in: -4...9)
        let impact = SCNVector3(r * sin(ang), y, r * cos(ang))

        let d1 = SCNVector3(Float.random(in: -16...16), Float.random(in: -6...6), Float.random(in: -16...16))
        let d2 = SCNVector3(-d1.x * 0.92, -d1.y * 0.85, -d1.z * 0.92)

        let rockGeo = asteroidGeometry(seed: Int.random(in: 1...20))
        let m1 = SCNNode(geometry: rockGeo)
        let m2 = SCNNode(geometry: rockGeo)
        m1.scale = SCNVector3(0.55, 0.55, 0.55)
        m2.scale = SCNVector3(0.46, 0.46, 0.46)
        m1.position = SCNVector3(impact.x + d1.x, impact.y + d1.y, impact.z + d1.z)
        m2.position = SCNVector3(impact.x + d2.x, impact.y + d2.y, impact.z + d2.z)
        m1.castsShadow = false
        m2.castsShadow = false
        markSolarBody(m1)
        markSolarBody(m2)
        for m in [m1, m2] {
            if let g = TextureCache.glowWarm {
                let sp = sprite(g, 3.6, 3.6)
                sp.opacity = 0.85
                m.addChildNode(sp)
            }
            let trail = SCNParticleSystem()
            trail.loops = true
            trail.birthRate = 220
            trail.particleLifeSpan = 0.45
            trail.particleSize = 0.28
            trail.particleColor = UIColor(red: 1.0, green: 0.62, blue: 0.22, alpha: 0.95)
            trail.blendMode = .additive
            trail.isLightingEnabled = false
            if let sp = TextureCache.spark { trail.particleImage = sp }
            m.addParticleSystem(trail)
            eventsNode.addChildNode(m)
        }
        m1.runAction(SCNAction.sequence([SCNAction.move(to: impact, duration: 0.85), SCNAction.removeFromParentNode()]))
        m2.runAction(SCNAction.sequence([SCNAction.move(to: impact, duration: 0.85), SCNAction.removeFromParentNode()]))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
            guard let self = self else { return }
            let expNode = SCNNode()
            expNode.position = impact
            self.eventsNode.addChildNode(expNode)

            let flash = self.sprite(TextureCache.burst, 13.5, 13.5)
            flash.scale = SCNVector3(0.2, 0.2, 0.2)
            flash.runAction(SCNAction.sequence([
                SCNAction.group([SCNAction.scale(to: 1.65, duration: 0.12), SCNAction.fadeIn(duration: 0.04)]),
                SCNAction.group([SCNAction.scale(to: 0.2, duration: 0.55), SCNAction.fadeOut(duration: 0.55)])
            ]))
            expNode.addChildNode(flash)

            let glow = self.sprite(TextureCache.glowWarm, 18.0, 18.0)
            glow.runAction(SCNAction.sequence([
                SCNAction.scale(to: 1.5, duration: 0.16),
                SCNAction.fadeOut(duration: 0.85)
            ]))
            expNode.addChildNode(glow)

            let flare = self.sprite(TextureCache.flareRing, 14.0, 14.0)
            flare.scale = SCNVector3(0.2, 0.2, 0.2)
            flare.runAction(SCNAction.group([SCNAction.scale(to: 1.8, duration: 0.55), SCNAction.fadeOut(duration: 0.55)]))
            expNode.addChildNode(flare)

            if self.currentQuality != .standard {
                if let swImg = TextureCache.shockwave {
                    let swp = SCNPlane(width: 13.0, height: 13.0)
                    let swm = SCNMaterial()
                    swm.lightingModel = .constant
                    swm.diffuse.contents = swImg
                    swm.blendMode = .add
                    swm.writesToDepthBuffer = false
                    swm.isDoubleSided = true
                    swp.materials = [swm]
                    for k in 0..<2 {
                        let sw = SCNNode(geometry: swp)
                        sw.eulerAngles = SCNVector3(Float.random(in: -0.9...0.9) + Float(k) * Float.pi / 2, Float.random(in: 0...3), 0)
                        sw.scale = SCNVector3(0.08, 0.08, 0.08)
                        sw.castsShadow = false
                        sw.runAction(SCNAction.group([SCNAction.scale(to: 1.85, duration: 0.95), SCNAction.fadeOut(duration: 0.95)]))
                        expNode.addChildNode(sw)
                    }
                }

                let ps = SCNParticleSystem()
                ps.loops = false
                ps.emissionDuration = 0.09
                ps.birthRate = 3600
                ps.particleLifeSpan = 1.8
                ps.particleLifeSpanVariation = 0.7
                ps.particleVelocity = 7.8
                ps.particleVelocityVariation = 4.2
                ps.birthLocation = .volume
                ps.birthDirection = .random
                ps.emitterShape = SCNSphere(radius: 0.45)
                ps.particleSize = 0.28
                ps.particleSizeVariation = 0.16
                ps.particleColor = UIColor(red: 1.0, green: 0.74, blue: 0.26, alpha: 1)
                ps.particleColorVariation = SCNVector4(0.16, 0.24, 0.30, 0)
                ps.blendMode = .additive
                ps.isLightingEnabled = false
                if let spImg = TextureCache.spark { ps.particleImage = spImg }
                let psNode = SCNNode()
                psNode.addParticleSystem(ps)
                expNode.addChildNode(psNode)

                let shardGeo = self.asteroidGeometry(seed: 9)
                for _ in 0..<12 {
                    let sh = SCNNode(geometry: shardGeo)
                    let sc = Float.random(in: 0.15...0.36)
                    sh.scale = SCNVector3(sc, sc, sc)
                    sh.castsShadow = false
                    self.markSolarBody(sh)
                    if let gw = TextureCache.glowWarm {
                        let gsh = self.sprite(gw, 1.9, 1.9)
                        gsh.opacity = 0.75
                        sh.addChildNode(gsh)
                    }
                    let v = SCNVector3(Float.random(in: -9...9), Float.random(in: -6...6), Float.random(in: -9...9))
                    sh.runAction(SCNAction.group([
                        SCNAction.move(by: v, duration: 2.4),
                        SCNAction.rotateBy(x: 7, y: 9, z: 6, duration: 2.4),
                        SCNAction.fadeOut(duration: 2.4)
                    ]))
                    expNode.addChildNode(sh)
                }
            }

            expNode.runAction(SCNAction.sequence([SCNAction.wait(duration: 2.8), SCNAction.removeFromParentNode()]))
        }
    }

    private func spawnShootingStar() {
        let a = Float.random(in: 0...(2 * Float.pi))
        let r: Float = Float.random(in: 115...175)
        let y = Float.random(in: 5...55)
        let start = SCNVector3(r * sin(a), y, r * cos(a))
        let dir = SCNVector3(Float.random(in: -34...34), Float.random(in: -20 ... -6), Float.random(in: -34...34))
        let meteor = sprite(TextureCache.streak, 7.5, 1.0)
        meteor.position = start
        meteor.look(at: SCNVector3(start.x + dir.x, start.y + dir.y, start.z + dir.z))
        eventsNode.addChildNode(meteor)
        meteor.runAction(SCNAction.sequence([
            SCNAction.group([SCNAction.move(by: dir, duration: 1.05), SCNAction.fadeOut(duration: 1.05)]),
            SCNAction.removeFromParentNode()
        ]))
    }

    static func fallbackEnvironment() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let colors: [CGColor] = [
                UIColor(red: 0.55, green: 0.62, blue: 0.85, alpha: 1).cgColor,
                UIColor(red: 1.00, green: 0.95, blue: 0.85, alpha: 1).cgColor,
                UIColor(red: 0.22, green: 0.15, blue: 0.10, alpha: 1).cgColor
            ]
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.0, 0.5, 1.0]) {
                ctx.cgContext.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }

    private func buildBackground() {
        scene.background.contents = UIColor(red: 0.004, green: 0.006, blue: 0.02, alpha: 1)
        if let sky = TextureCache.sky {
            let sk = SCNSphere(radius: 290)
            sk.segmentCount = 48
            let sm = SCNMaterial()
            sm.lightingModel = .constant
            sm.diffuse.contents = sky
            sm.cullMode = .front
            sm.writesToDepthBuffer = false
            sk.materials = [sm]
            skySphereNode.geometry = sk
            skySphereNode.castsShadow = false
            skySphereNode.renderingOrder = -100
            skySphereNode.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.05, z: 0, duration: 30)))
            scene.rootNode.addChildNode(skySphereNode)
        }
        if let env = TextureCache.env {
            scene.lightingEnvironment.contents = env
        } else {
            scene.lightingEnvironment.contents = SpaceScene.fallbackEnvironment()
        }
        scene.lightingEnvironment.intensity = 1.25
    }

    private func buildNebulae() {
        let imgs = [
            TextureCache.nebulaCyan, TextureCache.nebulaPurple,
            TextureCache.nebulaGold, TextureCache.nebulaEmerald, TextureCache.nebulaCrimson
        ].compactMap { $0 }
        guard !imgs.isEmpty else { return }
        let nebShader = "#pragma body\nfloat pulse = 0.90 + 0.14 * sin(scn_frame.time * 0.65 + _surface.diffuseTexcoord.x * 6.28);\n_output.color.rgb *= pulse;\n"
        for i in 0..<36 {
            let az = Float(i) * (2 * Float.pi / 36.0) + Float.random(in: -0.18...0.18)
            let el = Float.random(in: -0.55...0.72)
            let dist = Float.random(in: 194...268)
            let size = CGFloat(Float.random(in: 82...172))
            let plane = SCNPlane(width: size, height: size)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = imgs[i % imgs.count]
            m.blendMode = .add
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            m.shaderModifiers = [SCNShaderModifierEntryPoint.fragment: nebShader]
            plane.materials = [m]
            let n = SCNNode(geometry: plane)
            n.position = SCNVector3(dist * cos(el) * sin(az), dist * sin(el), -dist * cos(el) * cos(az))
            n.look(at: SCNVector3Zero)
            n.eulerAngles.z = Float.random(in: 0...(2 * Float.pi))
            let baseOp = CGFloat(Float.random(in: 0.28...0.52))
            n.opacity = baseOp
            n.renderingOrder = -90
            n.castsShadow = false
            let rot = SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0, z: CGFloat(i % 2 == 0 ? 0.08 : -0.07), duration: 20))
            n.runAction(rot)
            nebulaeNode.addChildNode(n)
        }
        nebulaeNode.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.09, z: 0, duration: 30)))
        scene.rootNode.addChildNode(nebulaeNode)
    }

    private func buildStars() {
        var geos: [SCNGeometry] = []
        let tints: [UIColor] = [
            UIColor.white,
            UIColor(red: 0.72, green: 0.86, blue: 1.0, alpha: 1),
            UIColor(red: 1.0, green: 0.90, blue: 0.68, alpha: 1),
            UIColor(red: 1.0, green: 0.72, blue: 0.60, alpha: 1)
        ]
        for c in tints {
            let g = SCNSphere(radius: 0.14)
            g.segmentCount = 6
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = c
            g.materials = [m]
            geos.append(g)
        }
        let stars = SCNNode()
        for i in 0..<1500 {
            var x: Float = 0
            var y: Float = 0
            var z: Float = 0
            var len: Float = 0
            var tries = 0
            repeat {
                x = Float.random(in: -1...1)
                y = Float.random(in: -1...1)
                z = Float.random(in: -1...1)
                len = (x * x + y * y + z * z).squareRoot()
                tries += 1
            } while (len > 1 || len < 0.2) && tries < 20
            if len > 1 || len < 0.2 { continue }
            let d = Float.random(in: 195...265) / len
            let n = SCNNode(geometry: geos[i % geos.count])
            n.position = SCNVector3(x * d, y * d, z * d)
            let k = Float.random(in: 0.45...1.9)
            n.scale = SCNVector3(k, k, k)
            n.castsShadow = false
            stars.addChildNode(n)
        }
        for _ in 0..<36 {
            let a = Float.random(in: 0...(2 * Float.pi))
            let e = Float.random(in: -0.9...1.0)
            let d: Float = Float.random(in: 205...255)
            let g = sprite(TextureCache.burst, 5.8, 5.8)
            g.position = SCNVector3(d * cos(e) * sin(a), d * sin(e), -d * cos(e) * cos(a))
            g.opacity = CGFloat(Float.random(in: 0.45...0.95))
            stars.addChildNode(g)
        }
        stars.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.12, z: 0, duration: 30)))
        scene.rootNode.addChildNode(stars)
    }

    private func sprite(_ image: UIImage?, _ w: CGFloat, _ h: CGFloat) -> SCNNode {
        guard let img = image else { return SCNNode() }
        let plane = SCNPlane(width: w, height: h)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = img
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        let bb = SCNBillboardConstraint()
        bb.freeAxes = SCNBillboardAxis.all
        n.constraints = [bb]
        n.castsShadow = false
        return n
    }

    private func buildSun() {
        let sun = SCNSphere(radius: 4.0)
        sun.segmentCount = 64
        let sm = SCNMaterial()
        sm.lightingModel = .constant
        if let img = TextureCache.sun {
            sm.diffuse.contents = img
            sm.emission.contents = img
        } else {
            sm.diffuse.contents = UIColor(red: 1.0, green: 0.75, blue: 0.25, alpha: 1)
            sm.emission.contents = UIColor(red: 1.0, green: 0.65, blue: 0.15, alpha: 1)
        }
        sm.emission.intensity = 2.4
        sm.shaderModifiers = [
            SCNShaderModifierEntryPoint.fragment:
                "#pragma body\nfloat2 uv = _surface.diffuseTexcoord;\nfloat t = scn_frame.time * 0.45;\nfloat n1 = sin(uv.x * 28.0 + t * 2.2) * cos(uv.y * 20.0 - t * 1.7);\nfloat n2 = sin((uv.x + uv.y) * 46.0 - t * 3.1) * cos((uv.x - uv.y) * 38.0 + t * 2.5);\nfloat flare = saturate(0.5 + 0.30 * n1 + 0.22 * n2);\nfloat3 n = normalize(_surface.normal);\nfloat3 v = normalize(_surface.view);\nfloat rim = pow(1.0 - saturate(abs(dot(n, v))), 2.1);\n_output.color.rgb *= (0.86 + 0.42 * flare);\n_output.color.rgb += float3(1.0, 0.52, 0.14) * rim * 1.55;\n"
        ]
        sun.materials = [sm]
        let sunNode = SCNNode(geometry: sun)
        sunNode.position = SCNVector3Zero
        sunNode.castsShadow = false
        sunNode.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.35, z: 0, duration: 15)))
        solarSystem.addChildNode(sunNode)

        let corona = sprite(TextureCache.glowWarm, 42, 42)
        corona.opacity = 0.95
        corona.runAction(SCNAction.repeatForever(SCNAction.sequence([
            SCNAction.scale(to: 1.07, duration: 3.0),
            SCNAction.scale(to: 0.94, duration: 3.4)
        ])))
        let core = sprite(TextureCache.glow, 18, 18)
        let flare = sprite(TextureCache.streak, 82, 9.5)
        flare.opacity = 0.85
        let star = sprite(TextureCache.burst, 40, 40)
        star.opacity = 0.72
        let optRing = sprite(TextureCache.flareRing, 24, 24)
        optRing.opacity = 0.35
        for n in [corona, core, flare, star, optRing] { sunNode.addChildNode(n) }

        let solarLight = SCNLight()
        solarLight.type = .omni
        solarLight.intensity = 2400
        solarLight.color = UIColor(red: 1.0, green: 0.94, blue: 0.84, alpha: 1)
        solarLight.attenuationStartDistance = 260
        solarLight.attenuationEndDistance = 320
        solarLight.attenuationFalloffExponent = 0
        solarLight.categoryBitMask = 2
        let slNode = SCNNode()
        slNode.light = solarLight
        slNode.position = SCNVector3Zero
        solarSystem.addChildNode(slNode)
    }

    private func planetNode(radius: CGFloat, image: UIImage?, normal: UIImage?, fallback: UIColor, roughness: CGFloat = 0.85, limbTint: (Float, Float, Float)? = nil, animatedFlow: Bool = false) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        sphere.segmentCount = 48
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        if let img = image { m.diffuse.contents = img } else { m.diffuse.contents = fallback }
        if let nm = normal {
            m.normal.contents = nm
            m.normal.intensity = 1.0
        }
        m.roughness.contents = roughness
        m.metalness.contents = 0.0
        if let lt = limbTint {
            if animatedFlow {
                m.shaderModifiers = [
                    SCNShaderModifierEntryPoint.fragment:
                        "#pragma body\nfloat3 n = normalize(_surface.normal);\nfloat3 v = normalize(_surface.view);\nfloat rim = pow(1.0 - saturate(abs(dot(n, v))), 3.1);\nfloat band = 0.94 + 0.08 * sin(_surface.diffuseTexcoord.y * 40.0 + scn_frame.time * 0.8);\n_output.color.rgb = _output.color.rgb * band + float3(\(lt.0), \(lt.1), \(lt.2)) * rim * 0.45;\n"
                ]
            } else {
                m.shaderModifiers = [
                    SCNShaderModifierEntryPoint.fragment:
                        "#pragma body\nfloat3 n = normalize(_surface.normal);\nfloat3 v = normalize(_surface.view);\nfloat rim = pow(1.0 - saturate(abs(dot(n, v))), 3.2);\n_output.color.rgb += float3(\(lt.0), \(lt.1), \(lt.2)) * rim * 0.45;\n"
                ]
            }
        }
        sphere.materials = [m]
        let n = SCNNode(geometry: sphere)
        n.castsShadow = false
        markSolarBody(n)
        return n
    }

    @discardableResult
    private func addOrbitBody(
        distance: Float,
        orbitPeriod: TimeInterval,
        startAngleDeg: Float,
        inclinationDeg: Float = 0,
        axialTiltDeg: Float = 0,
        spinPeriod: TimeInterval,
        retrograde: Bool = false,
        bodyBuilder: (SCNNode) -> Void
    ) -> (holder: SCNNode, axial: SCNNode) {
        let plane = SCNNode()
        plane.eulerAngles.z = inclinationDeg * Float.pi / 180.0
        solarSystem.addChildNode(plane)

        let orbitPivot = SCNNode()
        orbitPivot.eulerAngles.y = startAngleDeg * Float.pi / 180.0
        orbitPivot.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: CGFloat(2 * Float.pi), z: 0, duration: orbitPeriod)))
        plane.addChildNode(orbitPivot)

        let holder = SCNNode()
        holder.position = SCNVector3(0, 0, distance)
        orbitPivot.addChildNode(holder)

        let axialHolder = SCNNode()
        axialHolder.eulerAngles.z = axialTiltDeg * Float.pi / 180.0
        holder.addChildNode(axialHolder)

        let spinNode = SCNNode()
        let dir: CGFloat = retrograde ? -1.0 : 1.0
        spinNode.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: dir * CGFloat(2 * Float.pi), z: 0, duration: spinPeriod)))
        axialHolder.addChildNode(spinNode)

        bodyBuilder(spinNode)
        return (holder, axialHolder)
    }

    private func addMoon(to parent: SCNNode, radius: CGFloat, distance: Float, orbitPeriod: TimeInterval, startAngleDeg: Float, inclinationDeg: Float = 0, retrograde: Bool = false, image: UIImage?, normal: UIImage?, fallback: UIColor) {
        let tilt = SCNNode()
        tilt.eulerAngles.z = inclinationDeg * Float.pi / 180.0
        parent.addChildNode(tilt)

        let piv = SCNNode()
        piv.eulerAngles.y = startAngleDeg * Float.pi / 180.0
        let dir: CGFloat = retrograde ? -1.0 : 1.0
        piv.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: dir * CGFloat(2 * Float.pi), z: 0, duration: orbitPeriod)))
        tilt.addChildNode(piv)

        let moon = planetNode(radius: radius, image: image, normal: normal, fallback: fallback, roughness: 0.9)
        moon.position = SCNVector3(distance, 0, 0)
        moon.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: dir * CGFloat(2 * Float.pi), z: 0, duration: orbitPeriod)))
        piv.addChildNode(moon)
    }

    private func buildPlanets() {
        addOrbitBody(distance: 10.5, orbitPeriod: 24, startAngleDeg: 148, inclinationDeg: 7.0, axialTiltDeg: 0.03, spinPeriod: 36) { spin in
            spin.addChildNode(planetNode(radius: 0.55, image: TextureCache.mercury, normal: TextureCache.mercuryNormal, fallback: .gray, roughness: 0.92))
        }

        let venus = addOrbitBody(distance: 16.5, orbitPeriod: 38, startAngleDeg: 212, inclinationDeg: 3.4, axialTiltDeg: 177.4, spinPeriod: 44, retrograde: true) { spin in
            spin.addChildNode(planetNode(radius: 0.95, image: TextureCache.venus, normal: nil, fallback: .systemYellow, roughness: 0.65, limbTint: (1.0, 0.85, 0.45)))
        }
        let vHalo = sprite(TextureCache.haloWarm, 2.5, 2.5)
        vHalo.opacity = 0.45
        venus.holder.addChildNode(vHalo)

        let earth = addOrbitBody(distance: 25.0, orbitPeriod: 60, startAngleDeg: 166, inclinationDeg: 0, axialTiltDeg: 23.4, spinPeriod: 22) { spin in
            spin.addChildNode(planetNode(radius: 1.85, image: TextureCache.earth, normal: nil, fallback: .systemBlue, roughness: 0.52, limbTint: (0.35, 0.65, 1.0)))
            if let clouds = TextureCache.earthClouds {
                let cs = SCNSphere(radius: 1.88)
                cs.segmentCount = 48
                let cm = SCNMaterial()
                cm.lightingModel = .lambert
                cm.diffuse.contents = clouds
                cm.writesToDepthBuffer = false
                cs.materials = [cm]
                let cn = SCNNode(geometry: cs)
                cn.castsShadow = false
                markSolarBody(cn)
                cn.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.3, z: 0, duration: 18)))
                spin.addChildNode(cn)
            }
        }
        let eHalo = sprite(TextureCache.halo, 5.1, 5.1)
        eHalo.opacity = 0.85
        earth.holder.addChildNode(eHalo)
        let atmoSphere = SCNSphere(radius: 1.98)
        atmoSphere.segmentCount = 40
        let atmoMat = SCNMaterial()
        atmoMat.lightingModel = .constant
        atmoMat.diffuse.contents = UIColor.black
        atmoMat.blendMode = .add
        atmoMat.writesToDepthBuffer = false
        atmoMat.shaderModifiers = [
            SCNShaderModifierEntryPoint.fragment:
                "#pragma body\nfloat3 n = normalize(_surface.normal);\nfloat3 v = normalize(_surface.view);\nfloat f = pow(1.0 - saturate(abs(dot(n, v))), 2.6);\n_output.color.rgb = float3(0.35, 0.62, 1.0) * f * 1.5;\n"
        ]
        atmoSphere.materials = [atmoMat]
        let atmoNode = SCNNode(geometry: atmoSphere)
        atmoNode.castsShadow = false
        earth.holder.addChildNode(atmoNode)
        addMoon(to: earth.holder, radius: 0.48, distance: 3.8, orbitPeriod: 11, startAngleDeg: 40, inclinationDeg: 5.1, image: TextureCache.moon, normal: TextureCache.moonNormal, fallback: .lightGray)

        let mars = addOrbitBody(distance: 34.0, orbitPeriod: 84, startAngleDeg: 204, inclinationDeg: 1.85, axialTiltDeg: 25.2, spinPeriod: 23) { spin in
            spin.addChildNode(planetNode(radius: 1.15, image: TextureCache.mars, normal: TextureCache.marsNormal, fallback: .systemRed, roughness: 0.88, limbTint: (1.0, 0.52, 0.28)))
        }
        let mHalo = sprite(TextureCache.haloWarm, 3.1, 3.1)
        mHalo.opacity = 0.55
        mars.holder.addChildNode(mHalo)
        addMoon(to: mars.axial, radius: 0.14, distance: 2.0, orbitPeriod: 4.2, startAngleDeg: 15, image: TextureCache.asteroid, normal: TextureCache.asteroidNormal, fallback: .brown)
        addMoon(to: mars.axial, radius: 0.10, distance: 2.8, orbitPeriod: 8.4, startAngleDeg: 185, image: TextureCache.asteroid, normal: TextureCache.asteroidNormal, fallback: .gray)

        let jupiter = addOrbitBody(distance: 82.0, orbitPeriod: 140, startAngleDeg: 167, inclinationDeg: 1.3, axialTiltDeg: 3.1, spinPeriod: 10) { spin in
            spin.addChildNode(planetNode(radius: 4.5, image: TextureCache.jupiter, normal: nil, fallback: UIColor(red: 0.85, green: 0.68, blue: 0.48, alpha: 1), roughness: 0.65, limbTint: (1.0, 0.78, 0.55), animatedFlow: true))
        }
        let jRing = SCNTorus(ringRadius: 6.2, pipeRadius: 0.08)
        jRing.ringSegmentCount = 64
        let jrm = SCNMaterial()
        jrm.lightingModel = .constant
        jrm.diffuse.contents = UIColor(red: 0.82, green: 0.72, blue: 0.58, alpha: 0.16)
        jrm.writesToDepthBuffer = false
        jRing.materials = [jrm]
        let jRingNode = SCNNode(geometry: jRing)
        jRingNode.scale = SCNVector3(1.0, 0.06, 1.0)
        jRingNode.castsShadow = false
        jupiter.axial.addChildNode(jRingNode)
        addMoon(to: jupiter.axial, radius: 0.36, distance: 6.8, orbitPeriod: 6.0, startAngleDeg: 20, image: nil, normal: TextureCache.moonNormal, fallback: UIColor(red: 0.95, green: 0.80, blue: 0.28, alpha: 1))
        addMoon(to: jupiter.axial, radius: 0.31, distance: 8.4, orbitPeriod: 9.5, startAngleDeg: 140, image: nil, normal: TextureCache.moonNormal, fallback: UIColor(red: 0.88, green: 0.86, blue: 0.78, alpha: 1))
        addMoon(to: jupiter.axial, radius: 0.48, distance: 10.4, orbitPeriod: 14.0, startAngleDeg: 250, image: TextureCache.moon, normal: TextureCache.moonNormal, fallback: UIColor(red: 0.64, green: 0.58, blue: 0.52, alpha: 1))
        addMoon(to: jupiter.axial, radius: 0.43, distance: 12.6, orbitPeriod: 20.0, startAngleDeg: 310, image: TextureCache.asteroid, normal: TextureCache.asteroidNormal, fallback: UIColor(red: 0.44, green: 0.40, blue: 0.38, alpha: 1))

        let saturn = addOrbitBody(distance: 106.0, orbitPeriod: 190, startAngleDeg: 194, inclinationDeg: 2.5, axialTiltDeg: 26.7, spinPeriod: 11) { spin in
            spin.addChildNode(planetNode(radius: 3.8, image: TextureCache.saturn, normal: nil, fallback: UIColor(red: 0.82, green: 0.68, blue: 0.5, alpha: 1), roughness: 0.72, limbTint: (1.0, 0.85, 0.60), animatedFlow: true))
        }
        let sRing = SCNPlane(width: 17.0, height: 17.0)
        let srm = SCNMaterial()
        srm.lightingModel = .constant
        srm.diffuse.contents = TextureCache.saturnRing ?? UIColor(red: 0.88, green: 0.78, blue: 0.60, alpha: 0.6)
        srm.isDoubleSided = true
        sRing.materials = [srm]
        let sRingNode = SCNNode(geometry: sRing)
        sRingNode.eulerAngles.x = -Float.pi / 2
        sRingNode.castsShadow = false
        sRingNode.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0, z: CGFloat(2 * Float.pi), duration: 48)))
        saturn.axial.addChildNode(sRingNode)
        addMoon(to: saturn.axial, radius: 0.16, distance: 9.2, orbitPeriod: 6.5, startAngleDeg: 45, image: TextureCache.moon, normal: TextureCache.moonNormal, fallback: .lightGray)
        addMoon(to: saturn.axial, radius: 0.20, distance: 10.6, orbitPeriod: 9.0, startAngleDeg: 175, image: nil, normal: TextureCache.moonNormal, fallback: UIColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 1))
        addMoon(to: saturn.axial, radius: 0.50, distance: 13.0, orbitPeriod: 15.0, startAngleDeg: 290, image: nil, normal: nil, fallback: UIColor(red: 0.90, green: 0.68, blue: 0.34, alpha: 1))

        let uranus = addOrbitBody(distance: 130.0, orbitPeriod: 240, startAngleDeg: 172, inclinationDeg: 0.8, axialTiltDeg: 97.8, spinPeriod: 15, retrograde: true) { spin in
            spin.addChildNode(planetNode(radius: 2.5, image: TextureCache.uranus, normal: nil, fallback: .cyan, roughness: 0.68, limbTint: (0.55, 0.95, 1.0)))
        }
        let uRing = SCNPlane(width: 10.5, height: 10.5)
        let urm = SCNMaterial()
        urm.lightingModel = .constant
        urm.diffuse.contents = TextureCache.uranusRing ?? UIColor(red: 0.65, green: 0.88, blue: 0.95, alpha: 0.4)
        urm.isDoubleSided = true
        uRing.materials = [urm]
        let uRingNode = SCNNode(geometry: uRing)
        uRingNode.eulerAngles.x = -Float.pi / 2
        uRingNode.castsShadow = false
        uranus.axial.addChildNode(uRingNode)
        addMoon(to: uranus.axial, radius: 0.24, distance: 6.2, orbitPeriod: 8.0, startAngleDeg: 60, image: TextureCache.moon, normal: TextureCache.moonNormal, fallback: .lightGray)
        addMoon(to: uranus.axial, radius: 0.22, distance: 7.6, orbitPeriod: 11.5, startAngleDeg: 210, image: TextureCache.moon, normal: TextureCache.moonNormal, fallback: .gray)

        let neptune = addOrbitBody(distance: 152.0, orbitPeriod: 300, startAngleDeg: 188, inclinationDeg: 1.8, axialTiltDeg: 28.3, spinPeriod: 14) { spin in
            spin.addChildNode(planetNode(radius: 2.4, image: TextureCache.neptune, normal: nil, fallback: .systemBlue, roughness: 0.65, limbTint: (0.35, 0.65, 1.0)))
        }
        let nHalo = sprite(TextureCache.halo, 6.2, 6.2)
        nHalo.opacity = 0.55
        neptune.holder.addChildNode(nHalo)
        addMoon(to: neptune.axial, radius: 0.34, distance: 5.4, orbitPeriod: 9.0, startAngleDeg: 120, inclinationDeg: 23.0, retrograde: true, image: TextureCache.moon, normal: TextureCache.moonNormal, fallback: UIColor(red: 0.85, green: 0.80, blue: 0.82, alpha: 1))

        let pluto = addOrbitBody(distance: 168.0, orbitPeriod: 360, startAngleDeg: 177, inclinationDeg: 9.0, axialTiltDeg: 122.5, spinPeriod: 28, retrograde: true) { spin in
            spin.addChildNode(planetNode(radius: 0.82, image: TextureCache.pluto, normal: nil, fallback: UIColor(red: 0.78, green: 0.65, blue: 0.55, alpha: 1), roughness: 0.90))
        }
        addMoon(to: pluto.holder, radius: 0.42, distance: 2.2, orbitPeriod: 8.0, startAngleDeg: 40, image: TextureCache.moon, normal: TextureCache.moonNormal, fallback: .gray)
    }

    private func asteroidGeometry(seed: Int, icy: Bool = false) -> SCNGeometry {
        let stacks = 7
        let slices = 10
        var verts: [SCNVector3] = []
        var norms: [SCNVector3] = []
        var uvs: [CGPoint] = []
        let f = Float(seed)
        for i in 0...stacks {
            let v = Float(i) / Float(stacks)
            let phi = (1.0 - v) * Float.pi
            for j in 0...slices {
                let u = Float(j) / Float(slices)
                let theta = u * 2.0 * Float.pi
                let nx = sin(phi) * cos(theta)
                let ny = cos(phi)
                let nz = sin(phi) * sin(theta)
                let disp = 1.0
                    + 0.24 * sin(nx * 3.1 + f * 1.7) * cos(nz * 2.7 + f)
                    + 0.14 * cos(ny * 4.3 + nx * 2.1 + f * 2.3)
                let r = max(0.55, disp)
                verts.append(SCNVector3(nx * r, ny * r * 0.82, nz * r))
                norms.append(SCNVector3(nx, ny, nz))
                uvs.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
            }
        }
        var idx: [Int32] = []
        let cols = slices + 1
        for i in 0..<stacks {
            for j in 0..<slices {
                let a = Int32(i * cols + j)
                let b = Int32((i + 1) * cols + j)
                let c = Int32(i * cols + j + 1)
                let d = Int32((i + 1) * cols + j + 1)
                idx.append(contentsOf: [a, b, c, c, b, d])
            }
        }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = TextureCache.asteroid ?? UIColor(white: 0.48, alpha: 1)
        if icy { m.multiply.contents = UIColor(red: 0.72, green: 0.86, blue: 1.0, alpha: 1) }
        if let nm = TextureCache.asteroidNormal { m.normal.contents = nm; m.normal.intensity = 1.2 }
        m.roughness.contents = icy ? 0.68 : 0.92
        m.metalness.contents = icy ? 0.05 : 0.12
        let geo = SCNGeometry(
            sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms), SCNGeometrySource(textureCoordinates: uvs)],
            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)]
        )
        geo.materials = [m]
        return geo
    }

    private func buildBeltRing(geos: [SCNGeometry], count: Int, heroCount: Int, rMin: Float, rMax: Float, ySpread: Float, sMin: Float, sMax: Float, orbitPeriod: TimeInterval) {
        let piv = SCNNode()
        piv.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: CGFloat(2 * Float.pi), z: 0, duration: orbitPeriod)))
        beltsNode.addChildNode(piv)

        let staticGroup = SCNNode()
        for i in 0..<count {
            let angle = Float.random(in: 0...(2 * Float.pi))
            let dist = Float.random(in: rMin...rMax)
            let y = Float.random(in: -ySpread...ySpread)
            let n = SCNNode(geometry: geos[i % geos.count])
            n.position = SCNVector3(dist * sin(angle), y, dist * cos(angle))
            n.eulerAngles = SCNVector3(Float.random(in: 0...6), Float.random(in: 0...6), Float.random(in: 0...6))
            let sx = Float.random(in: sMin...sMax)
            let sy = sx * Float.random(in: 0.72...1.25)
            let sz = sx * Float.random(in: 0.72...1.25)
            n.scale = SCNVector3(sx, sy, sz)
            n.castsShadow = false
            if i < heroCount {
                markSolarBody(n)
                let rx = CGFloat(Float.random(in: -3...3))
                let ry = CGFloat(Float.random(in: -3...3))
                let rz = CGFloat(Float.random(in: -3...3))
                n.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: rx, y: ry, z: rz, duration: Double.random(in: 6...14))))
                piv.addChildNode(n)
            } else {
                staticGroup.addChildNode(n)
            }
        }
        let batch = staticGroup.flattenedClone()
        batch.castsShadow = false
        markSolarBody(batch)
        piv.addChildNode(batch)
    }

    private func buildAsteroidBelt() {
        solarSystem.addChildNode(beltsNode)
        let geos = (0..<5).map { asteroidGeometry(seed: $0 + 1) }
        buildBeltRing(geos: geos, count: 80, heroCount: 16, rMin: 54, rMax: 58, ySpread: 2.2, sMin: 0.16, sMax: 0.45, orbitPeriod: 112)
        buildBeltRing(geos: geos, count: 85, heroCount: 16, rMin: 58, rMax: 63, ySpread: 2.8, sMin: 0.18, sMax: 0.56, orbitPeriod: 126)
        buildBeltRing(geos: geos, count: 70, heroCount: 13, rMin: 63, rMax: 68, ySpread: 3.2, sMin: 0.16, sMax: 0.48, orbitPeriod: 142)

        addOrbitBody(distance: 60.5, orbitPeriod: 118, startAngleDeg: 183, inclinationDeg: 6.5, axialTiltDeg: 4.0, spinPeriod: 16) { spin in
            spin.addChildNode(planetNode(radius: 0.54, image: TextureCache.moon, normal: TextureCache.moonNormal, fallback: .gray, roughness: 0.92))
        }
    }

    private func buildKuiperBelt() {
        let icyGeos = (0..<4).map { asteroidGeometry(seed: $0 + 21, icy: true) }
        buildBeltRing(geos: icyGeos, count: 85, heroCount: 14, rMin: 166, rMax: 176, ySpread: 5.0, sMin: 0.25, sMax: 0.72, orbitPeriod: 340)
        buildBeltRing(geos: icyGeos, count: 75, heroCount: 12, rMin: 176, rMax: 188, ySpread: 6.0, sMin: 0.28, sMax: 0.78, orbitPeriod: 390)
    }

    private func buildComet() {
        let plane = SCNNode()
        plane.eulerAngles = SCNVector3(0.18, 0, -0.22)
        solarSystem.addChildNode(plane)

        let piv = SCNNode()
        piv.eulerAngles.y = 198 * Float.pi / 180.0
        piv.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: CGFloat(2 * Float.pi), z: 0, duration: 52)))
        plane.addChildNode(piv)

        let comet = SCNNode()
        comet.position = SCNVector3(48.0, 0, 0)
        piv.addChildNode(comet)

        let core = planetNode(radius: 0.34, image: TextureCache.moon, normal: TextureCache.moonNormal, fallback: .cyan, roughness: 0.6)
        core.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0.5, y: 1.2, z: 0.3, duration: 4)))
        comet.addChildNode(core)

        let coma = sprite(TextureCache.glow, 3.6, 3.6)
        coma.opacity = 0.85
        comet.addChildNode(coma)

        if let tailImg = TextureCache.cometTail {
            let tm = SCNMaterial()
            tm.lightingModel = .constant
            tm.diffuse.contents = tailImg
            tm.blendMode = .add
            tm.writesToDepthBuffer = false
            tm.isDoubleSided = true
            let tp = SCNPlane(width: 12.0, height: 2.8)
            tp.materials = [tm]
            for k in 0..<2 {
                let tn = SCNNode(geometry: tp)
                tn.position = SCNVector3(5.4, 0, 0)
                tn.eulerAngles.x = Float(k) * Float.pi / 2
                tn.castsShadow = false
                comet.addChildNode(tn)
            }
        }
    }

    private func buildBoardRig() {
        boardOrbitPivot.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: CGFloat(2 * Float.pi), z: 0, duration: 180)), forKey: "boardOrbit")
        solarSystem.addChildNode(boardOrbitPivot)
        boardAnchor.position = SCNVector3(0, 8.4, 44.0)
        boardOrbitPivot.addChildNode(boardAnchor)
        boardAnchor.addChildNode(boardMount)
    }

    private func buildBeams(from sun: SCNVector3) {
        boardAnchor.addChildNode(beamsNode)
        guard let tex = TextureCache.beam else { return }
        let warmMat = SCNMaterial()
        warmMat.lightingModel = .constant
        warmMat.diffuse.contents = tex
        warmMat.blendMode = .add
        warmMat.writesToDepthBuffer = false
        warmMat.isDoubleSided = true

        let coolMat = SCNMaterial()
        coolMat.lightingModel = .constant
        coolMat.diffuse.contents = tex
        coolMat.multiply.contents = UIColor(red: 0.55, green: 0.80, blue: 1.0, alpha: 1)
        coolMat.blendMode = .add
        coolMat.writesToDepthBuffer = false
        coolMat.isDoubleSided = true

        for i in 0..<20 {
            let target = SCNVector3(Float.random(in: -7.5...7.5), Float.random(in: -0.5...4.5), Float.random(in: -5...4))
            let dx = target.x - sun.x
            let dy = target.y - sun.y
            let dz = target.z - sun.z
            let length = (dx * dx + dy * dy + dz * dz).squareRoot()
            let holder = SCNNode()
            holder.position = SCNVector3((sun.x + target.x) / 2, (sun.y + target.y) / 2, (sun.z + target.z) / 2)
            beamsNode.addChildNode(holder)
            holder.look(at: target)
            let width = CGFloat(Float.random(in: 1.2...3.8))
            let beamMat = (i < 14) ? warmMat : coolMat
            for k in 0..<2 {
                let spin = SCNNode()
                spin.eulerAngles.z = Float(k) * Float.pi / 2 + Float.random(in: 0...0.5)
                let plane = SCNPlane(width: width, height: CGFloat(length * 1.05))
                plane.materials = [beamMat]
                let pn = SCNNode(geometry: plane)
                pn.eulerAngles.x = Float.pi / 2
                pn.castsShadow = false
                spin.addChildNode(pn)
                holder.addChildNode(spin)
            }
            let base = CGFloat(Float.random(in: 0.08...0.22))
            holder.opacity = base
            let up = SCNAction.fadeOpacity(to: base * 1.5, duration: Double.random(in: 2.5...5.0))
            let down = SCNAction.fadeOpacity(to: base * 0.55, duration: Double.random(in: 2.5...5.0))
            up.timingMode = .easeInEaseOut
            down.timingMode = .easeInEaseOut
            holder.runAction(SCNAction.repeatForever(SCNAction.sequence([up, down])))
        }
    }

    private func buildDust() {
        let ps = SCNParticleSystem()
        ps.loops = true
        ps.birthRate = 18
        ps.warmupDuration = 10
        ps.particleLifeSpan = 14
        ps.particleLifeSpanVariation = 4
        ps.emitterShape = SCNBox(width: 15, height: 5, length: 15, chamferRadius: 0)
        ps.birthLocation = .volume
        ps.birthDirection = .random
        ps.particleVelocity = 0.12
        ps.particleVelocityVariation = 0.1
        ps.acceleration = SCNVector3(0.01, 0.015, 0)
        ps.particleSize = 0.07
        ps.particleSizeVariation = 0.05
        ps.particleColor = UIColor(red: 1.0, green: 0.9, blue: 0.75, alpha: 0.6)
        ps.blendMode = .additive
        ps.isLightingEnabled = false
        if let img = TextureCache.dust { ps.particleImage = img }
        dustNode.position = SCNVector3(0, 2.6, 0)
        dustNode.addParticleSystem(ps)
        boardAnchor.addChildNode(dustNode)
    }

    private func startBoardFloat() {
        boardMount.removeAction(forKey: "float")
        let period: TimeInterval = 120.0
        let w0 = Float(2.0 * Double.pi / period)
        let drift = SCNAction.customAction(duration: period) { node, elapsed in
            let t = Float(elapsed)
            let y = 0.16 * sin(14 * w0 * t) + 0.04 * sin(27 * w0 * t + 0.8)
            let x = 0.09 * sin(7 * w0 * t + 0.4)
            let z = 0.08 * cos(9 * w0 * t + 1.1)
            let rx = 0.018 * sin(11 * w0 * t + 0.3)
            let rz = 0.020 * cos(8 * w0 * t + 1.4)
            let ry = 0.014 * sin(5 * w0 * t + 0.7)
            node.position = SCNVector3(x, y, z)
            node.eulerAngles = SCNVector3(rx, ry, rz)
        }
        boardMount.runAction(SCNAction.repeatForever(drift), forKey: "float")
    }

    private func buildCameraAndLights() {
        let cam = SCNCamera()
        cam.zNear = 0.1
        cam.zFar = 600
        cam.fieldOfView = 64
        camNode.camera = cam
        camNode.position = baseCam
        camNode.look(at: SCNVector3(0, 1.35, -1.5))
        gyroNode.addChildNode(camNode)
        pitch.addChildNode(gyroNode)
        orbit.addChildNode(pitch)
        boardAnchor.addChildNode(orbit)

        let back = SCNLight()
        back.type = .directional
        back.intensity = 1220
        back.color = UIColor(red: 1.0, green: 0.85, blue: 0.66, alpha: 1)
        back.castsShadow = true
        back.shadowMode = .deferred
        back.shadowRadius = 2.8
        back.shadowBias = 0.90
        back.shadowColor = UIColor(white: 0, alpha: 0.56)
        back.automaticallyAdjustsShadowProjection = false
        back.orthographicScale = 9.5
        back.categoryBitMask = 1
        let bn = SCNNode()
        bn.light = back
        bn.position = SCNVector3(-4, 11, -18)
        boardAnchor.addChildNode(bn)
        bn.look(at: SCNVector3Zero)
        backLight = back

        let key = SCNLight()
        key.type = .spot
        key.intensity = 760
        key.color = UIColor(red: 1.0, green: 0.95, blue: 0.89, alpha: 1)
        key.spotInnerAngle = 26
        key.spotOuterAngle = 82
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 4.2
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowSampleCount = 8
        key.shadowColor = UIColor(white: 0, alpha: 0.24)
        key.zNear = 2.0
        key.zFar = 38.0
        key.categoryBitMask = 1
        let kn = SCNNode()
        kn.light = key
        kn.position = SCNVector3(7, 13, 11)
        boardAnchor.addChildNode(kn)
        kn.look(at: SCNVector3Zero)
        keyLight = key

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 280
        fill.color = UIColor(red: 0.55, green: 0.70, blue: 1.0, alpha: 1)
        fill.categoryBitMask = 1
        let fn = SCNNode()
        fn.light = fill
        fn.position = SCNVector3(-8, 4, 8)
        boardAnchor.addChildNode(fn)
        fn.look(at: SCNVector3Zero)

        let under = SCNLight()
        under.type = .directional
        under.intensity = 230
        under.color = UIColor(red: 0.42, green: 0.60, blue: 0.98, alpha: 1)
        under.categoryBitMask = 1
        let un = SCNNode()
        un.light = under
        un.position = SCNVector3(2, -10, 4)
        boardAnchor.addChildNode(un)
        un.look(at: SCNVector3Zero)

        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 105
        amb.color = UIColor(red: 0.72, green: 0.78, blue: 1.0, alpha: 1)
        let an = SCNNode()
        an.light = amb
        scene.rootNode.addChildNode(an)
    }

    func applyQuality(_ q: GraphicsQuality) {
        currentQuality = q
        guard let cam = camNode.camera else { return }
        switch q {
        case .standard:
            cam.wantsHDR = false
            cam.wantsExposureAdaptation = false
            cam.bloomIntensity = 0
            cam.saturation = 1.0
            cam.contrast = 0.0
            cam.screenSpaceAmbientOcclusionIntensity = 0
            cam.wantsDepthOfField = false
            cam.motionBlurIntensity = 0
            cam.vignettingIntensity = 0
            cam.grainIntensity = 0
            cam.colorFringeStrength = 0
            backLight?.shadowMapSize = CGSize(width: 1024, height: 1024)
            backLight?.shadowSampleCount = 4
            keyLight?.castsShadow = false
            beamsNode.isHidden = true
            dustNode.isHidden = true
        case .high:
            configureFilmLook(cam)
            cam.screenSpaceAmbientOcclusionIntensity = 0.35
            cam.screenSpaceAmbientOcclusionRadius = 0.45
            cam.wantsDepthOfField = false
            cam.motionBlurIntensity = 0
            cam.grainIntensity = 0
            cam.colorFringeStrength = 0
            backLight?.shadowMapSize = CGSize(width: 2048, height: 2048)
            backLight?.shadowSampleCount = 8
            keyLight?.castsShadow = false
            beamsNode.isHidden = false
            dustNode.isHidden = false
        case .ultra:
            configureFilmLook(cam)
            cam.screenSpaceAmbientOcclusionIntensity = 0.95
            cam.screenSpaceAmbientOcclusionRadius = 0.55
            cam.screenSpaceAmbientOcclusionBias = 0.025
            cam.screenSpaceAmbientOcclusionDepthThreshold = 0.18
            cam.screenSpaceAmbientOcclusionNormalThreshold = 0.25
            cam.wantsDepthOfField = true
            cam.focusDistance = 13.8 * CGFloat(zoom)
            cam.fStop = 7.6
            cam.apertureBladeCount = 7
            cam.motionBlurIntensity = 0.18
            cam.grainIntensity = 0.07
            cam.grainScale = 1.4
            cam.colorFringeStrength = 0.75
            backLight?.shadowMapSize = CGSize(width: 4096, height: 4096)
            backLight?.shadowSampleCount = 16
            keyLight?.castsShadow = true
            beamsNode.isHidden = false
            dustNode.isHidden = false
        }
    }

    private func configureFilmLook(_ cam: SCNCamera) {
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = true
        cam.exposureOffset = -0.22
        cam.minimumExposure = -1.2
        cam.maximumExposure = 1.4
        cam.bloomIntensity = 0.72
        cam.bloomThreshold = 1.35
        cam.bloomBlurRadius = 11
        cam.bloomIterationCount = 2
        cam.vignettingIntensity = 0.48
        cam.vignettingPower = 1.25
        cam.saturation = 1.08
        cam.contrast = 0.10
    }

    func startMenuOrbit() {
        orbit.removeAction(forKey: "focus")
        pitch.eulerAngles.x = 0
        orbit.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.25, z: 0, duration: 20)), forKey: "menuOrbit")
    }

    func focus(flipped: Bool) {
        orbit.removeAction(forKey: "menuOrbit")
        pitch.eulerAngles.x = 0
        zoom = 1.0
        camNode.position = baseCam
        camNode.camera?.focusDistance = 13.8
        let target: CGFloat = flipped ? CGFloat.pi : 0
        orbit.runAction(SCNAction.rotateTo(x: 0, y: target, z: 0, duration: 0.9, usesShortestUnitArc: true), forKey: "focus")
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        orbit.removeAction(forKey: "focus")
        orbit.eulerAngles.y -= Float(dx) * 0.006
        let nx = pitch.eulerAngles.x - Float(dy) * 0.004
        pitch.eulerAngles.x = max(-0.8, min(0.3, nx))
    }

    func pinch(scale: CGFloat) {
        if scale <= 0 { return }
        zoom = min(1.5, max(0.55, zoom / Float(scale)))
        camNode.position = SCNVector3(baseCam.x * zoom, baseCam.y * zoom, baseCam.z * zoom)
        camNode.camera?.focusDistance = 13.8 * CGFloat(zoom)
    }
}

struct Chess3DContainer: UIViewRepresentable {
    @ObservedObject var gm: GameManager

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = gm.space.scene
        view.pointOfView = gm.space.cameraNode
        view.antialiasingMode = .multisampling4X
        view.isTemporalAntialiasingEnabled = true
        view.rendersContinuously = true
        view.backgroundColor = UIColor.black
        view.delegate = context.coordinator
        gm.space.scene.physicsWorld.contactDelegate = context.coordinator
        gm.attachBoardToSpace()

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let dblTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        dblTap.numberOfTapsRequired = 2
        tap.require(toFail: dblTap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(dblTap)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(gm: gm) }

    final class Coordinator: NSObject, SCNSceneRendererDelegate, SCNPhysicsContactDelegate {
        let gm: GameManager
        private var isDraggingPiece = false
        private var lastDragLocal: SCNVector3? = nil
        private var lastDragTime: TimeInterval = 0
        private var dragVelocityLocal = SCNVector3Zero
        private var lastClackTime: TimeInterval = 0

        init(gm: GameManager) { self.gm = gm }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            gm.space.updateFrame(atTime: time)
            if gm.controlMode == .drag {
                gm.boardCtl.updateDraggedPiecePhysics()
            }
        }

        func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
            guard contact.collisionImpulse > 0.7 else { return }
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastClackTime < 0.08 { return }
            lastClackTime = now
            SoundEngine.shared.play("click", enabled: gm.sfxEnabled)
        }

        private func rayBoardPoint(_ view: SCNView, screenPoint: CGPoint, yPlane: Float) -> SCNVector3? {
            let p0 = view.unprojectPoint(SCNVector3(Float(screenPoint.x), Float(screenPoint.y), 0))
            let p1 = view.unprojectPoint(SCNVector3(Float(screenPoint.x), Float(screenPoint.y), 1))
            let o = gm.boardCtl.root.convertPosition(p0, from: nil)
            let f = gm.boardCtl.root.convertPosition(p1, from: nil)
            let dy = f.y - o.y
            guard abs(dy) > 0.001 else { return nil }
            let t = (yPlane - o.y) / dy
            guard t > 0 else { return nil }
            let lx = min(7.0, max(-7.0, o.x + (f.x - o.x) * t))
            let lz = min(7.0, max(-7.0, o.z + (f.z - o.z) * t))
            return SCNVector3(lx, yPlane, lz)
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? SCNView else { return }
            let p = g.location(in: view)
            let hits = view.hitTest(p, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
            for h in hits {
                if let s = BoardController.squareIndex(from: h.node) {
                    gm.tapSquare(s)
                    return
                }
            }
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard gm.controlMode == .drag, let view = g.view as? SCNView else { return }
            let p = g.location(in: view)
            let hits = view.hitTest(p, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
            for h in hits {
                if let s = BoardController.squareIndex(from: h.node) {
                    let camW = gm.space.cameraNode.presentation.worldPosition
                    let hitW = h.worldCoordinates
                    let dirLocal = gm.boardCtl.root.convertVector(SCNVector3(hitW.x - camW.x, 0, hitW.z - camW.z), from: nil)
                    gm.knockOverPiece(at: s, viewDir: dirLocal)
                    return
                }
            }
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view as? SCNView else { return }
            let p = g.location(in: view)
            switch g.state {
            case .began:
                isDraggingPiece = false
                lastDragLocal = nil
                dragVelocityLocal = SCNVector3Zero
                if gm.controlMode == .drag {
                    let hits = view.hitTest(p, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
                    for h in hits {
                        if let s = BoardController.squareIndex(from: h.node),
                           let pt = rayBoardPoint(view, screenPoint: p, yPlane: 0.58) {
                            if gm.beginPieceDrag(square: s, atLocal: pt) {
                                isDraggingPiece = true
                                lastDragLocal = pt
                                lastDragTime = Date().timeIntervalSinceReferenceDate
                                return
                            }
                        }
                    }
                }
                let t = g.translation(in: view)
                gm.space.pan(dx: t.x, dy: t.y)
                g.setTranslation(.zero, in: view)

            case .changed:
                if isDraggingPiece {
                    if let pt = rayBoardPoint(view, screenPoint: p, yPlane: 0.58) {
                        let now = Date().timeIntervalSinceReferenceDate
                        let dt = Float(max(0.008, now - lastDragTime))
                        if let prev = lastDragLocal {
                            dragVelocityLocal = SCNVector3((pt.x - prev.x) / dt, 0, (pt.z - prev.z) / dt)
                        }
                        lastDragLocal = pt
                        lastDragTime = now
                        gm.updatePieceDrag(toLocal: pt)
                    }
                } else {
                    let t = g.translation(in: view)
                    gm.space.pan(dx: t.x, dy: t.y)
                    g.setTranslation(.zero, in: view)
                }

            case .ended, .cancelled:
                if isDraggingPiece {
                    isDraggingPiece = false
                    let pt = rayBoardPoint(view, screenPoint: p, yPlane: 0.58) ?? lastDragLocal
                    let worldVel = gm.boardCtl.root.convertVector(dragVelocityLocal, to: nil)
                    gm.endPieceDrag(atLocal: pt, releaseVelocity: worldVel)
                }
            default:
                break
            }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            gm.space.pinch(scale: g.scale)
            g.scale = 1.0
        }
    }
}

struct ARChessContainer: UIViewRepresentable {
    @ObservedObject var gm: GameManager

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.autoenablesDefaultLighting = true
        v.automaticallyUpdatesLighting = true
        gm.arSceneView = v
        gm.arBoardAnchorNode = nil
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal]
        v.session.run(cfg)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    func makeCoordinator() -> Coordinator { Coordinator(gm: gm) }

    final class Coordinator: NSObject {
        let gm: GameManager
        init(gm: GameManager) { self.gm = gm }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? ARSCNView else { return }
            let p = g.location(in: view)
            if gm.arBoardAnchorNode == nil {
                guard let query = view.raycastQuery(from: p, allowing: .estimatedPlane, alignment: .horizontal),
                      let hit = view.session.raycast(query).first else {
                    gm.statusText = "Плоскость не найдена — поводи камерой по столу"
                    return
                }
                let anchor = SCNNode()
                anchor.simdTransform = hit.worldTransform
                anchor.scale = SCNVector3(0.04, 0.04, 0.04)
                view.scene.rootNode.addChildNode(anchor)
                gm.attachBoard(to: anchor)
                gm.arBoardAnchorNode = anchor
                gm.statusText = "Доска на столе!"
                return
            }
            let hits = view.hitTest(p, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
            for h in hits {
                if let s = BoardController.squareIndex(from: h.node) {
                    gm.tapSquare(s)
                    return
                }
            }
        }
    }
}

@main
struct VibeChessApp: App {
    var body: some Scene {
        WindowGroup {
            MainGameView()
        }
    }
}

struct GlassStyle: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(Color.black.opacity(0.55))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}

extension View {
    func glass(_ radius: CGFloat = 12) -> some View {
        modifier(GlassStyle(radius: radius))
    }
}

private func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
    return Font.system(size: size, weight: weight, design: .monospaced)
}

struct MainGameView: View {
    @StateObject private var gm = GameManager()
    @State private var showSaves = false
    @State private var showSettings = false
    @State private var showAIChat = false
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            sceneLayer
            uiLayer
        }
        .onReceive(timer) { _ in gm.onClockTick() }
        .sheet(isPresented: $showSaves) { SavesModalView(gm: gm) }
        .sheet(isPresented: $showAIChat) { AIChatModalView(gm: gm) }
        .sheet(isPresented: $showSettings) { SettingsModalView(gm: gm) }
    }

    @ViewBuilder private var sceneLayer: some View {
        if gm.isARMode {
            ARChessContainer(gm: gm).ignoresSafeArea()
        } else {
            Chess3DContainer(gm: gm).ignoresSafeArea()
        }
    }

    @ViewBuilder private var uiLayer: some View {
        if gm.inMenu {
            MainMenuOverlay(gm: gm, showSaves: $showSaves, showSettings: $showSettings, showAIChat: $showAIChat)
        } else {
            ZStack {
                GameHUDOverlay(gm: gm, showAIChat: $showAIChat)
                if gm.pendingPromotion != nil {
                    PromotionOverlay(gm: gm)
                }
                if gm.gameResult != nil {
                    GameOverOverlay(gm: gm)
                }
                if gm.isPaused {
                    PauseMenuOverlay(gm: gm, showSaves: $showSaves, showSettings: $showSettings)
                }
            }
        }
    }
}

struct MainMenuOverlay: View {
    @ObservedObject var gm: GameManager
    @Binding var showSaves: Bool
    @Binding var showSettings: Bool
    @Binding var showAIChat: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("VIBE CHESS 3D")
                    .font(mono(30, .black))
                    .foregroundColor(.cyan)
                    .shadow(color: .cyan, radius: 10)
                Text("шахматы среди планет")
                    .font(mono(12, .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.top, 60)
            Spacer()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    optionsCard
                    startButtons
                    footerRow
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .frame(maxHeight: 540)
        }
    }

    private func caption(_ t: String) -> some View {
        Text(t).font(mono(10)).foregroundColor(.white.opacity(0.6))
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            caption("РЕЖИМ:")
            Picker("", selection: $gm.mode) {
                ForEach(GameMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)

            if gm.mode == .vsBot {
                caption("СЛОЖНОСТЬ БОТА:")
                Picker("", selection: $gm.difficulty) {
                    ForEach(BotDifficulty.allCases) { d in Text(d.rawValue).tag(d) }
                }
                .pickerStyle(.segmented)

                caption("ТВОЯ СТОРОНА:")
                Picker("", selection: $gm.playerSide) {
                    Text("Белые").tag(Side.white)
                    Text("Чёрные").tag(Side.black)
                }
                .pickerStyle(.segmented)
            }

            caption("УПРАВЛЕНИЕ ФИГУРАМИ:")
            Picker("", selection: $gm.controlMode) {
                ForEach(ControlMode.allCases) { c in Text(c.rawValue).tag(c) }
            }
            .pickerStyle(.segmented)

            HStack {
                caption("КОНТРОЛЬ ВРЕМЕНИ:")
                Spacer()
                Picker("", selection: $gm.timeControl) {
                    ForEach(TimeControl.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.menu)
                .tint(.cyan)
            }

            Toggle(isOn: $gm.isARMode) {
                Label("AR-режим (на столе)", systemImage: "camera.viewfinder")
                    .font(mono(12))
                    .foregroundColor(.cyan)
            }
        }
        .padding(18)
        .glass(20)
    }

    private var startButtons: some View {
        VStack(spacing: 10) {
            Button(action: { gm.startNewGame() }) {
                Text("НАЧАТЬ ПАРТИЮ")
                    .font(mono(15))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.cyan)
                    .cornerRadius(14)
            }
            if gm.hasAutoSave {
                Button(action: { gm.continueGame() }) {
                    Text("ПРОДОЛЖИТЬ ПАРТИЮ")
                        .font(mono(13))
                        .foregroundColor(.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .glass(14)
                }
            }
        }
    }

    private var footerRow: some View {
        HStack {
            Button(action: { showSaves = true }) {
                Label("СЕЙВЫ", systemImage: "folder.fill").font(mono(11)).foregroundColor(.yellow)
            }
            Spacer()
            Button(action: { showSettings = true }) {
                Label("НАСТРОЙКИ", systemImage: "gearshape.fill").font(mono(11)).foregroundColor(.white)
            }
            Spacer()
            Button(action: { showAIChat = true }) {
                Label("ИИ ЧАТ", systemImage: "brain.head.profile").font(mono(11)).foregroundColor(.cyan)
            }
        }
        .padding(.horizontal, 6)
    }
}

struct GameHUDOverlay: View {
    @ObservedObject var gm: GameManager
    @Binding var showAIChat: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                Button(action: { gm.pauseGame() }) {
                    Image(systemName: "pause.fill")
                        .foregroundColor(.white)
                        .padding(10)
                        .glass(20)
                }
                Spacer()
                VStack(spacing: 6) {
                    if gm.isClockActive { clockView }
                    statusPill
                }
                Spacer()
                Button(action: { showAIChat = true }) {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(.cyan)
                        .padding(10)
                        .glass(20)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 50)

            if gm.isCheckNow && gm.gameResult == nil {
                Text("ШАХ!")
                    .font(mono(18, .black))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.85))
                    .cornerRadius(10)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: { gm.performUndo() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Откат (\(gm.undoCount))")
                    }
                    .font(mono(11))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .glass(10)
                    .opacity(gm.undoCount > 0 ? 1.0 : 0.4)
                }

                if !gm.isARMode {
                    Button(action: { gm.toggleControlMode() }) {
                        HStack(spacing: 4) {
                            Image(systemName: gm.controlMode == .drag ? "hand.raised.fill" : "hand.tap.fill")
                            Text(gm.controlMode == .drag ? "Физика" : "Тап")
                        }
                        .font(mono(11))
                        .foregroundColor(gm.controlMode == .drag ? .orange : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .glass(10)
                    }
                    if gm.controlMode == .drag {
                        Button(action: { gm.realignPhysicsPieces() }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(mono(12))
                                .foregroundColor(.green)
                                .padding(8)
                                .glass(10)
                        }
                    }
                }

                Spacer()
                Text(gm.lastMoveNotation)
                    .font(mono(12))
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .glass(10)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 28)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            if gm.isThinking || gm.isAdviceThinking {
                ProgressView().tint(.cyan)
            }
            Text(gm.statusText)
                .font(mono(11))
                .foregroundColor(.cyan)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glass(10)
    }

    private var clockView: some View {
        let wTurn = gm.turnIsWhite
        let wBg = wTurn ? Color.white.opacity(0.22) : Color.black.opacity(0.5)
        let bBg = wTurn ? Color.black.opacity(0.5) : Color.white.opacity(0.22)
        let wFg = wTurn ? Color.green : Color.white.opacity(0.6)
        let bFg = wTurn ? Color.white.opacity(0.6) : Color.green
        return HStack(spacing: 8) {
            Text("⚪️ \(formatSec(gm.whiteSeconds))")
                .font(mono(13)).foregroundColor(wFg)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(wBg).cornerRadius(8)
            Text("⚫️ \(formatSec(gm.blackSeconds))")
                .font(mono(13)).foregroundColor(bFg)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(bBg).cornerRadius(8)
        }
    }

    private func formatSec(_ s: Int) -> String {
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct PromotionOverlay: View {
    @ObservedObject var gm: GameManager

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("ПРЕВРАЩЕНИЕ ПЕШКИ")
                    .font(mono(14))
                    .foregroundColor(.white)
                HStack(spacing: 10) {
                    promoButton("♕", "Ферзь", 5)
                    promoButton("♖", "Ладья", 4)
                    promoButton("♗", "Слон", 3)
                    promoButton("♘", "Конь", 2)
                }
                Button("Отмена") { gm.cancelPromotion() }
                    .font(mono(12))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(22)
            .glass(22)
        }
    }

    private func promoButton(_ glyph: String, _ name: String, _ type: Int) -> some View {
        Button(action: { gm.choosePromotion(type) }) {
            VStack(spacing: 4) {
                Text(glyph).font(.system(size: 38))
                Text(name).font(mono(10))
            }
            .foregroundColor(.white)
            .frame(width: 66, height: 78)
            .background(Color.cyan.opacity(0.25))
            .cornerRadius(12)
        }
    }
}

struct GameOverOverlay: View {
    @ObservedObject var gm: GameManager
    @State private var hidden = false

    var body: some View {
        Group {
            if !hidden {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 14) {
                        Text("ПАРТИЯ ОКОНЧЕНА")
                            .font(mono(13))
                            .foregroundColor(.white.opacity(0.7))
                        Text(gm.gameResult?.title ?? "")
                            .font(mono(20, .black))
                            .foregroundColor(.cyan)
                            .multilineTextAlignment(.center)
                        Button(action: { gm.restartGame() }) {
                            Text("РЕВАНШ")
                                .font(mono(14))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.cyan)
                                .cornerRadius(12)
                        }
                        Button(action: { hidden = true }) {
                            Text("Осмотреть доску").font(mono(12)).foregroundColor(.white)
                        }
                        Button(action: { gm.exitToMenu() }) {
                            Text("В главное меню").font(mono(12)).foregroundColor(.red)
                        }
                    }
                    .padding(24)
                    .glass(22)
                    .padding(.horizontal, 30)
                }
            }
        }
    }
}

struct PauseMenuOverlay: View {
    @ObservedObject var gm: GameManager
    @Binding var showSaves: Bool
    @Binding var showSettings: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("ПАУЗА").font(mono(26, .black)).foregroundColor(.white)
                Button("Продолжить") { gm.resumeGame() }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                Button("Настройки") { showSettings = true }
                    .buttonStyle(.bordered)
                Button("Сохранить партию") { showSaves = true }
                    .buttonStyle(.bordered)
                Button("Новая партия") {
                    gm.isPaused = false
                    gm.restartGame()
                }
                .buttonStyle(.bordered)
                Button("Выход в главное меню") { gm.exitToMenu() }
                    .foregroundColor(.red)
            }
            .padding(26)
            .glass(20)
        }
    }
}

struct AIChatModalView: View {
    @ObservedObject var gm: GameManager
    @Environment(\.dismiss) var dismiss
    @State private var input = ""

    var body: some View {
        NavigationStack {
            VStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(gm.chat) { msg in
                                bubble(msg).id(msg.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: gm.chat.count) { _ in
                        if let last = gm.chat.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("🧠 Лучший ход?") { gm.sendUserMessage("Какой ход лучший?") }
                            .buttonStyle(.bordered)
                            .tint(.cyan)
                        Button("⚖️ Оцени позицию") { gm.sendUserMessage("Оцени шансы") }
                            .buttonStyle(.bordered)
                            .tint(.cyan)
                    }
                    .padding(.horizontal)
                }
                HStack {
                    TextField("Сообщение ИИ...", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send() }
                    Button(action: { send() }) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundColor(.cyan)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
                .padding(.top, 4)
            }
            .navigationTitle("AI Каспаров-9000")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    private func send() {
        gm.sendUserMessage(input)
        input = ""
    }

    @ViewBuilder private func bubble(_ msg: ChatMessage) -> some View {
        if msg.sender == "Ты" {
            HStack {
                Spacer()
                VStack(alignment: .trailing) {
                    Text(msg.sender).font(.caption2).foregroundColor(.gray)
                    Text(msg.text).padding(10).background(Color.cyan.opacity(0.3)).cornerRadius(12)
                }
            }
        } else {
            HStack {
                VStack(alignment: .leading) {
                    Text(msg.sender).font(.caption2).foregroundColor(.gray)
                    Text(msg.text).padding(10).background(Color.gray.opacity(0.2)).cornerRadius(12)
                }
                Spacer()
            }
        }
    }
}

struct SettingsModalView: View {
    @ObservedObject var gm: GameManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Звук и музыка")) {
                    Toggle("Звуковые эффекты", isOn: $gm.sfxEnabled)
                    Toggle("Фоновая музыка космоса", isOn: $gm.musicEnabled)
                    Toggle("Голос комментатора", isOn: $gm.voiceEnabled)
                }
                Section(header: Text("Управление и гироскоп")) {
                    Picker("Режим фигур", selection: $gm.controlMode) {
                        ForEach(ControlMode.allCases) { c in Text(c.rawValue).tag(c) }
                    }
                    .pickerStyle(.segmented)
                    Text("В режиме «Руками (Физика)» фигуры можно брать и переносить пальцем, сталкивать друг с другом и опрокидывать двойным нажатием.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Toggle("Камера по гироскопу", isOn: $gm.gyroEnabled)
                    if gm.gyroEnabled {
                        Button("Калибровать гироскоп") {
                            gm.space.recalibrateGyro()
                        }
                    }
                }
                Section(header: Text("Графика RTX 4K")) {
                    Picker("Качество", selection: $gm.graphicsQuality) {
                        ForEach(GraphicsQuality.allCases) { q in Text(q.rawValue).tag(q) }
                    }
                    .pickerStyle(.segmented)
                    Text("Ультра: 4K текстуры, Metal-шейдеры, лакировка ClearCoat, двойные тени, DoF боке, TAA, лучи света и взрывы метеоритов.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("Игра")) {
                    Toggle("Подсвечивать доступные ходы", isOn: $gm.showHints)
                    Picker("Сложность бота", selection: $gm.difficulty) {
                        ForEach(BotDifficulty.allCases) { d in Text(d.rawValue).tag(d) }
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

struct SavesModalView: View {
    @ObservedObject var gm: GameManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !gm.inMenu {
                    Section("Сохранить партию") {
                        ForEach(1...3, id: \.self) { num in
                            Button("Сохранить в слот #\(num)") {
                                gm.saveToSlot(slotId: "slot_\(num)", title: "Слот #\(num)")
                                dismiss()
                            }
                        }
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
                                    Text("\(slot.dateString) • Ход \(slot.board.fullmove)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Загрузить") {
                                    gm.loadFromSlot(slot)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    gm.deleteSlot(slot.id)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Слоты сохранений")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}
