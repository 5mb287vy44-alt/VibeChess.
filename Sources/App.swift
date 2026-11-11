import SwiftUI
import SceneKit
import ARKit
import AVFoundation
import AudioToolbox
import UIKit

// ============================================================
// VIBE CHESS 3D  v3
//  - полные правила шахмат (шах, мат, пат, рокировка, взятие
//    на проходе, превращение, ничья)
//  - бот на alpha-beta поиске: ходит только легальными ходами
//  - доска с буквами A-H и цифрами 1-8
// ============================================================

// MARK: - Базовые типы

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

enum BotDifficulty: String, CaseIterable, Identifiable, Codable {
    case easy = "Новичок"
    case medium = "Тактик"
    case hard = "Гроссмейстер"
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

// MARK: - Шахматный движок
// Фигуры: 1 пешка, 2 конь, 3 слон, 4 ладья, 5 ферзь, 6 король.
// Белые положительные, чёрные отрицательные. Клетка = row * 8 + col,
// row 0 = первая горизонталь (белые), col 0 = вертикаль A.

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
    var castle: UInt8      // 1: белые O-O, 2: белые O-O-O, 4: чёрные O-O, 8: чёрные O-O-O
    var ep: Int            // клетка для взятия на проходе или -1
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
            // взятие на проходе
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

// MARK: - Запись ходов

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

// MARK: - ИИ (negamax + alpha-beta + поиск взятий)

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

