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