    // Оценка с точки зрения белых (в сотых долях пешки)
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

// MARK: - Звук

final class SoundEngine: NSObject {
    static let shared = SoundEngine()
    private var players: [String: AVAudioPlayer] = [:]
    private var bgPlayer: AVAudioPlayer?
    private let speechSynth = AVSpeechSynthesizer()

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        for n in ["move", "capture", "select", "click", "check", "win"] { loadSound(n) }
        if let url = Bundle.main.url(forResource: "ambient", withExtension: "wav") {
            bgPlayer = try? AVAudioPlayer(contentsOf: url)
            bgPlayer?.numberOfLoops = -1
            bgPlayer?.volume = 0.3
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

// MARK: - Текстуры (генерируются при сборке, см. build.yml)

struct TextureCache {
    static let wood = loadTex("wood_texture")
    static let marble = loadTex("marble_texture")
    static let earth = loadTex("earth_texture")
    static let mars = loadTex("mars_texture")
    static let saturn = loadTex("saturn_texture")
    static let sun = loadTex("sun_texture")
    static let moon = loadTex("moon_texture")

    private static func loadTex(_ name: String) -> UIImage? {
        if let path = Bundle.main.path(forResource: name, ofType: "png") { return UIImage(contentsOfFile: path) }
        return UIImage(named: name)
    }
}

// MARK: - Модели интерфейса

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

// MARK: - GameManager

final class GameManager: ObservableObject {
    // Интерфейс
    @Published var inMenu = true
    @Published var isPaused = false
    @Published var statusText = "Выбери режим и начни партию"
    @Published var lastMoveNotation = "Начало партии"
    @Published var isARMode = false
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

    // Настройки (сохраняются)
    @Published var playerSide: Side = .white { didSet { saveSettings() } }
    @Published var mode: GameMode = .vsBot { didSet { saveSettings() } }
    @Published var difficulty: BotDifficulty = .hard { didSet { saveSettings() } }
    @Published var timeControl: TimeControl = .rapid5 { didSet { saveSettings() } }
    @Published var sfxEnabled = true { didSet { saveSettings() } }
    @Published var musicEnabled = true { didSet { saveSettings(); SoundEngine.shared.toggleMusic(musicEnabled) } }
    @Published var voiceEnabled = true { didSet { saveSettings() } }
    @Published var showHints = true { didSet { saveSettings(); refreshHighlights() } }

    // Сцена
    let boardCtl = BoardController()
    let space = SpaceScene()
    weak var arSceneView: ARSCNView?
    var arBoardAnchorNode: SCNNode?

    // Состояние партии
    private var board = ChessBoard.initial()
    private var history: [HistoryEntry] = []
    private var positionCounts: [PositionKey: Int] = [:]
    private var selectedSquare: Int? = nil
    private var legalForSelected: [Move] = []
    private var lastMove: Move? = nil
    private var gameToken = 0
    private var pendingBotMove: Move? = nil
    private var isLoadingSettings = false

    init() {
        isLoadingSettings = true
        loadSettings()
        isLoadingSettings = false
        loadSavesFromDisk()
        positionCounts = [board.key: 1]
        boardCtl.reset(board: board, flipped: false)
        SoundEngine.shared.toggleMusic(musicEnabled)
    }

    var isHumanTurn: Bool {
        if mode == .passAndPlay { return true }
        return board.whiteToMove == (playerSide == .white)
    }

    var shouldFlipCamera: Bool { mode == .vsBot && playerSide == .black }
    var hasAutoSave: Bool { saveSlots.contains { $0.id == "auto" } }

    // MARK: Настройки

    private func saveSettings() {
        if isLoadingSettings { return }
        let d = UserDefaults.standard
        d.set(sfxEnabled, forKey: "Vibe_Sfx")
        d.set(musicEnabled, forKey: "Vibe_Music")
        d.set(voiceEnabled, forKey: "Vibe_Voice")
        d.set(showHints, forKey: "Vibe_Hints")
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
        if let m = d.string(forKey: "Vibe_Mode"), let v = GameMode(rawValue: m) { mode = v }
        if let m = d.string(forKey: "Vibe_Diff"), let v = BotDifficulty(rawValue: m) { difficulty = v }
        if let m = d.string(forKey: "Vibe_Time"), let v = TimeControl(rawValue: m) { timeControl = v }
        if let m = d.string(forKey: "Vibe_Side2"), let v = Side(rawValue: m) { playerSide = v }
    }

    // MARK: Старт, пауза, выход

    func startNewGame() {
        gameToken += 1
        pendingBotMove = nil
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

    // MARK: Ввод игрока

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

    private func select(_ s: Int) {
        selectedSquare = s
        legalForSelected = board.legalMoves().filter { $0.from == s }
        boardCtl.setLift(s)
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

    // MARK: Ход

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

    // MARK: Бот

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

    // MARK: Откат

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

    // MARK: Часы

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

    // MARK: Сохранения

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
        space.focus(flipped: shouldFlipCamera)
        refreshHighlights()
        updateStatus()
        SoundEngine.shared.play("select", enabled: sfxEnabled)
        evaluateGameState()
        if gameResult == nil && mode == .vsBot && !isHumanTurn { triggerBotMove() }
    }

    // MARK: ИИ-чат

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

    // MARK: Сцена

    func attachBoardToSpace() {
        arBoardAnchorNode = nil
        boardCtl.root.removeFromParentNode()
        boardCtl.root.position = SCNVector3Zero
        space.scene.rootNode.addChildNode(boardCtl.root)
    }

    func attachBoard(to node: SCNNode) {
        boardCtl.root.removeFromParentNode()
        node.addChildNode(boardCtl.root)
    }
}

// MARK: - Фигуры (точёные профили Штаунтона)

enum Lathe {
    // Тело вращения по профилю (радиус, высота) снизу вверх
    static func geometry(_ profile: [(Float, Float)], segments: Int = 36) -> SCNGeometry {
        let n = profile.count
        var segN: [(Float, Float)] = []
        for i in 0..<(n - 1) {
            let dr = profile[i + 1].0 - profile[i].0
            let dy = profile[i + 1].1 - profile[i].1
            let len = max(0.0001, (dr * dr + dy * dy).squareRoot())
            segN.append((dy / len, -dr / len))
        }
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
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
            for j in 0...segments {
                let a = Float(j) / Float(segments) * 2 * Float.pi
                let c = cos(a)
                let s = sin(a)
                vertices.append(SCNVector3(r * c, y, r * s))
                normals.append(SCNVector3(nn.0 * c, nn.1, nn.0 * s))
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
        let el = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vs, ns], elements: [el])
    }
}

enum PieceBuilder {
    private static var templates: [Int: SCNNode] = [:]

    static func node(for code: Int8) -> SCNNode {
        let key = Int(code)
        if let t = templates[key] { return t.clone() }
        let t = build(code)
        templates[key] = t
        return t.clone()
    }

    private static func material(white: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        if white {
            m.diffuse.contents = UIColor(red: 0.95, green: 0.91, blue: 0.82, alpha: 1)
            m.roughness.contents = 0.32
            m.metalness.contents = 0.0
        } else {
            m.diffuse.contents = UIColor(red: 0.13, green: 0.10, blue: 0.09, alpha: 1)
            m.roughness.contents = 0.28
            m.metalness.contents = 0.15
        }
        return m
    }

    private static func lathe(_ p: [(Float, Float)], _ mat: SCNMaterial) -> SCNNode {
        let g = Lathe.geometry(p)
        g.materials = [mat]
        return SCNNode(geometry: g)
    }

    private static func sphere(_ r: CGFloat, _ mat: SCNMaterial, _ x: Float, _ y: Float, _ z: Float) -> SCNNode {
        let s = SCNSphere(radius: r)
        s.segmentCount = 20
        s.materials = [mat]
        let n = SCNNode(geometry: s)
        n.position = SCNVector3(x, y, z)
        return n
    }

    private static func build(_ code: Int8) -> SCNNode {
        let type = abs(Int(code))
        let white = code > 0
        let mat = material(white: white)
        let root = SCNNode()
        let base: [(Float, Float)] = [(0, 0), (0.35, 0), (0.35, 0.06), (0.31, 0.10), (0.26, 0.13)]

        switch type {
        case 1:
            let body: [(Float, Float)] = [(0.20, 0.17), (0.13, 0.30), (0.11, 0.42), (0.19, 0.46), (0.19, 0.50),
                                              (0.11, 0.53), (0.15, 0.58), (0.17, 0.66), (0.15, 0.74), (0.08, 0.80), (0, 0.82)]
            root.addChildNode(lathe(base + body, mat))
        case 2:
            let body: [(Float, Float)] = [(0.21, 0.18), (0.17, 0.32), (0.16, 0.44), (0.18, 0.50), (0.0, 0.50)]
            root.addChildNode(lathe(base + body, mat))
            let neck = SCNBox(width: 0.26, height: 0.58, length: 0.30, chamferRadius: 0.06)
            neck.materials = [mat]
            let nn = SCNNode(geometry: neck)
            nn.position = SCNVector3(0, 0.74, 0.02)
            nn.eulerAngles.x = -0.22
            root.addChildNode(nn)
            let head = SCNBox(width: 0.22, height: 0.22, length: 0.48, chamferRadius: 0.07)
            head.materials = [mat]
            let hn = SCNNode(geometry: head)
            hn.position = SCNVector3(0, 1.0, -0.14)
            hn.eulerAngles.x = -0.25
            root.addChildNode(hn)
            for sx in [Float(-0.06), Float(0.06)] {
                let ear = SCNPyramid(width: 0.07, height: 0.15, length: 0.07)
                ear.materials = [mat]
                let en = SCNNode(geometry: ear)
                en.position = SCNVector3(sx, 1.08, 0.08)
                root.addChildNode(en)
            }
            if !white { root.eulerAngles.y = Float.pi }
        case 3:
            let body: [(Float, Float)] = [(0.17, 0.20), (0.12, 0.38), (0.10, 0.52), (0.20, 0.56), (0.20, 0.60),
                                              (0.10, 0.63), (0.18, 0.70), (0.20, 0.80), (0.17, 0.92), (0.10, 1.02), (0.04, 1.08),
                                              (0.07, 1.11), (0.07, 1.15), (0.04, 1.18), (0, 1.19)]
            root.addChildNode(lathe(base + body, mat))
        case 4:
            let body: [(Float, Float)] = [(0.22, 0.20), (0.19, 0.40), (0.18, 0.60), (0.26, 0.64), (0.28, 0.68),
                                              (0.28, 0.86), (0.22, 0.86), (0.22, 0.80), (0, 0.80)]
            root.addChildNode(lathe(base + body, mat))
            for k in 0..<8 {
                let a = Float(k) * Float.pi / 4
                let b = SCNBox(width: 0.11, height: 0.10, length: 0.11, chamferRadius: 0.01)
                b.materials = [mat]
                let bn = SCNNode(geometry: b)
                bn.position = SCNVector3(0.245 * cos(a), 0.91, 0.245 * sin(a))
                bn.eulerAngles.y = -a
                root.addChildNode(bn)
            }
        case 5:
            let body: [(Float, Float)] = [(0.19, 0.22), (0.14, 0.45), (0.12, 0.70), (0.22, 0.74), (0.22, 0.78),
                                              (0.12, 0.81), (0.17, 0.90), (0.24, 1.02), (0.27, 1.12), (0.20, 1.14),
                                              (0.12, 1.10), (0, 1.10)]
            root.addChildNode(lathe(base + body, mat))
            root.addChildNode(sphere(0.07, mat, 0, 1.20, 0))
            for k in 0..<8 {
                let a = Float(k) * Float.pi / 4
                root.addChildNode(sphere(0.04, mat, 0.23 * cos(a), 1.16, 0.23 * sin(a)))
            }
        default:
            let body: [(Float, Float)] = [(0.19, 0.22), (0.15, 0.45), (0.13, 0.72), (0.24, 0.76), (0.24, 0.80),
                                              (0.13, 0.83), (0.20, 0.92), (0.25, 1.05), (0.26, 1.14), (0.14, 1.16), (0, 1.16)]
            root.addChildNode(lathe(base + body, mat))
            let v = SCNBox(width: 0.09, height: 0.32, length: 0.09, chamferRadius: 0.015)
            v.materials = [mat]
            let vn = SCNNode(geometry: v)
            vn.position = SCNVector3(0, 1.32, 0)
            root.addChildNode(vn)
            let h = SCNBox(width: 0.25, height: 0.08, length: 0.09, chamferRadius: 0.015)
            h.materials = [mat]
            let hn = SCNNode(geometry: h)
            hn.position = SCNVector3(0, 1.36, 0)
            root.addChildNode(hn)
        }
        return root
    }
}

// MARK: - Доска (общая для 3D и AR)

final class BoardController {
    let root = SCNNode()
    private let squaresNode = SCNNode()
    private let piecesNode = SCNNode()
    private let labelsNode = SCNNode()
    private var overlays: [SCNNode] = []
    private var overlayMats: [SCNMaterial] = []
    private var pieceNodes: [Int: SCNNode] = [:]
    private var labelContainers: [SCNNode] = []
    private var liftedSquare: Int? = nil
    private var animationToken = 0
    private let restY: Float = 0.075

    init() {
        root.addChildNode(squaresNode)
        root.addChildNode(piecesNode)
        root.addChildNode(labelsNode)
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

    // MARK: Построение

    private func buildSquares() {
        for s in 0..<64 {
            let c = s & 7
            let r = s >> 3
            let dark = (r + c) % 2 == 0
            let box = SCNBox(width: 1.0, height: 0.15, length: 1.0, chamferRadius: 0)
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            if dark {
                if let img = TextureCache.wood { mat.diffuse.contents = img } else { mat.diffuse.contents = UIColor(red: 0.40, green: 0.25, blue: 0.14, alpha: 1) }
                mat.roughness.contents = 0.45
            } else {
                if let img = TextureCache.marble { mat.diffuse.contents = img } else { mat.diffuse.contents = UIColor(red: 0.90, green: 0.87, blue: 0.80, alpha: 1) }
                mat.roughness.contents = 0.25
            }
            mat.metalness.contents = 0.0
            mat.diffuse.wrapS = .repeat
            mat.diffuse.wrapT = .repeat
            let ox = Float((s * 53) % 16) / 16.0
            let oy = Float((s * 29 + 7) % 16) / 16.0
            mat.diffuse.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(0.5, 0.5, 1), SCNMatrix4MakeTranslation(ox, oy, 0))
            box.materials = [mat]
            let node = SCNNode(geometry: box)
            node.name = "sq_\(s)"
            node.position = SCNVector3(Float(c) - 3.5, 0, 3.5 - Float(r))
            squaresNode.addChildNode(node)

            let plane = SCNPlane(width: 0.94, height: 0.94)
            let om = SCNMaterial()
            om.lightingModel = .constant
            om.diffuse.contents = UIColor.green
            om.transparency = 0.5
            om.isDoubleSided = true
            om.writesToDepthBuffer = false
            plane.materials = [om]
            let on = SCNNode(geometry: plane)
            on.name = "sq_\(s)"
            on.eulerAngles.x = -Float.pi / 2
            on.position = SCNVector3(Float(c) - 3.5, 0.082, 3.5 - Float(r))
            on.renderingOrder = 10
            on.isHidden = true
            squaresNode.addChildNode(on)
            overlays.append(on)
            overlayMats.append(om)
        }
    }

    private func buildFrame() {
        let fm = SCNMaterial()
        fm.lightingModel = .physicallyBased
        if let img = TextureCache.wood {
            fm.diffuse.contents = img
            fm.multiply.contents = UIColor(red: 0.55, green: 0.40, blue: 0.32, alpha: 1)
        } else {
            fm.diffuse.contents = UIColor(red: 0.22, green: 0.13, blue: 0.08, alpha: 1)
        }
        fm.roughness.contents = 0.4
        let strips: [(CGFloat, CGFloat, Float, Float)] = [
            (9.9, 0.95, 0, 4.475), (9.9, 0.95, 0, -4.475), (0.95, 8.0, 4.475, 0), (0.95, 8.0, -4.475, 0)
        ]
        for (w, l, x, z) in strips {
            let b = SCNBox(width: w, height: 0.3, length: l, chamferRadius: 0.03)
            b.materials = [fm]
            let n = SCNNode(geometry: b)
            n.position = SCNVector3(x, restY - 0.15, z)
            root.addChildNode(n)
        }
        let slab = SCNBox(width: 10.5, height: 0.25, length: 10.5, chamferRadius: 0.05)
        slab.materials = [fm]
        let sn = SCNNode(geometry: slab)
        sn.position = SCNVector3(0, -0.35, 0)
        root.addChildNode(sn)
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
        container.position = SCNVector3(x, 0.09, z)
        let plane = SCNPlane(width: 0.5, height: 0.5)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = BoardController.labelImage(text)
        m.isDoubleSided = true
        plane.materials = [m]
        let pn = SCNNode(geometry: plane)
        pn.eulerAngles.x = -Float.pi / 2
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
                .foregroundColor: UIColor(red: 0.96, green: 0.86, blue: 0.62, alpha: 1.0),
                .paragraphStyle: style
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let h = str.size().height
            str.draw(in: CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h))
        }
    }

    // MARK: Состояние

    func setFlipped(_ flipped: Bool) {
        let a: Float = flipped ? Float.pi : 0
        for c in labelContainers { c.eulerAngles.y = a }
    }

    func reset(board: ChessBoard, flipped: Bool) {
        animationToken += 1
        setFlipped(flipped)
        rebuild(from: board)
    }

    private func rebuild(from board: ChessBoard) {
        for n in piecesNode.childNodes where n.name != "fly" { n.removeFromParentNode() }
        pieceNodes.removeAll()
        liftedSquare = nil
        for s in 0..<64 {
            let code = board.sq[s]
            if code == 0 { continue }
            let n = PieceBuilder.node(for: code)
            n.name = "pc_\(s)"
            n.position = pos(s)
            piecesNode.addChildNode(n)
            pieceNodes[s] = n
        }
    }

    func setHighlights(selected: Int?, targets: [Int: Bool], last: Move?, check: Int?) {
        for o in overlays { o.isHidden = true }
        func show(_ s: Int, _ color: UIColor, _ alpha: CGFloat) {
            if s < 0 || s >= 64 { return }
            overlays[s].isHidden = false
            overlayMats[s].diffuse.contents = color
            overlayMats[s].transparency = alpha
        }
        if let l = last {
            show(l.from, UIColor.yellow, 0.30)
            show(l.to, UIColor.yellow, 0.40)
        }
        if let s = selected { show(s, UIColor.cyan, 0.55) }
        for (s, isCapture) in targets {
            show(s, isCapture ? UIColor.systemRed : UIColor.systemGreen, 0.65)
        }
        if let c = check { show(c, UIColor.red, 0.75) }
    }

    func setLift(_ s: Int?) {
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

    func animate(move m: Move, before: ChessBoard, after: ChessBoard, completion: @escaping () -> Void) {
        liftedSquare = nil
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
        mover.removeAllActions()

        // Взятая фигура (в том числе на проходе)
        var capSq = -1
        if before.sq[m.to] != 0 {
            capSq = m.to
        } else if abs(Int(before.sq[m.from])) == 1 && (m.from & 7) != (m.to & 7) {
            capSq = (m.from >> 3) * 8 + (m.to & 7)
        }
        if capSq >= 0, let cap = pieceNodes[capSq] {
            pieceNodes[capSq] = nil
            cap.name = "fly"
            let dx = CGFloat.random(in: -2...2)
            let dz = CGFloat.random(in: -2...2)
            let fly = SCNAction.group([
                SCNAction.moveBy(x: dx, y: 2.5, z: dz, duration: 0.6),
                SCNAction.fadeOut(duration: 0.6),
                SCNAction.rotateBy(x: 3, y: 0, z: 2, duration: 0.6)
            ])
            cap.runAction(SCNAction.sequence([SCNAction.wait(duration: 0.25), fly, SCNAction.removeFromParentNode()]))
        }

        // Рокировка: двигаем ладью
        let fromCol = m.from & 7
        let toCol = m.to & 7
        if abs(Int(before.sq[m.from])) == 6 && abs(toCol - fromCol) == 2 {
            let base = (m.from >> 3) * 8
            let rookFrom = base + (toCol == 6 ? 7 : 0)
            let rookTo = base + (toCol == 6 ? 5 : 3)
            if let rook = pieceNodes[rookFrom] {
                pieceNodes[rookFrom] = nil
                rook.removeAllActions()
                let rp = pos(rookTo)
                let up = SCNAction.move(to: SCNVector3(rook.position.x, restY + 0.5, rook.position.z), duration: 0.12)
                let glide = SCNAction.move(to: SCNVector3(rp.x, restY + 0.5, rp.z), duration: 0.28)
                let down = SCNAction.move(to: rp, duration: 0.12)
                rook.runAction(SCNAction.sequence([up, glide, down]))
            }
        }

        let target = pos(m.to)
        let lift = SCNAction.move(to: SCNVector3(mover.position.x, restY + 0.7, mover.position.z), duration: 0.12)
        let glide = SCNAction.move(to: SCNVector3(target.x, restY + 0.7, target.z), duration: 0.28)
        let drop = SCNAction.move(to: target, duration: 0.12)
        lift.timingMode = .easeOut
        glide.timingMode = .easeInEaseOut
        drop.timingMode = .easeIn
        let done = SCNAction.run { _ in
            DispatchQueue.main.async { finish() }
        }
        mover.runAction(SCNAction.sequence([lift, glide, drop, done]))
        // Страховка: если анимация почему-то не дошла до конца
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { finish() }
    }
}

// MARK: - Космос и камера

final class SpaceScene {
    let scene = SCNScene()
    let orbit = SCNNode()
    private let pitch = SCNNode()
    private let camNode = SCNNode()
    private let baseCam = SCNVector3(0, 9.6, 9.0)
    private var zoom: Float = 1.0

    init() {
        scene.background.contents = UIColor(red: 0.004, green: 0.006, blue: 0.02, alpha: 1)
        scene.lightingEnvironment.contents = SpaceScene.environmentImage()
        scene.lightingEnvironment.intensity = 1.1
        buildSky()
        buildCameraAndLights()
        startMenuOrbit()
    }

    var cameraNode: SCNNode { camNode }

    static func environmentImage() -> UIImage {
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

    private func ringPosition(_ angleDeg: Float, _ radius: Float, _ y: Float) -> SCNVector3 {
        let a = angleDeg * Float.pi / 180
        return SCNVector3(radius * sin(a), y, -radius * cos(a))
    }

    private func planet(radius: CGFloat, image: UIImage?, fallback: UIColor) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        sphere.segmentCount = 48
        let m = SCNMaterial()
        if let img = image { m.diffuse.contents = img } else { m.diffuse.contents = fallback }
        m.specular.contents = UIColor(white: 0.15, alpha: 1)
        sphere.materials = [m]
        return SCNNode(geometry: sphere)
    }

    private func buildSky() {
        // Солнце
        let sun = SCNSphere(radius: 4.5)
        sun.segmentCount = 48
        let sm = SCNMaterial()
        sm.lightingModel = .constant
        if let img = TextureCache.sun {
            sm.diffuse.contents = img
            sm.emission.contents = img
        } else {
            sm.diffuse.contents = UIColor(red: 1.0, green: 0.75, blue: 0.25, alpha: 1)
            sm.emission.contents = UIColor(red: 1.0, green: 0.65, blue: 0.15, alpha: 1)
        }
        sm.emission.intensity = 2.0
        sun.materials = [sm]
        let sunNode = SCNNode(geometry: sun)
        sunNode.position = ringPosition(150, 34, 3)
        sunNode.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.3, z: 0, duration: 30)))
        scene.rootNode.addChildNode(sunNode)

        // Земля и Луна
        let earth = planet(radius: 2.6, image: TextureCache.earth, fallback: UIColor.systemBlue)
        earth.position = ringPosition(-10, 27, -1)
        let moon = planet(radius: 0.7, image: TextureCache.moon, fallback: UIColor.lightGray)
        moon.position = SCNVector3(4.2, 0.8, 0)
        earth.addChildNode(moon)
        earth.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.6, z: 0, duration: 24)))
        scene.rootNode.addChildNode(earth)

        // Марс
        let mars = planet(radius: 1.5, image: TextureCache.mars, fallback: UIColor.systemRed)
        mars.position = ringPosition(-62, 30, 1)
        mars.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.5, z: 0, duration: 26)))
        scene.rootNode.addChildNode(mars)

        // Сатурн с кольцами
        let saturn = planet(radius: 3.0, image: TextureCache.saturn, fallback: UIColor(red: 0.82, green: 0.68, blue: 0.5, alpha: 1))
        saturn.position = ringPosition(24, 33, 0.5)
        let ring = SCNTube(innerRadius: 4.0, outerRadius: 6.2, height: 0.04)
        let rm = SCNMaterial()
        rm.diffuse.contents = UIColor(red: 0.88, green: 0.78, blue: 0.60, alpha: 1)
        rm.transparency = 0.7
        rm.isDoubleSided = true
        ring.materials = [rm]
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles.x = 0.4
        saturn.addChildNode(ringNode)
        saturn.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0.4, z: 0, duration: 30)))
        scene.rootNode.addChildNode(saturn)

        // Звёзды (одна общая геометрия)
        let starGeo = SCNSphere(radius: 0.12)
        starGeo.segmentCount = 6
        let stm = SCNMaterial()
        stm.lightingModel = .constant
        stm.diffuse.contents = UIColor.white
        starGeo.materials = [stm]
        let stars = SCNNode()
        for _ in 0..<350 {
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
            let d = Float.random(in: 60...90) / len
            let n = SCNNode(geometry: starGeo)
            n.position = SCNVector3(x * d, y * d, z * d)
            let k = Float.random(in: 0.4...1.3)
            n.scale = SCNVector3(k, k, k)
            stars.addChildNode(n)
        }
        scene.rootNode.addChildNode(stars)
    }

    private func buildCameraAndLights() {
        let cam = SCNCamera()
        cam.zNear = 0.1
        cam.zFar = 200
        cam.fieldOfView = 55
        cam.wantsHDR = true
        cam.bloomIntensity = 0.9
        cam.bloomThreshold = 1.0
        cam.bloomBlurRadius = 8
        camNode.camera = cam
        camNode.position = baseCam
        camNode.look(at: SCNVector3(0, 0, -0.3))
        pitch.addChildNode(camNode)
        orbit.addChildNode(pitch)
        scene.rootNode.addChildNode(orbit)

        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.intensity = 900
        sunLight.color = UIColor(red: 1.0, green: 0.96, blue: 0.88, alpha: 1)
        sunLight.castsShadow = true
        sunLight.shadowMode = .deferred
        sunLight.shadowSampleCount = 8
        sunLight.shadowRadius = 3.5
        sunLight.shadowColor = UIColor(white: 0, alpha: 0.55)
        let ln = SCNNode()
        ln.light = sunLight
        ln.position = SCNVector3(5, 15, 9)
        ln.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(ln)

        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 260
        let an = SCNNode()
        an.light = amb
        scene.rootNode.addChildNode(an)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 250
        fill.color = UIColor(red: 0.6, green: 0.7, blue: 1.0, alpha: 1)
        let fn = SCNNode()
        fn.light = fill
        fn.position = SCNVector3(-8, 6, -8)
        fn.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(fn)
    }

    // MARK: Камера

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
    }
}

// MARK: - 3D-контейнер

struct Chess3DContainer: UIViewRepresentable {
    @ObservedObject var gm: GameManager

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = gm.space.scene
        view.pointOfView = gm.space.cameraNode
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.backgroundColor = UIColor.black
        gm.attachBoardToSpace()
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(gm: gm) }

    final class Coordinator: NSObject {
        let gm: GameManager
        init(gm: GameManager) { self.gm = gm }

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

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let t = g.translation(in: view)
            gm.space.pan(dx: t.x, dy: t.y)
            g.setTranslation(CGPoint.zero, in: view)
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            gm.space.pinch(scale: g.scale)
            g.scale = 1.0
        }
    }
}

// MARK: - AR-контейнер

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

// MARK: - Приложение

@main
struct VibeChessApp: App {
    var body: some Scene {
        WindowGroup {
            MainGameView()
        }
    }
}

// MARK: - Стиль

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

// MARK: - Главный экран

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

// MARK: - Меню

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

// MARK: - Игровой HUD

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

            HStack {
                Button(action: { gm.performUndo() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Откат (\(gm.undoCount))")
                    }
                    .font(mono(11))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glass(10)
                    .opacity(gm.undoCount > 0 ? 1.0 : 0.4)
                }
                Spacer()
                Text(gm.lastMoveNotation)
                    .font(mono(12))
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .glass(10)
            }
            .padding(.horizontal, 16)
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

// MARK: - Оверлеи

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

// MARK: - Окна

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
// ==================== КОНЕЦ ФАЙЛА ====================
