import Foundation

enum Stone: String, Codable {
    case empty
    case black
    case white

    var opposite: Stone {
        switch self {
        case .black: return .white
        case .white: return .black
        case .empty: return .empty
        }
    }
}

enum PlayerType: String, CaseIterable, Identifiable, Codable {
    case human = "Human"
    case ai = "AI"

    var id: String { rawValue }
}

enum AIStrength: String, CaseIterable, Identifiable, Codable {
    case fast = "Fast"
    case normal = "Normal"
    case strong = "Strong"

    var id: String { rawValue }
}

enum CaptureReadingStrength: String, CaseIterable, Identifiable, Codable {
    case off = "Off"
    case normal = "Normal"
    case deep = "Deep"

    var id: String { rawValue }
}

private struct Point: Hashable {
    let row: Int
    let col: Int
}

private struct SimState {
    var board: [[Stone]]
    var currentPlayer: Stone
    var capturesBlack: Int
    var capturesWhite: Int
    var currentBoardHash: UInt64?
    var koForbiddenHash: UInt64?
    var consecutivePasses: Int
}

private struct FastSimState {
    var board: [UInt8] // 0 empty, 1 black, 2 white
    var currentPlayer: UInt8
    var capturesBlack: Int
    var capturesWhite: Int
    var currentBoardHash: UInt64?
    var koForbiddenHash: UInt64?
    var consecutivePasses: Int
}

private struct CandidateMove {
    let row: Int
    let col: Int
    let immediateScore: Int
    let policyPrior: Double
    let capturesGained: Int
    let selfFillNoTactics: Bool
    let stateAfterMove: SimState
}

private struct FastCandidateMove {
    let index: Int
    let immediateScore: Int
    let policyPrior: Double
    let capturesGained: Int
    let selfFillNoTactics: Bool
    let stateAfterMove: FastSimState
}

private struct ImmediateHeuristicResult {
    let score: Int
    let selfFillNoTactics: Bool
}

private enum CornerOrientation: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

private struct JosekiRule {
    let requiredOwn: [(Int, Int)]
    let requiredOpp: [(Int, Int)]
    let suggestions: [(Int, Int)]
}

private struct TacticalGroupInfoFast {
    let representative: Int
    let size: Int
    let liberties: [Int]
}

enum StrategyGhostKind: Hashable {
    case current
    case best
    case opponentResponse
    case aiFollowUp
}

struct StrategyGhostStone: Identifiable, Hashable {
    let row: Int
    let col: Int
    let stone: Stone
    let kind: StrategyGhostKind

    var id: String { "\(row)-\(col)-\(stone.rawValue)-\(kind)" }
}

private struct StaticEvalKey: Hashable {
    let boardFingerprint: Int
    let capturesBlack: Int
    let capturesWhite: Int
    let perspective: Stone
}

private final class SearchEvalCache {
    private var staticScores: [StaticEvalKey: Double] = [:]

    func value(for key: StaticEvalKey) -> Double? {
        return staticScores[key]
    }

    func store(_ value: Double, for key: StaticEvalKey) {
        if staticScores.count > 80_000 {
            staticScores.removeAll(keepingCapacity: true)
        }
        staticScores[key] = value
    }
}

private final class RolloutThreadCache {
    var ownersByHash: [UInt64: [UInt8]] = [:]
    var preferredEmptyByHash: [UInt64: [Int]] = [:]
    var openingLikelyByHash: [UInt64: Bool] = [:]
    var endgameLikelyByHash: [UInt64: Bool] = [:]
    var visitMarks: [UInt32] = []
    var libertyMarks: [UInt32] = []
    var tempMarks: [UInt32] = []
    var stackBuffer: [Int] = []
    var groupBuffer: [Int] = []
    private var markCounter: UInt32 = 1

    func trimIfNeeded() {
        if ownersByHash.count > 512 {
            ownersByHash.removeAll(keepingCapacity: true)
        }
        if preferredEmptyByHash.count > 512 {
            preferredEmptyByHash.removeAll(keepingCapacity: true)
        }
        if openingLikelyByHash.count > 1024 {
            openingLikelyByHash.removeAll(keepingCapacity: true)
        }
        if endgameLikelyByHash.count > 1024 {
            endgameLikelyByHash.removeAll(keepingCapacity: true)
        }
    }

    func ensureCapacity(_ capacity: Int) {
        if visitMarks.count < capacity {
            visitMarks = Array(repeating: 0, count: capacity)
        }
        if libertyMarks.count < capacity {
            libertyMarks = Array(repeating: 0, count: capacity)
        }
        if tempMarks.count < capacity {
            tempMarks = Array(repeating: 0, count: capacity)
        }
        if stackBuffer.capacity < capacity {
            stackBuffer.reserveCapacity(capacity)
        }
        if groupBuffer.capacity < capacity {
            groupBuffer.reserveCapacity(capacity)
        }
    }

    func nextMark() -> UInt32 {
        if markCounter == UInt32.max - 1 {
            visitMarks = Array(repeating: 0, count: visitMarks.count)
            libertyMarks = Array(repeating: 0, count: libertyMarks.count)
            tempMarks = Array(repeating: 0, count: tempMarks.count)
            markCounter = 1
        } else {
            markCounter &+= 1
        }
        return markCounter
    }
}

final class GoGameViewModel: ObservableObject {
    private static let evalCacheThreadKey = "GoGameViewModel.evalCache"
    private static let rolloutCacheThreadKey = "GoGameViewModel.rolloutCache"
    private let whiteKomi: Double = 6.5
    private var isRestoringFromLoad = false
    private var turnStartDate: Date?
    private var turnTicker: Timer?
    private var pausedAt: Date?
    private var aiComputationToken: Int = 0
    @Published private(set) var isAIThinking: Bool = false

    @Published var boardSize: Int = 9 {
        didSet {
            guard !isRestoringFromLoad else { return }
            guard oldValue != boardSize else { return }
            newGame()
        }
    }
    @Published var blackPlayer: PlayerType = .human {
        didSet {
            guard !isRestoringFromLoad else { return }
            if currentPlayer == .black { scheduleAIMoveIfNeeded() }
        }
    }
    @Published var whitePlayer: PlayerType = .ai {
        didSet {
            guard !isRestoringFromLoad else { return }
            if currentPlayer == .white { scheduleAIMoveIfNeeded() }
        }
    }
    @Published var aiStrength: AIStrength = .normal
    @Published var tacticalModeEnabled: Bool = false {
        didSet {
            guard !isRestoringFromLoad else { return }
            _ = saveGameToDisk(manual: false)
            if playerType(for: currentPlayer) == .ai {
                scheduleAIMoveIfNeeded()
            }
        }
    }
    @Published var captureReadingStrength: CaptureReadingStrength = .normal {
        didSet {
            guard !isRestoringFromLoad else { return }
            _ = saveGameToDisk(manual: false)
            if playerType(for: currentPlayer) == .ai {
                scheduleAIMoveIfNeeded()
            }
        }
    }
    @Published var showStrategyEnabled: Bool = false {
        didSet {
            guard !isRestoringFromLoad else { return }
            if !showStrategyEnabled {
                clearStrategyDisplay()
            }
            _ = saveGameToDisk(manual: false)
        }
    }
    @Published var josekiBookEnabled: Bool = true {
        didSet {
            guard !isRestoringFromLoad else { return }
            _ = saveGameToDisk(manual: false)
            if playerType(for: currentPlayer) == .ai {
                scheduleAIMoveIfNeeded()
            }
        }
    }
    @Published private(set) var isAIPaused: Bool = false

    @Published private(set) var board: [[Stone]] = []
    @Published private(set) var currentPlayer: Stone = .black
    @Published private(set) var capturesBlack: Int = 0
    @Published private(set) var capturesWhite: Int = 0
    @Published private(set) var territoryBlack: Int = 0
    @Published private(set) var territoryWhite: Int = 0
    @Published private(set) var finalBlackScore: Double?
    @Published private(set) var finalWhiteScore: Double?
    @Published private(set) var gameOver: Bool = false
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var moveHistory: [String] = []
    @Published private(set) var currentTurnElapsed: TimeInterval = 0
    @Published private(set) var totalTimeBlack: TimeInterval = 0
    @Published private(set) var totalTimeWhite: TimeInterval = 0
    @Published private(set) var lastMoveRow: Int?
    @Published private(set) var lastMoveCol: Int?
    @Published private(set) var strategyGhosts: [StrategyGhostStone] = []

    private var currentBoardHash: UInt64?
    private var koForbiddenHash: UInt64?
    private var consecutivePasses = 0
    private var historyStack: [Snapshot] = []
    private var neighborTable: [[Point]] = []
    private var neighborIndexTable: [[Int]] = []
    private var zobristBlack: [UInt64] = []
    private var zobristWhite: [UInt64] = []
    private var zobristBoardSalt: UInt64 = 0
    private var activeStrategyToken: Int = 0
    private var strategyGhostPublishLock = NSLock()
    private var strategyGhostLastPublishUptime: TimeInterval = 0
    private var strategyGhostLastCurrent: (row: Int, col: Int)?
    private var strategyGhostLastBest: (row: Int, col: Int)?

    private struct SavedGame: Codable {
        let boardSize: Int
        let blackPlayer: PlayerType
        let whitePlayer: PlayerType
        let aiStrength: AIStrength
        let tacticalModeEnabled: Bool?
        let captureReadingStrength: CaptureReadingStrength?
        let showStrategyEnabled: Bool?
        let josekiBookEnabled: Bool?
        let isAIPaused: Bool
        let board: [[Stone]]
        let currentPlayer: Stone
        let capturesBlack: Int
        let capturesWhite: Int
        let territoryBlack: Int
        let territoryWhite: Int
        let finalBlackScore: Double?
        let finalWhiteScore: Double?
        let gameOver: Bool
        let statusMessage: String
        let moveHistory: [String]
        let currentTurnElapsed: TimeInterval?
        let totalTimeBlack: TimeInterval?
        let totalTimeWhite: TimeInterval?
        let lastMoveRow: Int?
        let lastMoveCol: Int?
        let currentBoardHash: String?
        let koForbiddenHash: String?
        let previousBoardHash: String? // legacy compatibility
        let consecutivePasses: Int
    }

    private struct Snapshot {
        let board: [[Stone]]
        let currentPlayer: Stone
        let capturesBlack: Int
        let capturesWhite: Int
        let territoryBlack: Int
        let territoryWhite: Int
        let finalBlackScore: Double?
        let finalWhiteScore: Double?
        let gameOver: Bool
        let statusMessage: String
        let currentBoardHash: UInt64?
        let koForbiddenHash: UInt64?
        let consecutivePasses: Int
        let moveHistory: [String]
        let currentTurnElapsed: TimeInterval
        let totalTimeBlack: TimeInterval
        let totalTimeWhite: TimeInterval
        let lastMoveRow: Int?
        let lastMoveCol: Int?
    }

    init() {
        startTurnTicker()
        if !loadGameFromDisk(manual: false) {
            newGame()
        }
    }

    deinit {
        turnTicker?.invalidate()
    }

    func newGame() {
        isRestoringFromLoad = true
        rebuildNeighborTable()
        board = Array(
            repeating: Array(repeating: .empty, count: boardSize),
            count: boardSize
        )
        currentPlayer = .black
        capturesBlack = 0
        capturesWhite = 0
        territoryBlack = 0
        territoryWhite = 0
        finalBlackScore = nil
        finalWhiteScore = nil
        gameOver = false
        isAIPaused = false
        pausedAt = nil
        currentTurnElapsed = 0
        totalTimeBlack = 0
        totalTimeWhite = 0
        lastMoveRow = nil
        lastMoveCol = nil
        currentBoardHash = hash(for: board)
        koForbiddenHash = nil
        consecutivePasses = 0
        statusMessage = "Black to move"
        moveHistory = ["New game: \(boardSize)x\(boardSize)"]
        turnStartDate = Date()
        historyStack = [snapshot()]
        isRestoringFromLoad = false
        _ = saveGameToDisk(manual: false)
        scheduleAIMoveIfNeeded()
    }

    func undoMove() {
        guard historyStack.count > 1 else { return }
        historyStack.removeLast()
        guard let previous = historyStack.last else { return }
        restore(from: previous)
        statusMessage = "Undid last action. \(label(for: currentPlayer)) to move"
        _ = saveGameToDisk(manual: false)
        scheduleAIMoveIfNeeded()
    }

    func toggleAIPause() {
        guard !gameOver else { return }
        isAIPaused.toggle()
        if isAIPaused {
            aiComputationToken += 1
            isAIThinking = false
            refreshCurrentTurnElapsed()
            pausedAt = Date()
            statusMessage = "AI paused"
        } else {
            if let pausedAt {
                let pausedDuration = Date().timeIntervalSince(pausedAt)
                if let turnStartDate {
                    self.turnStartDate = turnStartDate.addingTimeInterval(pausedDuration)
                } else {
                    self.turnStartDate = Date().addingTimeInterval(-currentTurnElapsed)
                }
            }
            pausedAt = nil
            statusMessage = "\(label(for: currentPlayer)) to move"
            scheduleAIMoveIfNeeded()
        }
        _ = saveGameToDisk(manual: false)
    }

    func canPauseAI() -> Bool {
        playerType(for: currentPlayer) == .ai && !gameOver
    }

    func formattedCurrentTurnTime() -> String {
        formatDuration(currentTurnElapsed)
    }

    func formattedTotalTime(for stone: Stone) -> String {
        let total = stone == .black ? totalTimeBlack : totalTimeWhite
        return formatDuration(total)
    }

    @discardableResult
    func saveGameToDisk(manual: Bool = true) -> Bool {
        do {
            refreshCurrentTurnElapsed()
            let saved = SavedGame(
                boardSize: boardSize,
                blackPlayer: blackPlayer,
                whitePlayer: whitePlayer,
                aiStrength: aiStrength,
                tacticalModeEnabled: tacticalModeEnabled,
                captureReadingStrength: captureReadingStrength,
                showStrategyEnabled: showStrategyEnabled,
                josekiBookEnabled: josekiBookEnabled,
                isAIPaused: isAIPaused,
                board: board,
                currentPlayer: currentPlayer,
                capturesBlack: capturesBlack,
                capturesWhite: capturesWhite,
                territoryBlack: territoryBlack,
                territoryWhite: territoryWhite,
                finalBlackScore: finalBlackScore,
                finalWhiteScore: finalWhiteScore,
                gameOver: gameOver,
                statusMessage: statusMessage,
                moveHistory: moveHistory,
                currentTurnElapsed: currentTurnElapsed,
                totalTimeBlack: totalTimeBlack,
                totalTimeWhite: totalTimeWhite,
                lastMoveRow: lastMoveRow,
                lastMoveCol: lastMoveCol,
                currentBoardHash: encodeHashString(currentBoardHash),
                koForbiddenHash: encodeHashString(koForbiddenHash),
                previousBoardHash: encodeHashString(currentBoardHash),
                consecutivePasses: consecutivePasses
            )
            let data = try JSONEncoder().encode(saved)
            let url = try saveFileURL()
            try data.write(to: url, options: .atomic)
            if manual {
                statusMessage = "Game saved"
            }
            return true
        } catch {
            if manual {
                statusMessage = "Failed to save game"
            }
            return false
        }
    }

    @discardableResult
    func loadGameFromDisk(manual: Bool = true) -> Bool {
        do {
            let url = try saveFileURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                if manual { statusMessage = "No saved game found" }
                return false
            }

            let data = try Data(contentsOf: url)
            let saved = try JSONDecoder().decode(SavedGame.self, from: data)
            apply(savedGame: saved)

            if manual {
                if gameOver {
                    statusMessage = "Loaded saved game (finished)"
                } else if isAIPaused {
                    statusMessage = "Loaded saved game (AI paused)"
                } else {
                    statusMessage = "Loaded saved game. \(label(for: currentPlayer)) to move"
                }
            }

            scheduleAIMoveIfNeeded()
            return true
        } catch {
            if manual {
                statusMessage = "Failed to load saved game"
            }
            return false
        }
    }

    func isHumanTurn() -> Bool {
        playerType(for: currentPlayer) == .human
    }

    func playerType(for stone: Stone) -> PlayerType {
        stone == .black ? blackPlayer : whitePlayer
    }

    func playHuman(row: Int, col: Int) {
        guard isHumanTurn() else { return }
        guard !gameOver else { return }
        _ = playMove(row: row, col: col)
    }

    func passTurn() {
        guard !gameOver else { return }

        let passer = currentPlayer
        commitCurrentTurnTime(for: passer)
        consecutivePasses += 1
        moveHistory.append("\(shortLabel(for: passer)) pass")

        if consecutivePasses >= 2 {
            finishGame()
            saveSnapshot()
            return
        }

        currentPlayer = currentPlayer.opposite
        turnStartDate = Date()
        currentTurnElapsed = 0
        statusMessage = "\(label(for: passer)) passed. \(label(for: currentPlayer)) to move"
        saveSnapshot()
        scheduleAIMoveIfNeeded()
    }

    func aiMoveIfNeededNow() {
        guard playerType(for: currentPlayer) == .ai else { return }
        guard !isAIPaused else { return }
        guard !gameOver else { return }
        guard consecutivePasses < 2 else { return }
        guard !isAIThinking else { return }

        let stone = currentPlayer
        aiComputationToken += 1
        let token = aiComputationToken
        beginStrategySession(for: stone, token: token)
        isAIThinking = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let move = self.bestMove(for: stone, searchToken: token)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard token == self.aiComputationToken else { return }

                self.isAIThinking = false
                guard self.currentPlayer == stone else { return }
                guard self.playerType(for: self.currentPlayer) == .ai else { return }
                guard !self.isAIPaused else { return }
                guard !self.gameOver else { return }
                guard self.consecutivePasses < 2 else { return }

                if let move {
                    _ = self.playMove(row: move.0, col: move.1)
                } else {
                    self.passTurn()
                }
            }
        }
    }

    private func scheduleAIMoveIfNeeded() {
        guard playerType(for: currentPlayer) == .ai else { return }
        guard !isAIPaused else { return }
        guard !gameOver else { return }
        guard consecutivePasses < 2 else { return }
        guard !isAIThinking else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.aiMoveIfNeededNow()
        }
    }

    private func playMove(row: Int, col: Int) -> Bool {
        guard !gameOver else { return false }
        guard row >= 0, row < boardSize, col >= 0, col < boardSize else { return false }
        guard board[row][col] == .empty else {
            statusMessage = "That intersection is occupied"
            return false
        }

        var next = board
        let mover = currentPlayer
        next[row][col] = mover

        let capturedPoints = captureGroupsDetailed(of: mover.opposite, on: &next)

        if liberties(ofGroupAt: row, col: col, in: next).isEmpty {
            statusMessage = "Illegal move: suicide"
            return false
        }

        let boardHashBeforeMove = currentBoardHash ?? hash(for: board)
        var nextHash = boardHashBeforeMove
        nextHash ^= zobristValue(for: mover, row: row, col: col)
        for point in capturedPoints {
            nextHash ^= zobristValue(for: mover.opposite, row: point.row, col: point.col)
        }
        if let koForbiddenHash, koForbiddenHash == nextHash {
            statusMessage = "Illegal move: ko"
            return false
        }

        board = next
        commitCurrentTurnTime(for: mover)
        if mover == .black {
            capturesBlack += capturedPoints.count
        } else {
            capturesWhite += capturedPoints.count
        }

        updateTerritory()
        consecutivePasses = 0
        koForbiddenHash = boardHashBeforeMove
        currentBoardHash = nextHash
        currentPlayer = mover.opposite
        turnStartDate = Date()
        currentTurnElapsed = 0

        moveHistory.append("\(shortLabel(for: mover)) \(coordinateLabel(row: row, col: col))")
        lastMoveRow = row
        lastMoveCol = col
        statusMessage = "\(label(for: currentPlayer)) to move"
        saveSnapshot()
        scheduleAIMoveIfNeeded()
        return true
    }

    private func finishGame() {
        commitCurrentTurnTime(for: currentPlayer)
        gameOver = true
        turnStartDate = nil
        currentTurnElapsed = 0
        updateTerritory()

        let blackScore = Double(territoryBlack + capturesBlack)
        let whiteScore = Double(territoryWhite + capturesWhite) + whiteKomi
        finalBlackScore = blackScore
        finalWhiteScore = whiteScore

        let winnerText: String
        if blackScore > whiteScore {
            winnerText = "Black wins by \(String(format: "%.1f", blackScore - whiteScore))"
        } else if whiteScore > blackScore {
            winnerText = "White wins by \(String(format: "%.1f", whiteScore - blackScore))"
        } else {
            winnerText = "Draw"
        }

        statusMessage = "Game over. \(winnerText)"
        moveHistory.append(
            "Final: B \(String(format: "%.1f", blackScore)) - W \(String(format: "%.1f", whiteScore))"
        )
    }

    private func bestMove(for stone: Stone, searchToken: Int) -> (Int, Int)? {
        let root = FastSimState(
            board: flattenBoard(board),
            currentPlayer: stoneCode(for: stone),
            capturesBlack: capturesBlack,
            capturesWhite: capturesWhite,
            currentBoardHash: currentBoardHash,
            koForbiddenHash: koForbiddenHash,
            consecutivePasses: consecutivePasses
        )

        let candidateLimit: Int
        switch aiStrength {
        case .fast:
            candidateLimit = boardSize <= 9 ? 18 : 8
        case .normal:
            candidateLimit = boardSize <= 9 ? 28 : 12
        case .strong:
            candidateLimit = boardSize <= 9 ? 32 : 14
        }

        let candidates = monteCarloCandidatesFast(
            for: stoneCode(for: stone),
            from: root,
            maxCandidates: candidateLimit
        )
        guard !candidates.isEmpty else { return nil }

        let baseSimulationsPerMove = boardSize <= 9 ? 36 : 14
        let baseRolloutDepth = boardSize <= 9 ? 120 : 180
        let boardBudgetScale: Double = boardSize <= 9 ? 1.0 : 0.68
        let boardDepthScale: Double = boardSize <= 9 ? 1.0 : 0.72
        let simulationsPerMove: Int
        let rolloutDepth: Int
        let tacticalWeight: Double
        let runTacticalLookahead: Bool
        switch aiStrength {
        case .fast:
            simulationsPerMove = max(4, Int(Double(baseSimulationsPerMove / 2) * boardBudgetScale))
            rolloutDepth = max(48, Int(Double(baseRolloutDepth / 2) * boardDepthScale))
            tacticalWeight = 0
            runTacticalLookahead = false
        case .normal:
            simulationsPerMove = max(8, Int(Double(baseSimulationsPerMove) * boardBudgetScale))
            rolloutDepth = max(90, Int(Double(baseRolloutDepth) * boardDepthScale))
            tacticalWeight = tacticalModeEnabled ? 0.7 : 0.5
            runTacticalLookahead = true
        case .strong:
            simulationsPerMove = max(12, Int(Double(baseSimulationsPerMove * 2) * boardBudgetScale))
            rolloutDepth = max(120, Int(Double(baseRolloutDepth + (boardSize <= 9 ? 80 : 120)) * boardDepthScale))
            tacticalWeight = tacticalModeEnabled ? 0.85 : 0.7
            runTacticalLookahead = true
        }
        let hardMoveTimeCapSeconds: TimeInterval
        switch aiStrength {
        case .fast:
            hardMoveTimeCapSeconds = boardSize <= 9 ? 5.0 : 7.0
        case .normal:
            hardMoveTimeCapSeconds = boardSize <= 9 ? 10.0 : 14.0
        case .strong:
            hardMoveTimeCapSeconds = boardSize <= 9 ? 15.0 : 20.0
        }
        let moveDeadline = ProcessInfo.processInfo.systemUptime + hardMoveTimeCapSeconds

        var best: (moveIndex: Int, score: Double)?
        var bestCandidate: FastCandidateMove?
        let cpuCores = max(1, ProcessInfo.processInfo.activeProcessorCount)

        var shouldRunTacticalByIndex = Array(repeating: false, count: candidates.count)
        if runTacticalLookahead {
            let tacticalBaseBudget: Int
            switch aiStrength {
            case .fast:
                tacticalBaseBudget = 0
            case .normal:
                tacticalBaseBudget = tacticalModeEnabled ? 8 : 5
            case .strong:
                tacticalBaseBudget = tacticalModeEnabled ? 12 : 8
            }

            if tacticalBaseBudget > 0 {
                let sortedIndices = candidates.indices.sorted {
                    if candidates[$0].policyPrior == candidates[$1].policyPrior {
                        return candidates[$0].immediateScore > candidates[$1].immediateScore
                    }
                    return candidates[$0].policyPrior > candidates[$1].policyPrior
                }
                let tacticalCap = min(candidates.count, tacticalBaseBudget + 5)
                var selected = 0

                for idx in sortedIndices where selected < tacticalBaseBudget {
                    shouldRunTacticalByIndex[idx] = true
                    selected += 1
                }

                if tacticalCap > selected {
                    for idx in sortedIndices where selected < tacticalCap {
                        let candidate = candidates[idx]
                        // Always include forcing candidates that can swing local fights.
                        if candidate.capturesGained > 0 || !candidate.selfFillNoTactics {
                            shouldRunTacticalByIndex[idx] = true
                            selected += 1
                        }
                    }
                }
            }
        }

        let optimisticPlayoutCeiling = Double(boardSize * boardSize) + whiteKomi + 20.0
        let optimisticTacticalCeiling = 90.0
        let pruneCheckInterval = 4
        let minRolloutsBeforePrune = 8
        let baseTotalBudget = max(candidates.count, simulationsPerMove * candidates.count)
        let strategyOverheadScale = showStrategyEnabled ? 0.86 : 1.0
        let totalSimulationBudget = max(candidates.count, Int(Double(baseTotalBudget) * strategyOverheadScale))
        let mctsBatchSize: Int
        let rolloutPreviewInterval: Int
        switch aiStrength {
        case .fast:
            mctsBatchSize = 2
            rolloutPreviewInterval = showStrategyEnabled ? 12 : 8
        case .normal:
            mctsBatchSize = 3
            rolloutPreviewInterval = showStrategyEnabled ? 10 : 6
        case .strong:
            mctsBatchSize = 4
            rolloutPreviewInterval = showStrategyEnabled ? 8 : 4
        }
        let livePreviewScoreDelta = 2.8
        let mctsExplorationConstant: Double = tacticalModeEnabled ? 1.15 : 1.05
        let confidenceIntervalScale: Double = tacticalModeEnabled ? 1.55 : 1.45
        let minSamplesForConfidenceStop = max(36, totalSimulationBudget / 4)
        let requiredConfidenceLead: Double = boardSize <= 9 ? 0.65 : 0.95
        let shouldParallelizeRolloutBatches =
            aiStrength != .fast &&
            cpuCores >= 4 &&
            candidates.count >= 4

        func shouldPublishInterimCandidate(
            interimCombined: Double,
            bestScore: Double?
        ) -> Bool {
            guard let bestScore else { return true }
            return interimCombined >= (bestScore - livePreviewScoreDelta)
        }

        struct RootMCTSChild {
            let candidate: FastCandidateMove
            let candidateIndex: Int
            let fixedTerm: Double
            let runTactical: Bool
            let tacticalUrgency: Int
            let volatility: Int
            var visits: Int = 0
            var totalPlayout: Double = 0
            var tacticalLookahead: Double = 0
            var tacticalComputed: Bool = false
        }

        let rolloutCache = threadLocalRolloutCache()
        let rootOpponentThreat = maxImmediateCaptureFast(
            for: stoneCode(for: stone.opposite),
            in: root,
            sampleLimit: boardSize <= 9 ? 24 : 16,
            cache: rolloutCache
        )

        var children: [RootMCTSChild] = candidates.enumerated().map { idx, candidate in
            let candidateOpponentThreat = maxImmediateCaptureFast(
                for: stoneCode(for: stone.opposite),
                in: candidate.stateAfterMove,
                sampleLimit: boardSize <= 9 ? 20 : 14,
                cache: rolloutCache
            )
            let defensiveGain = max(0, rootOpponentThreat - candidateOpponentThreat)
            let tacticalUrgency =
                (candidate.capturesGained * 2) +
                (defensiveGain * 2) +
                ((defensiveGain > 0 && candidate.capturesGained == 0) ? 1 : 0)
            let urgencyBonus =
                (Double(candidate.capturesGained) * 2.4) +
                (Double(defensiveGain) * 2.0) +
                ((defensiveGain > 0 && candidate.capturesGained == 0) ? 1.25 : 0)
            let fixedTerm =
                (Double(candidate.immediateScore) * 0.028) +
                (Double(candidate.capturesGained) * 1.15) +
                (candidate.policyPrior * 6.5) +
                urgencyBonus
            let volatility =
                (candidate.capturesGained * 3) +
                (defensiveGain * 2) +
                (candidate.selfFillNoTactics ? 0 : 1) +
                (candidate.immediateScore > 300 ? 1 : 0)
            return RootMCTSChild(
                candidate: candidate,
                candidateIndex: idx,
                fixedTerm: fixedTerm,
                runTactical: shouldRunTacticalByIndex[idx],
                tacticalUrgency: tacticalUrgency,
                volatility: volatility
            )
        }

        let tacticalPriorityLimit: Int
        switch aiStrength {
        case .fast:
            tacticalPriorityLimit = 0
        case .normal:
            tacticalPriorityLimit = boardSize <= 9 ? 4 : 3
        case .strong:
            tacticalPriorityLimit = boardSize <= 9 ? 6 : 5
        }
        let tacticalPriorityIndices: Set<Int> = {
            guard tacticalPriorityLimit > 0 else { return [] }
            let sorted = children.indices.sorted {
                let lhs = children[$0].candidate
                let rhs = children[$1].candidate
                if lhs.policyPrior == rhs.policyPrior {
                    return lhs.immediateScore > rhs.immediateScore
                }
                return lhs.policyPrior > rhs.policyPrior
            }
            var selected = Set(sorted.prefix(tacticalPriorityLimit).map { children[$0].candidateIndex })
            // Always include urgent tactical lines (captures/defenses) for lookahead.
            for child in children where child.tacticalUrgency > 0 {
                selected.insert(child.candidateIndex)
            }
            return selected
        }()
        let minVisitsBeforeAnyTactical = max(16, totalSimulationBudget / 7)
        let tacticalScoreWindow = tacticalModeEnabled ? 2.1 : 1.25
        let tacticalVisitRankLimit = tacticalModeEnabled ? 3 : 2

        var totalVisits = 0
        let evalCache = threadLocalEvalCache()

        func meanPlayout(_ child: RootMCTSChild) -> Double {
            guard child.visits > 0 else { return 0 }
            return child.totalPlayout / Double(child.visits)
        }

        func combinedScore(_ child: RootMCTSChild) -> Double {
            meanPlayout(child) + child.fixedTerm + (child.tacticalLookahead * tacticalWeight)
        }

        func upperConfidenceBound(_ child: RootMCTSChild, total: Int) -> Double {
            let priorBoost = child.candidate.policyPrior * 0.7
            if child.visits == 0 {
                return child.fixedTerm + priorBoost + mctsExplorationConstant * 2.2
            }
            let explore =
                mctsExplorationConstant *
                (0.8 + child.candidate.policyPrior) *
                sqrt(log(Double(max(total, 1)) + 1.0) / Double(child.visits))
            return meanPlayout(child) + child.fixedTerm + (child.tacticalLookahead * tacticalWeight) + explore + priorBoost
        }

        func optimisticCombined(_ child: RootMCTSChild, remainingBudget: Int) -> Double {
            let optimisticAverage =
                (child.totalPlayout + (Double(remainingBudget) * optimisticPlayoutCeiling)) /
                Double(max(1, child.visits + remainingBudget))
            let optimisticTactical = child.runTactical ? (optimisticTacticalCeiling * tacticalWeight) : 0
            return optimisticAverage + child.fixedTerm + optimisticTactical
        }

        func maybeComputeTactical(for index: Int) {
            guard children[index].runTactical else { return }
            guard !children[index].tacticalComputed else { return }
            guard tacticalPriorityIndices.contains(children[index].candidateIndex) else { return }
            guard totalVisits >= minVisitsBeforeAnyTactical else { return }
            // Selective tactical lookahead: only fire for top/volatile lines and sufficiently sampled children.
            let visitThreshold = tacticalModeEnabled ? 5 : 7
            if children[index].volatility <= 0 && children[index].visits < visitThreshold * 2 {
                return
            }
            guard children[index].visits >= visitThreshold else { return }
            let childCombined = combinedScore(children[index])
            let bestCombined = best?.score ?? childCombined
            guard childCombined >= (bestCombined - tacticalScoreWindow) else { return }
            let betterVisitCount = children.indices.reduce(into: 0) { total, idx in
                if children[idx].visits > children[index].visits {
                    total += 1
                }
            }
            guard betterVisitCount < tacticalVisitRankLimit else { return }
            let tactical = tacticalReplySwingFast(
                for: children[index].candidate,
                perspective: stoneCode(for: stone),
                cache: evalCache
            )
            children[index].tacticalLookahead = tactical
            children[index].tacticalComputed = true
        }

        func updateBestFromChildren() {
            guard let bestIndex = children.indices.max(by: { combinedScore(children[$0]) < combinedScore(children[$1]) }) else {
                return
            }
            let score = combinedScore(children[bestIndex])
            best = (children[bestIndex].candidate.index, score)
            bestCandidate = children[bestIndex].candidate
        }

        var playoutsUsed = 0
        while playoutsUsed < totalSimulationBudget {
            if ProcessInfo.processInfo.systemUptime >= moveDeadline {
                break
            }
            let selectedIndex = children.indices.max {
                upperConfidenceBound(children[$0], total: max(1, totalVisits + 1)) <
                upperConfidenceBound(children[$1], total: max(1, totalVisits + 1))
            } ?? 0

            let remainingBudget = totalSimulationBudget - playoutsUsed
            let childRemaining = max(0, simulationsPerMove - children[selectedIndex].visits)
            let batch = max(1, min(mctsBatchSize, min(remainingBudget, childRemaining == 0 ? mctsBatchSize : childRemaining)))

            let batchScore: Double
            if shouldParallelizeRolloutBatches && batch >= 2 {
                let workerCount = min(cpuCores, batch)
                var subtotals = Array(repeating: 0.0, count: workerCount)
                DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                    var subtotal = 0.0
                    var i = worker
                    while i < batch {
                        subtotal += runRandomPlayoutFast(
                            from: children[selectedIndex].candidate.stateAfterMove,
                            perspective: stone,
                            maxSteps: rolloutDepth
                        )
                        i += workerCount
                    }
                    subtotals[worker] = subtotal
                }
                batchScore = subtotals.reduce(0, +)
            } else {
                batchScore = runRandomPlayoutBatchFast(
                    from: children[selectedIndex].candidate.stateAfterMove,
                    perspective: stone,
                    maxSteps: rolloutDepth,
                    playoutCount: batch
                )
            }

            children[selectedIndex].visits += batch
            children[selectedIndex].totalPlayout += batchScore
            playoutsUsed += batch
            totalVisits += batch

            if ProcessInfo.processInfo.systemUptime >= moveDeadline {
                updateBestFromChildren()
                break
            }

            maybeComputeTactical(for: selectedIndex)
            updateBestFromChildren()

            if showStrategyEnabled,
               let bestMoveIndex = best?.moveIndex,
               (children[selectedIndex].visits == batch ||
                children[selectedIndex].visits % rolloutPreviewInterval == 0) {
                let interim = combinedScore(children[selectedIndex])
                if shouldPublishInterimCandidate(interimCombined: interim, bestScore: best?.score) {
                    publishContemplatedMoveFast(
                        currentMove: children[selectedIndex].candidate,
                        bestMoveIndex: bestMoveIndex,
                        stone: stone,
                        token: searchToken,
                        includePreviewLine: false
                    )
                }
            }

            if children[selectedIndex].visits >= minRolloutsBeforePrune &&
               children[selectedIndex].visits % pruneCheckInterval == 0,
               let bestScore = best?.score {
                let optimistic = optimisticCombined(children[selectedIndex], remainingBudget: remainingBudget)
                if optimistic < bestScore - 0.1 {
                    continue
                }
            }

            // Confidence-gap early stop: if best line is statistically clear, end search early.
            if totalVisits >= minSamplesForConfidenceStop,
               children.count > 1,
               let bestIdx = children.indices.max(by: { combinedScore(children[$0]) < combinedScore(children[$1]) }) {
                var secondIdx: Int?
                for idx in children.indices where idx != bestIdx {
                    if secondIdx == nil || combinedScore(children[idx]) > combinedScore(children[secondIdx!]) {
                        secondIdx = idx
                    }
                }
                if let secondIdx,
                   children[bestIdx].visits >= 8,
                   children[secondIdx].visits >= 8 {
                    let totalLog = log(Double(totalVisits) + 1.0)
                    let bestRadius =
                        confidenceIntervalScale *
                        sqrt(totalLog / Double(max(1, children[bestIdx].visits)))
                    let secondRadius =
                        confidenceIntervalScale *
                        sqrt(totalLog / Double(max(1, children[secondIdx].visits)))
                    let bestLower = combinedScore(children[bestIdx]) - bestRadius
                    let secondUpper = combinedScore(children[secondIdx]) + secondRadius
                    if bestLower - secondUpper > requiredConfidenceLead {
                        break
                    }
                }
            }
        }

        if let bestMoveIndex = best?.moveIndex,
           let currentBest = bestCandidate {
            publishContemplatedMoveFast(
                currentMove: currentBest,
                bestMoveIndex: bestMoveIndex,
                stone: stone,
                token: searchToken
            )
        }

        if let bestCandidate,
           shouldPreferPassOverBestCandidateFast(
               bestCandidate,
               root: root,
               perspective: stoneCode(for: stone),
               cache: threadLocalEvalCache()
           ) {
            return nil
        }

        guard let bestMoveIndex = best?.moveIndex else { return nil }
        return (bestMoveIndex / boardSize, bestMoveIndex % boardSize)
    }

    private func monteCarloCandidatesFast(
        for stone: UInt8,
        from root: FastSimState,
        maxCandidates: Int? = nil
    ) -> [FastCandidateMove] {
        var prelim: [(index: Int, immediateScore: Int, capturesGained: Int, selfFillNoTactics: Bool, stateAfterMove: FastSimState, policyRaw: Double)] = []
        let ownersBeforeMove = emptyRegionOwnersFast(in: root.board)
        let endgameLikely = isLikelyEndgameFast(state: root)
        let openingLikely = isLikelyOpeningFast(state: root)
        let afterFirstPass = root.consecutivePasses > 0
        let cache = threadLocalRolloutCache()
        let koRecapturePending = hasKoRecaptureOpportunityFast(
            for: stone,
            in: root,
            cache: cache
        )
        let candidateIndices = openingLikely
            ? openingExpansionIndicesFast(in: root.board, for: stone)
            : preferredEmptyIndicesFast(in: root.board)

        for index in candidateIndices {
            var simulated = root
            guard applyFastSimMove(at: index, to: &simulated) else { continue }

            let immediate = immediateHeuristicFast(
                from: root,
                to: simulated,
                moveIndex: index,
                stone: stone,
                ownerBeforeMove: ownersBeforeMove[index],
                endgameLikely: endgameLikely,
                openingLikely: openingLikely,
                afterFirstPass: afterFirstPass,
                koRecapturePending: koRecapturePending,
                cache: cache
            )
            let capturesGained: Int
            if stone == 1 {
                capturesGained = simulated.capturesBlack - root.capturesBlack
            } else {
                capturesGained = simulated.capturesWhite - root.capturesWhite
            }

            // Hard filter: avoid eye-filling/self-filling dead-end moves with no tactical purpose.
            if capturesGained == 0 && immediate.selfFillNoTactics && immediate.score <= -2000 {
                continue
            }

            let policyRaw = policyPriorRawFast(
                moveIndex: index,
                root: root,
                immediateScore: immediate.score,
                capturesGained: capturesGained,
                selfFillNoTactics: immediate.selfFillNoTactics,
                openingLikely: openingLikely,
                endgameLikely: endgameLikely,
                orderRank: prelim.count,
                orderCount: candidateIndices.count
            )
            prelim.append(
                (
                    index: index,
                    immediateScore: immediate.score,
                    capturesGained: capturesGained,
                    selfFillNoTactics: immediate.selfFillNoTactics,
                    stateAfterMove: simulated,
                    policyRaw: policyRaw
                )
            )
        }

        let priors = normalizedPolicyPriors(from: prelim.map { $0.policyRaw })
        var scored: [FastCandidateMove] = []
        scored.reserveCapacity(prelim.count)
        for (idx, item) in prelim.enumerated() {
            scored.append(
                FastCandidateMove(
                    index: item.index,
                    immediateScore: item.immediateScore,
                    policyPrior: priors[idx],
                    capturesGained: item.capturesGained,
                    selfFillNoTactics: item.selfFillNoTactics,
                    stateAfterMove: item.stateAfterMove
                )
            )
        }

        scored.sort {
            if $0.policyPrior == $1.policyPrior {
                return $0.immediateScore > $1.immediateScore
            }
            return $0.policyPrior > $1.policyPrior
        }
        let resolvedMaxCandidates = maxCandidates ?? (boardSize <= 9 ? 28 : 16)
        guard scored.count > resolvedMaxCandidates else { return scored }

        let headCount = resolvedMaxCandidates / 2
        var chosen = Array(scored.prefix(headCount))
        var tailPool = Array(scored.dropFirst(headCount))
        while chosen.count < resolvedMaxCandidates, !tailPool.isEmpty {
            let priorMass = tailPool.reduce(0.0) { total, candidate in
                total + max(1e-6, candidate.policyPrior)
            }
            let pickIndex: Int
            if priorMass > 0 {
                var threshold = Double.random(in: 0..<priorMass)
                var selected = tailPool.count - 1
                for (i, candidate) in tailPool.enumerated() {
                    threshold -= max(1e-6, candidate.policyPrior)
                    if threshold <= 0 {
                        selected = i
                        break
                    }
                }
                pickIndex = selected
            } else {
                pickIndex = Int.random(in: 0..<tailPool.count)
            }
            chosen.append(tailPool.remove(at: pickIndex))
        }
        return chosen
    }

    private func immediateHeuristicFast(
        from root: FastSimState,
        to next: FastSimState,
        moveIndex: Int,
        stone: UInt8,
        ownerBeforeMove: UInt8,
        endgameLikely: Bool,
        openingLikely: Bool,
        afterFirstPass: Bool,
        koRecapturePending: Bool,
        cache: RolloutThreadCache
    ) -> ImmediateHeuristicResult {
        let capturesGained: Int
        if stone == 1 {
            capturesGained = next.capturesBlack - root.capturesBlack
        } else {
            capturesGained = next.capturesWhite - root.capturesWhite
        }

        let ownLiberties = fastGroupLiberties(at: moveIndex, in: next.board, cache: cache)
        let ownAtariBefore = adjacentAtariGroupsFast(of: stone, around: moveIndex, in: root.board, cache: cache)
        let enemyAtariAfter = adjacentAtariGroupsFast(
            of: stone == 1 ? 2 : 1,
            around: moveIndex,
            in: next.board,
            cache: cache
        )
        let opponentCaptureThreat = maxImmediateCaptureFast(
            for: stone == 1 ? 2 : 1,
            in: next,
            sampleLimit: boardSize <= 9 ? 30 : 18,
            cache: cache
        )
        let row = moveIndex / boardSize
        let col = moveIndex % boardSize
        let localEdgeDist = min(min(row, boardSize - 1 - row), min(col, boardSize - 1 - col))
        let center = Double(boardSize - 1) / 2.0
        let distanceFromCenter = abs(Double(row) - center) + abs(Double(col) - center)
        let centerBonus = Int((Double(boardSize) - distanceFromCenter).rounded())
        let shapeBonus = ownLiberties >= 4 ? 8 : 0

        if ownLiberties <= 1 && capturesGained == 0 {
            return ImmediateHeuristicResult(score: -1200, selfFillNoTactics: false)
        }

        let adjacentEnemyBefore = neighborIndexTable[moveIndex].reduce(into: 0) { total, n in
            if root.board[n] == (stone == 1 ? 2 : 1) { total += 1 }
        }
        let adjacentOwnBefore = neighborIndexTable[moveIndex].reduce(into: 0) { total, n in
            if root.board[n] == stone { total += 1 }
        }
        let adjacentEmptyBefore = neighborIndexTable[moveIndex].reduce(into: 0) { total, n in
            if root.board[n] == 0 { total += 1 }
        }
        let occupiedAdjacentBefore = adjacentEnemyBefore + adjacentOwnBefore

        let ownLibertyPenalty = ownLiberties == 2 ? -22 : 0
        let ownEyeFillNoTactics =
            capturesGained == 0 &&
            enemyAtariAfter == 0 &&
            ownAtariBefore == 0 &&
            isOwnEyeFast(at: moveIndex, stone: stone, in: root.board)
        if ownEyeFillNoTactics {
            return ImmediateHeuristicResult(score: -2200, selfFillNoTactics: true)
        }
        let selfFillNoTactics =
            ownerBeforeMove == stone &&
            capturesGained == 0 &&
            enemyAtariAfter == 0 &&
            ownAtariBefore == 0
        if selfFillNoTactics && endgameLikely && afterFirstPass {
            return ImmediateHeuristicResult(score: -2600, selfFillNoTactics: true)
        }
        let ownTerritoryFillPenalty = selfFillNoTactics
            ? (afterFirstPass && endgameLikely ? 1800 : (endgameLikely ? 920 : 260))
            : 0
        let captureCompletionBonus = capturesGained > 0 ? (160 + capturesGained * 55) : 0
        let openingContactPenalty =
            (openingLikely && capturesGained == 0 && adjacentEnemyBefore > adjacentOwnBefore)
            ? (adjacentEnemyBefore - adjacentOwnBefore) * 95
            : 0
        let openingExpansionBonus = openingLikely
            ? ((occupiedAdjacentBefore == 0 ? 160 : 0) + max(0, 2 - occupiedAdjacentBefore) * 30)
            : 0
        let openingEdgePenalty: Int
        if openingLikely && capturesGained == 0 && adjacentEnemyBefore == 0 {
            if localEdgeDist == 0 {
                openingEdgePenalty = 420
            } else if localEdgeDist == 1 {
                openingEdgePenalty = 190
            } else {
                openingEdgePenalty = 0
            }
        } else {
            openingEdgePenalty = 0
        }
        let openingSelfFillPenalty =
             (openingLikely &&
             capturesGained == 0 &&
             adjacentEnemyBefore == 0 &&
             adjacentOwnBefore >= 2 &&
             adjacentEmptyBefore <= 1 &&
             enemyAtariAfter == 0)
            ? 320
            : 0
        let tacticalReadingBonus = localTacticalReadingBonusFast(
            from: root,
            to: next,
            moveIndex: moveIndex,
            stone: stone,
            capturesGained: capturesGained,
            ownLibertiesAfterMove: ownLiberties,
            enemyAtariAfter: enemyAtariAfter,
            adjacentEnemyBefore: adjacentEnemyBefore,
            cache: cache
        )
        let deadShapePenalty = deadShapeRiskPenaltyFast(
            moveIndex: moveIndex,
            stone: stone,
            in: next.board,
            capturesGained: capturesGained,
            enemyAtariAfter: enemyAtariAfter,
            cache: cache
        )
        let koCaptureLikely = isLikelyKoCaptureFast(
            from: root,
            to: next,
            moveIndex: moveIndex,
            stone: stone,
            capturesGained: capturesGained,
            ownLibertiesAfterMove: ownLiberties,
            cache: cache
        )
        let ownKoThreat = koThreatValueFast(for: stone, in: root, cache: cache)
        let oppKoThreat = koThreatValueFast(for: stone == 1 ? 2 : 1, in: root, cache: cache)
        let koThreatDeficit = max(0, oppKoThreat - ownKoThreat)
        let koTakePenalty = koCaptureLikely ? (120 + (koThreatDeficit * 45)) : 0
        let koTakeBonus = koCaptureLikely ? max(0, (ownKoThreat - oppKoThreat) * 16) : 0
        let koThreatMove = isLikelyKoThreatMove(capturesGained: capturesGained, enemyAtariAfter: enemyAtariAfter)
        let koIgnorePenalty = (koRecapturePending && !koThreatMove) ? 210 : 0
        let koThreatBonus = (koRecapturePending && koThreatMove) ? 55 : 0

        let score =
            capturesGained * 220 +
            captureCompletionBonus +
            openingExpansionBonus +
            ownAtariBefore * 85 +
            enemyAtariAfter * 28 +
            ownLiberties * 6 +
            centerBonus +
            shapeBonus +
            ownLibertyPenalty -
            openingContactPenalty -
            openingEdgePenalty -
            openingSelfFillPenalty -
            ownTerritoryFillPenalty +
            koTakeBonus +
            koThreatBonus +
            tacticalReadingBonus -
            koTakePenalty -
            koIgnorePenalty -
            deadShapePenalty -
            (opponentCaptureThreat * 130) +
            Int.random(in: 0...2)

        return ImmediateHeuristicResult(score: score, selfFillNoTactics: selfFillNoTactics)
    }

    private func monteCarloCandidates(
        for stone: Stone,
        from root: SimState,
        maxCandidates: Int? = nil
    ) -> [CandidateMove] {
        var prelim: [(row: Int, col: Int, immediateScore: Int, capturesGained: Int, selfFillNoTactics: Bool, stateAfterMove: SimState, policyRaw: Double)] = []
        let ownersBeforeMove = emptyRegionOwners(in: root.board)
        let endgameLikely = isLikelyEndgame(state: root)
        let openingLikely = isLikelyOpening(state: root)
        let afterFirstPass = root.consecutivePasses > 0
        let koRecapturePending = hasKoRecaptureOpportunity(for: stone, in: root)
        let candidatePoints = openingLikely
            ? openingExpansionPoints(in: root.board, for: stone)
            : preferredEmptyPoints(in: root.board)

        for point in candidatePoints {
            guard let simulated = simulateMove(row: point.row, col: point.col, state: root) else {
                continue
            }

            let immediate = immediateHeuristic(
                from: root,
                to: simulated,
                move: point,
                for: stone,
                ownerBeforeMove: ownersBeforeMove[point.row][point.col],
                endgameLikely: endgameLikely,
                openingLikely: openingLikely,
                afterFirstPass: afterFirstPass,
                koRecapturePending: koRecapturePending
            )
            let capturesGained: Int
            if stone == .black {
                capturesGained = simulated.capturesBlack - root.capturesBlack
            } else {
                capturesGained = simulated.capturesWhite - root.capturesWhite
            }
            let policyRaw = policyPriorRaw(
                move: point,
                root: root,
                immediateScore: immediate.score,
                capturesGained: capturesGained,
                selfFillNoTactics: immediate.selfFillNoTactics,
                openingLikely: openingLikely,
                endgameLikely: endgameLikely,
                orderRank: prelim.count,
                orderCount: candidatePoints.count
            )
            prelim.append(
                (
                    row: point.row,
                    col: point.col,
                    immediateScore: immediate.score,
                    capturesGained: capturesGained,
                    selfFillNoTactics: immediate.selfFillNoTactics,
                    stateAfterMove: simulated,
                    policyRaw: policyRaw
                )
            )
        }

        let priors = normalizedPolicyPriors(from: prelim.map { $0.policyRaw })
        var scored: [CandidateMove] = []
        scored.reserveCapacity(prelim.count)
        for (idx, item) in prelim.enumerated() {
            scored.append(
                CandidateMove(
                    row: item.row,
                    col: item.col,
                    immediateScore: item.immediateScore,
                    policyPrior: priors[idx],
                    capturesGained: item.capturesGained,
                    selfFillNoTactics: item.selfFillNoTactics,
                    stateAfterMove: item.stateAfterMove
                )
            )
        }

        scored.sort {
            if $0.policyPrior == $1.policyPrior {
                return $0.immediateScore > $1.immediateScore
            }
            return $0.policyPrior > $1.policyPrior
        }

        let resolvedMaxCandidates = maxCandidates ?? (boardSize <= 9 ? 28 : 16)
        guard scored.count > resolvedMaxCandidates else { return scored }

        let headCount = resolvedMaxCandidates / 2
        var chosen = Array(scored.prefix(headCount))
        var tailPool = Array(scored.dropFirst(headCount))

        while chosen.count < resolvedMaxCandidates, !tailPool.isEmpty {
            let priorMass = tailPool.reduce(0.0) { total, candidate in
                total + max(1e-6, candidate.policyPrior)
            }
            let pickIndex: Int
            if priorMass > 0 {
                var threshold = Double.random(in: 0..<priorMass)
                var selected = tailPool.count - 1
                for (i, candidate) in tailPool.enumerated() {
                    threshold -= max(1e-6, candidate.policyPrior)
                    if threshold <= 0 {
                        selected = i
                        break
                    }
                }
                pickIndex = selected
            } else {
                pickIndex = Int.random(in: 0..<tailPool.count)
            }
            chosen.append(tailPool.remove(at: pickIndex))
        }

        return chosen
    }

    private func normalizedPolicyPriors(from rawScores: [Double]) -> [Double] {
        guard !rawScores.isEmpty else { return [] }
        let maxRaw = rawScores.max() ?? 0
        let temperature = 1.35
        var weights: [Double] = []
        weights.reserveCapacity(rawScores.count)
        var total = 0.0
        for raw in rawScores {
            let weight = Foundation.exp((raw - maxRaw) / temperature)
            weights.append(weight)
            total += weight
        }
        guard total > 0 else {
            let uniform = 1.0 / Double(rawScores.count)
            return Array(repeating: uniform, count: rawScores.count)
        }
        return weights.map { $0 / total }
    }

    private func policyPriorRawFast(
        moveIndex: Int,
        root: FastSimState,
        immediateScore: Int,
        capturesGained: Int,
        selfFillNoTactics: Bool,
        openingLikely: Bool,
        endgameLikely: Bool,
        orderRank: Int,
        orderCount: Int
    ) -> Double {
        let row = moveIndex / boardSize
        let col = moveIndex % boardSize
        let edgeDist = min(min(row, boardSize - 1 - row), min(col, boardSize - 1 - col))
        let preferredLine = boardSize <= 9 ? 2 : 3
        let adjacentEnemy = neighborIndexTable[moveIndex].reduce(into: 0) { total, n in
            if root.board[n] == (root.currentPlayer == 1 ? 2 : 1) { total += 1 }
        }
        let adjacentOwn = neighborIndexTable[moveIndex].reduce(into: 0) { total, n in
            if root.board[n] == root.currentPlayer { total += 1 }
        }
        let orderedBias = orderCount > 1
            ? (1.0 - (Double(orderRank) / Double(orderCount - 1)))
            : 1.0

        var raw =
            (Double(immediateScore) * 0.018) +
            (Double(capturesGained) * 2.8) +
            (orderedBias * (openingLikely ? 1.5 : 0.9))

        if selfFillNoTactics { raw -= 4.2 }
        if openingLikely {
            raw += Double(max(0, 4 - abs(edgeDist - preferredLine))) * 0.45
            if adjacentEnemy > adjacentOwn && capturesGained == 0 { raw -= 0.95 }
            if adjacentEnemy == 0 { raw += 0.35 }
        }
        if endgameLikely && selfFillNoTactics { raw -= 2.2 }
        return raw
    }

    private func policyPriorRaw(
        move: Point,
        root: SimState,
        immediateScore: Int,
        capturesGained: Int,
        selfFillNoTactics: Bool,
        openingLikely: Bool,
        endgameLikely: Bool,
        orderRank: Int,
        orderCount: Int
    ) -> Double {
        let edgeDist = min(min(move.row, boardSize - 1 - move.row), min(move.col, boardSize - 1 - move.col))
        let preferredLine = boardSize <= 9 ? 2 : 3
        let adjacentEnemy = neighbors(of: move).reduce(into: 0) { total, n in
            if root.board[n.row][n.col] == root.currentPlayer.opposite { total += 1 }
        }
        let adjacentOwn = neighbors(of: move).reduce(into: 0) { total, n in
            if root.board[n.row][n.col] == root.currentPlayer { total += 1 }
        }
        let orderedBias = orderCount > 1
            ? (1.0 - (Double(orderRank) / Double(orderCount - 1)))
            : 1.0

        var raw =
            (Double(immediateScore) * 0.018) +
            (Double(capturesGained) * 2.8) +
            (orderedBias * (openingLikely ? 1.5 : 0.9))

        if selfFillNoTactics { raw -= 4.2 }
        if openingLikely {
            raw += Double(max(0, 4 - abs(edgeDist - preferredLine))) * 0.45
            if adjacentEnemy > adjacentOwn && capturesGained == 0 { raw -= 0.95 }
            if adjacentEnemy == 0 { raw += 0.35 }
        }
        if endgameLikely && selfFillNoTactics { raw -= 2.2 }
        return raw
    }

    private func preferredEmptyPoints(in position: [[Stone]]) -> [Point] {
        var nearStones: [Point] = []
        var allEmpty: [Point] = []

        for row in 0..<boardSize {
            for col in 0..<boardSize where position[row][col] == .empty {
                let p = Point(row: row, col: col)
                allEmpty.append(p)

                let touchesStone = neighbors(of: p).contains { n in
                    position[n.row][n.col] != .empty
                }
                if touchesStone {
                    nearStones.append(p)
                }
            }
        }

        if nearStones.count < max(8, boardSize) {
            return allEmpty
        }

        return nearStones
    }

    private func immediateHeuristic(
        from root: SimState,
        to next: SimState,
        move: Point,
        for stone: Stone,
        ownerBeforeMove: Stone?,
        endgameLikely: Bool,
        openingLikely: Bool,
        afterFirstPass: Bool,
        koRecapturePending: Bool
    ) -> ImmediateHeuristicResult {
        let capturesGained: Int
        if stone == .black {
            capturesGained = next.capturesBlack - root.capturesBlack
        } else {
            capturesGained = next.capturesWhite - root.capturesWhite
        }

        let ownLiberties = liberties(ofGroupAt: move.row, col: move.col, in: next.board).count
        let ownAtariBefore = adjacentAtariGroups(of: stone, around: move, in: root.board)
        let enemyAtariAfter = adjacentAtariGroups(of: stone.opposite, around: move, in: next.board)
        let opponentCaptureThreat = maxImmediateCapture(
            for: stone.opposite,
            in: next,
            sampleLimit: boardSize <= 9 ? 30 : 18
        )
        let adjacentEnemyBefore = neighbors(of: move).reduce(into: 0) { total, n in
            if root.board[n.row][n.col] == stone.opposite { total += 1 }
        }
        let adjacentOwnBefore = neighbors(of: move).reduce(into: 0) { total, n in
            if root.board[n.row][n.col] == stone { total += 1 }
        }
        let adjacentEmptyBefore = neighbors(of: move).reduce(into: 0) { total, n in
            if root.board[n.row][n.col] == .empty { total += 1 }
        }
        let occupiedAdjacentBefore = adjacentEnemyBefore + adjacentOwnBefore
        let localEdgeDist = min(
            min(move.row, boardSize - 1 - move.row),
            min(move.col, boardSize - 1 - move.col)
        )
        let center = Double(boardSize - 1) / 2.0
        let distanceFromCenter = abs(Double(move.row) - center) + abs(Double(move.col) - center)
        let centerBonus = Int((Double(boardSize) - distanceFromCenter).rounded())
        let shapeBonus = ownLiberties >= 4 ? 8 : 0

        // Strongly avoid self-atari unless it captures something meaningful.
        if ownLiberties <= 1 && capturesGained == 0 {
            return ImmediateHeuristicResult(score: -1200, selfFillNoTactics: false)
        }

        let ownLibertyPenalty = ownLiberties == 2 ? -22 : 0
        let ownEyeFillNoTactics =
            capturesGained == 0 &&
            enemyAtariAfter == 0 &&
            ownAtariBefore == 0 &&
            isOwnEye(at: move, stone: stone, in: root.board)
        if ownEyeFillNoTactics {
            return ImmediateHeuristicResult(score: -2200, selfFillNoTactics: true)
        }
        let selfFillNoTactics =
            ownerBeforeMove == stone &&
            capturesGained == 0 &&
            enemyAtariAfter == 0 &&
            ownAtariBefore == 0
        if selfFillNoTactics && endgameLikely && afterFirstPass {
            return ImmediateHeuristicResult(score: -2600, selfFillNoTactics: true)
        }
        let ownTerritoryFillPenalty = selfFillNoTactics
            ? (afterFirstPass && endgameLikely ? 1800 : (endgameLikely ? 920 : 260))
            : 0
        let captureCompletionBonus = capturesGained > 0 ? (160 + capturesGained * 55) : 0
        let openingContactPenalty =
            (openingLikely && capturesGained == 0 && adjacentEnemyBefore > adjacentOwnBefore)
            ? (adjacentEnemyBefore - adjacentOwnBefore) * 95
            : 0
        let openingExpansionBonus = openingLikely
            ? ((occupiedAdjacentBefore == 0 ? 160 : 0) + max(0, 2 - occupiedAdjacentBefore) * 30)
            : 0
        let openingEdgePenalty: Int
        if openingLikely && capturesGained == 0 && adjacentEnemyBefore == 0 {
            if localEdgeDist == 0 {
                openingEdgePenalty = 420
            } else if localEdgeDist == 1 {
                openingEdgePenalty = 190
            } else {
                openingEdgePenalty = 0
            }
        } else {
            openingEdgePenalty = 0
        }
        let openingSelfFillPenalty =
            (openingLikely &&
             capturesGained == 0 &&
             adjacentEnemyBefore == 0 &&
             adjacentOwnBefore >= 2 &&
             adjacentEmptyBefore <= 1 &&
             enemyAtariAfter == 0)
            ? 320
            : 0
        let deadShapePenalty = deadShapeRiskPenalty(
            move: move,
            stone: stone,
            in: next.board,
            capturesGained: capturesGained,
            enemyAtariAfter: enemyAtariAfter
        )
        let koCaptureLikely = isLikelyKoCapture(
            from: root,
            to: next,
            move: move,
            for: stone,
            capturesGained: capturesGained,
            ownLibertiesAfterMove: ownLiberties
        )
        let ownKoThreat = koThreatValue(for: stone, in: root)
        let oppKoThreat = koThreatValue(for: stone.opposite, in: root)
        let koThreatDeficit = max(0, oppKoThreat - ownKoThreat)
        let koTakePenalty = koCaptureLikely ? (120 + (koThreatDeficit * 45)) : 0
        let koTakeBonus = koCaptureLikely ? max(0, (ownKoThreat - oppKoThreat) * 16) : 0
        let koThreatMove = isLikelyKoThreatMove(capturesGained: capturesGained, enemyAtariAfter: enemyAtariAfter)
        let koIgnorePenalty = (koRecapturePending && !koThreatMove) ? 210 : 0
        let koThreatBonus = (koRecapturePending && koThreatMove) ? 55 : 0

        let score =
            capturesGained * 220 +
            captureCompletionBonus +
            openingExpansionBonus +
            ownAtariBefore * 85 +
            enemyAtariAfter * 28 +
            ownLiberties * 6 +
            centerBonus +
            shapeBonus +
            ownLibertyPenalty -
            openingContactPenalty -
            openingEdgePenalty -
            openingSelfFillPenalty -
            koTakePenalty -
            koIgnorePenalty -
            deadShapePenalty +
            koTakeBonus +
            koThreatBonus -
            ownTerritoryFillPenalty -
            (opponentCaptureThreat * 130) +
            Int.random(in: 0...2)
        return ImmediateHeuristicResult(score: score, selfFillNoTactics: selfFillNoTactics)
    }

    private func isLikelyKoThreatMove(capturesGained: Int, enemyAtariAfter: Int) -> Bool {
        capturesGained > 0 || enemyAtariAfter > 0
    }

    private func koThreatValue(for stone: Stone, in state: SimState) -> Int {
        let immediateCapture = maxImmediateCapture(
            for: stone,
            in: state,
            sampleLimit: boardSize <= 9 ? 24 : 14
        )
        let atariPressure = countGroupsInAtari(for: stone.opposite, in: state.board)
        return (immediateCapture * 3) + atariPressure
    }

    private func koThreatValueFast(for stone: UInt8, in state: FastSimState, cache: RolloutThreadCache) -> Int {
        let immediateCapture = maxImmediateCaptureFast(
            for: stone,
            in: state,
            sampleLimit: boardSize <= 9 ? 24 : 14,
            cache: cache
        )
        let atariPressure = countGroupsInAtariFast(for: stone == 1 ? 2 : 1, in: state.board)
        return (immediateCapture * 3) + atariPressure
    }

    private func hasKoRecaptureOpportunity(for stone: Stone, in state: SimState) -> Bool {
        var probe = state
        probe.currentPlayer = stone

        let points = preferredEmptyPoints(in: probe.board)
        if points.isEmpty { return false }

        let maxChecks = boardSize <= 9 ? 48 : 30
        for point in points.prefix(maxChecks) {
            var blocked = probe
            if applySimMove(row: point.row, col: point.col, to: &blocked) {
                continue
            }

            var koIgnored = probe
            koIgnored.koForbiddenHash = nil
            let beforeCaptures = stone == .black ? koIgnored.capturesBlack : koIgnored.capturesWhite
            guard applySimMove(row: point.row, col: point.col, to: &koIgnored) else { continue }
            let capturesGained = stone == .black
                ? (koIgnored.capturesBlack - beforeCaptures)
                : (koIgnored.capturesWhite - beforeCaptures)
            let ownLiberties = liberties(ofGroupAt: point.row, col: point.col, in: koIgnored.board).count
            if isLikelyKoCapture(
                from: probe,
                to: koIgnored,
                move: point,
                for: stone,
                capturesGained: capturesGained,
                ownLibertiesAfterMove: ownLiberties
            ) {
                return true
            }
        }

        return false
    }

    private func hasKoRecaptureOpportunityFast(
        for stone: UInt8,
        in state: FastSimState,
        cache: RolloutThreadCache
    ) -> Bool {
        var probe = state
        probe.currentPlayer = stone

        let probeHash = probe.currentBoardHash ?? hash(forFastBoard: probe.board)
        let points = preferredEmptyIndicesFast(in: probe.board, boardHash: probeHash, cache: cache)
        if points.isEmpty { return false }

        let maxChecks = boardSize <= 9 ? 48 : 30
        for pointIndex in points.prefix(maxChecks) {
            var blocked = probe
            if applyFastSimMove(at: pointIndex, to: &blocked, cache: cache) {
                continue
            }

            var koIgnored = probe
            koIgnored.koForbiddenHash = nil
            let beforeCaptures = stone == 1 ? koIgnored.capturesBlack : koIgnored.capturesWhite
            guard applyFastSimMove(at: pointIndex, to: &koIgnored, cache: cache) else { continue }
            let capturesGained = stone == 1
                ? (koIgnored.capturesBlack - beforeCaptures)
                : (koIgnored.capturesWhite - beforeCaptures)
            let ownLiberties = fastGroupLiberties(at: pointIndex, in: koIgnored.board, cache: cache)
            if isLikelyKoCaptureFast(
                from: probe,
                to: koIgnored,
                moveIndex: pointIndex,
                stone: stone,
                capturesGained: capturesGained,
                ownLibertiesAfterMove: ownLiberties,
                cache: cache
            ) {
                return true
            }
        }

        return false
    }

    private func isLikelyKoCapture(
        from root: SimState,
        to next: SimState,
        move: Point,
        for stone: Stone,
        capturesGained: Int,
        ownLibertiesAfterMove: Int
    ) -> Bool {
        guard capturesGained == 1, ownLibertiesAfterMove == 1 else { return false }

        var capturedPoint: Point?
        for r in 0..<boardSize {
            for c in 0..<boardSize where root.board[r][c] == stone.opposite && next.board[r][c] == .empty {
                if capturedPoint != nil { return false }
                capturedPoint = Point(row: r, col: c)
            }
        }
        guard let capturedPoint else { return false }

        var recaptureProbe = next
        recaptureProbe.currentPlayer = stone.opposite
        recaptureProbe.koForbiddenHash = nil
        let beforeCaptures = stone.opposite == .black ? recaptureProbe.capturesBlack : recaptureProbe.capturesWhite
        guard applySimMove(row: capturedPoint.row, col: capturedPoint.col, to: &recaptureProbe) else {
            return false
        }
        let recaptureGain = stone.opposite == .black
            ? (recaptureProbe.capturesBlack - beforeCaptures)
            : (recaptureProbe.capturesWhite - beforeCaptures)
        return recaptureGain == 1
    }

    private func isLikelyKoCaptureFast(
        from root: FastSimState,
        to next: FastSimState,
        moveIndex: Int,
        stone: UInt8,
        capturesGained: Int,
        ownLibertiesAfterMove: Int,
        cache: RolloutThreadCache
    ) -> Bool {
        guard capturesGained == 1, ownLibertiesAfterMove == 1 else { return false }

        let opponent: UInt8 = stone == 1 ? 2 : 1
        var capturedPoint: Int?
        for index in root.board.indices where root.board[index] == opponent && next.board[index] == 0 {
            if capturedPoint != nil { return false }
            capturedPoint = index
        }
        guard let capturedPoint else { return false }

        var recaptureProbe = next
        recaptureProbe.currentPlayer = opponent
        recaptureProbe.koForbiddenHash = nil
        let beforeCaptures = opponent == 1 ? recaptureProbe.capturesBlack : recaptureProbe.capturesWhite
        guard applyFastSimMove(at: capturedPoint, to: &recaptureProbe, cache: cache) else { return false }
        let recaptureGain = opponent == 1
            ? (recaptureProbe.capturesBlack - beforeCaptures)
            : (recaptureProbe.capturesWhite - beforeCaptures)
        return recaptureGain == 1
    }

    private func tacticalReplySwing(
        for candidate: CandidateMove,
        perspective: Stone,
        cache: SearchEvalCache
    ) -> Double {
        let baseline = staticBoardScore(for: perspective, in: candidate.stateAfterMove, cache: cache)
        let opponent = perspective.opposite
        let replies = monteCarloCandidates(for: opponent, from: candidate.stateAfterMove)

        guard !replies.isEmpty else { return 22.0 }

        let replyLimit = tacticalModeEnabled ? min(9, replies.count) : min(5, replies.count)
        var worst = Double.greatestFiniteMagnitude

        for reply in replies.prefix(replyLimit) {
            let replyScore = staticBoardScore(for: perspective, in: reply.stateAfterMove, cache: cache)
            let effectiveScore: Double

            if tacticalModeEnabled {
                let counterScore = bestLocalCounterScore(
                    for: perspective,
                    in: reply.stateAfterMove,
                    sampleLimit: boardSize <= 9 ? 10 : 7,
                    cache: cache
                )
                effectiveScore = max(replyScore, counterScore)
            } else {
                effectiveScore = replyScore
            }

            if effectiveScore < worst {
                worst = effectiveScore
            }
        }

        return worst - baseline
    }

    private func staticBoardScore(for perspective: Stone, in state: SimState, cache: SearchEvalCache) -> Double {
        let key = StaticEvalKey(
            boardFingerprint: boardFingerprint(for: state.board),
            capturesBlack: state.capturesBlack,
            capturesWhite: state.capturesWhite,
            perspective: perspective
        )
        if let cached = cache.value(for: key) {
            return cached
        }

        let (blackTerritory, whiteTerritory) = territory(on: state.board)
        let blackScore = Double(blackTerritory + state.capturesBlack)
        let whiteScore = Double(whiteTerritory + state.capturesWhite) + whiteKomi
        let balance = perspective == .black ? (blackScore - whiteScore) : (whiteScore - blackScore)

        let ownAtari = countGroupsInAtari(for: perspective, in: state.board)
        let oppAtari = countGroupsInAtari(for: perspective.opposite, in: state.board)
        let safetyDelta = Double((oppAtari * 9) - (ownAtari * 14))
        let score = balance + safetyDelta
        cache.store(score, for: key)
        return score
    }

    private func tacticalReplySwingFast(
        for candidate: FastCandidateMove,
        perspective: UInt8,
        cache: SearchEvalCache
    ) -> Double {
        let baseline = staticBoardScoreFast(for: perspective, in: candidate.stateAfterMove, cache: cache)
        let opponent: UInt8 = perspective == 1 ? 2 : 1
        let replies = monteCarloCandidatesFast(for: opponent, from: candidate.stateAfterMove)
        guard !replies.isEmpty else { return 22.0 }

        let replyLimit = tacticalModeEnabled ? min(9, replies.count) : min(5, replies.count)
        var worst = Double.greatestFiniteMagnitude
        for reply in replies.prefix(replyLimit) {
            let replyScore = staticBoardScoreFast(for: perspective, in: reply.stateAfterMove, cache: cache)
            let effectiveScore: Double
            if tacticalModeEnabled {
                let rolloutCache = threadLocalRolloutCache()
                let counterScore = bestLocalCounterScoreFast(
                    for: perspective,
                    in: reply.stateAfterMove,
                    sampleLimit: boardSize <= 9 ? 10 : 7,
                    cache: cache,
                    rolloutCache: rolloutCache
                )
                effectiveScore = max(replyScore, counterScore)
            } else {
                effectiveScore = replyScore
            }
            if effectiveScore < worst {
                worst = effectiveScore
            }
        }
        return worst - baseline
    }

    private func staticBoardScoreFast(
        for perspective: UInt8,
        in state: FastSimState,
        cache: SearchEvalCache
    ) -> Double {
        let perspectiveStone = perspective == 1 ? Stone.black : Stone.white
        let key = StaticEvalKey(
            boardFingerprint: Int(truncatingIfNeeded: state.currentBoardHash ?? hash(forFastBoard: state.board)),
            capturesBlack: state.capturesBlack,
            capturesWhite: state.capturesWhite,
            perspective: perspectiveStone
        )
        if let cached = cache.value(for: key) {
            return cached
        }

        let (blackTerritory, whiteTerritory) = territory(onFastBoard: state.board)
        let blackScore = Double(blackTerritory + state.capturesBlack)
        let whiteScore = Double(whiteTerritory + state.capturesWhite) + whiteKomi
        let balance = perspective == 1 ? (blackScore - whiteScore) : (whiteScore - blackScore)

        let ownAtari = countGroupsInAtariFast(for: perspective, in: state.board)
        let oppAtari = countGroupsInAtariFast(for: perspective == 1 ? 2 : 1, in: state.board)
        let safetyDelta = Double((oppAtari * 9) - (ownAtari * 14))
        let score = balance + safetyDelta
        cache.store(score, for: key)
        return score
    }

    private func maxImmediateCapture(for stone: Stone, in state: SimState, sampleLimit: Int) -> Int {
        var probe = state
        probe.currentPlayer = stone

        let points = preferredEmptyPoints(in: probe.board)
        if points.isEmpty { return 0 }

        var best = 0
        for point in points.prefix(sampleLimit) {
            guard let next = simulateMove(row: point.row, col: point.col, state: probe) else { continue }
            let gained: Int
            if stone == .black {
                gained = next.capturesBlack - probe.capturesBlack
            } else {
                gained = next.capturesWhite - probe.capturesWhite
            }
            if gained > best {
                best = gained
            }
        }
        return best
    }

    private func bestLocalCounterScore(
        for stone: Stone,
        in state: SimState,
        sampleLimit: Int,
        cache: SearchEvalCache
    ) -> Double {
        guard state.currentPlayer == stone else {
            return staticBoardScore(for: stone, in: state, cache: cache)
        }

        let points = preferredEmptyPoints(in: state.board)
        if points.isEmpty {
            return staticBoardScore(for: stone, in: state, cache: cache)
        }

        var best = -Double.greatestFiniteMagnitude
        var found = false

        for point in points.prefix(sampleLimit) {
            guard let next = simulateMove(row: point.row, col: point.col, state: state) else { continue }
            let score = staticBoardScore(for: stone, in: next, cache: cache)
            if score > best {
                best = score
            }
            found = true
        }

        if found {
            return best
        }
        return staticBoardScore(for: stone, in: state, cache: cache)
    }

    private func maxImmediateCaptureFast(
        for stone: UInt8,
        in state: FastSimState,
        sampleLimit: Int,
        cache: RolloutThreadCache
    ) -> Int {
        var probe = state
        probe.currentPlayer = stone

        let probeHash = probe.currentBoardHash ?? hash(forFastBoard: probe.board)
        let points = preferredEmptyIndicesFast(in: probe.board, boardHash: probeHash, cache: cache)
        if points.isEmpty { return 0 }

        var best = 0
        for point in points.prefix(sampleLimit) {
            var next = probe
            guard applyFastSimMove(at: point, to: &next, cache: cache) else { continue }
            let gained: Int
            if stone == 1 {
                gained = next.capturesBlack - probe.capturesBlack
            } else {
                gained = next.capturesWhite - probe.capturesWhite
            }
            if gained > best {
                best = gained
            }
        }
        return best
    }

    private func collectGroupInfoFast(
        at index: Int,
        in board: [UInt8],
        cache: RolloutThreadCache
    ) -> TacticalGroupInfoFast? {
        guard index >= 0, index < board.count else { return nil }
        let stone = board[index]
        guard stone != 0 else { return nil }
        cache.ensureCapacity(board.count)

        let visitMark = cache.nextMark()
        let libertyMark = cache.nextMark()
        var stack: [Int] = [index]
        var group: [Int] = []
        var liberties: [Int] = []

        while let point = stack.popLast() {
            if cache.visitMarks[point] == visitMark { continue }
            cache.visitMarks[point] = visitMark
            guard board[point] == stone else { continue }
            group.append(point)

            for neighbor in neighborIndexTable[point] {
                let value = board[neighbor]
                if value == stone {
                    if cache.visitMarks[neighbor] != visitMark {
                        stack.append(neighbor)
                    }
                } else if value == 0 {
                    if cache.libertyMarks[neighbor] != libertyMark {
                        cache.libertyMarks[neighbor] = libertyMark
                        liberties.append(neighbor)
                    }
                }
            }
        }

        guard !group.isEmpty else { return nil }
        let representative = group.min() ?? index
        return TacticalGroupInfoFast(
            representative: representative,
            size: group.count,
            liberties: liberties
        )
    }

    private func adjacentOpponentGroupsFast(
        around index: Int,
        attacker: UInt8,
        in board: [UInt8],
        cache: RolloutThreadCache
    ) -> [TacticalGroupInfoFast] {
        let opponent: UInt8 = attacker == 1 ? 2 : 1
        var seen: Set<Int> = []
        var groups: [TacticalGroupInfoFast] = []

        for neighbor in neighborIndexTable[index] where board[neighbor] == opponent {
            guard let info = collectGroupInfoFast(at: neighbor, in: board, cache: cache) else { continue }
            if seen.insert(info.representative).inserted {
                groups.append(info)
            }
        }
        return groups
    }

    private func canForceCaptureGroupFast(
        attacker: UInt8,
        targetRepresentative: Int,
        in state: FastSimState,
        depthRemaining: Int,
        defenderToMove: Bool,
        cache: RolloutThreadCache
    ) -> Bool {
        let defender: UInt8 = attacker == 1 ? 2 : 1
        guard depthRemaining > 0 else { return false }

        guard let target = collectGroupInfoFast(at: targetRepresentative, in: state.board, cache: cache) else {
            return true
        }
        // Group merged into attacker-colored stones means it was captured.
        if state.board[target.representative] != defender {
            return true
        }

        let legalResponses = target.liberties
        if legalResponses.isEmpty { return true }

        if defenderToMove {
            // Defender survives if any legal defense breaks the forcing sequence.
            for liberty in legalResponses {
                var defended = state
                defended.currentPlayer = defender
                guard applyFastSimMove(at: liberty, to: &defended, cache: cache) else { continue }
                if !canForceCaptureGroupFast(
                    attacker: attacker,
                    targetRepresentative: targetRepresentative,
                    in: defended,
                    depthRemaining: depthRemaining - 1,
                    defenderToMove: false,
                    cache: cache
                ) {
                    return false
                }
            }
            return true
        } else {
            // Attacker needs at least one continuation that keeps the capture forced.
            for liberty in legalResponses {
                var attack = state
                attack.currentPlayer = attacker
                guard applyFastSimMove(at: liberty, to: &attack, cache: cache) else { continue }
                if canForceCaptureGroupFast(
                    attacker: attacker,
                    targetRepresentative: targetRepresentative,
                    in: attack,
                    depthRemaining: depthRemaining - 1,
                    defenderToMove: true,
                    cache: cache
                ) {
                    return true
                }
            }
            return false
        }
    }

    private func localTacticalReadingBonusFast(
        from root: FastSimState,
        to next: FastSimState,
        moveIndex: Int,
        stone: UInt8,
        capturesGained: Int,
        ownLibertiesAfterMove: Int,
        enemyAtariAfter: Int,
        adjacentEnemyBefore: Int,
        cache: RolloutThreadCache
    ) -> Int {
        if captureReadingStrength == .off {
            return 0
        }

        let opponent: UInt8 = stone == 1 ? 2 : 1
        var bonus = 0
        let readingMultiplier: Double
        let readDepth: Int
        switch captureReadingStrength {
        case .off:
            return 0
        case .normal:
            readingMultiplier = 1.0
            readDepth = tacticalModeEnabled ? 8 : 6
        case .deep:
            readingMultiplier = tacticalModeEnabled ? 1.35 : 1.2
            readDepth = tacticalModeEnabled ? 11 : 9
        }

        // Atari-chain / ladder-net style local reading on adjacent opponent groups.
        let groups = adjacentOpponentGroupsFast(
            around: moveIndex,
            attacker: stone,
            in: next.board,
            cache: cache
        )
        for group in groups {
            if group.liberties.count == 1 {
                let scaled = Int(Double(55 + (group.size * 14)) * readingMultiplier)
                bonus += min(380, scaled)
            } else if group.liberties.count == 2 {
                let forced = canForceCaptureGroupFast(
                    attacker: stone,
                    targetRepresentative: group.representative,
                    in: next,
                    depthRemaining: readDepth,
                    defenderToMove: true,
                    cache: cache
                )
                if forced {
                    let scaled = Int(Double(85 + (group.size * 20)) * readingMultiplier)
                    bonus += min(460, scaled)
                }
            }
        }

        // Throw-in style: low-liberty insertion that creates local forcing pressure.
        if capturesGained == 0 &&
            ownLibertiesAfterMove <= 2 &&
            enemyAtariAfter > 0 &&
            adjacentEnemyBefore >= 2 {
            bonus += 70
        }

        // Snapback-like safety: penalize fragile capture if immediate recapture is severe.
        if capturesGained > 0 {
            var opponentReply = next
            opponentReply.currentPlayer = opponent
            if applyFastSimMove(at: moveIndex, to: &opponentReply, cache: cache) {
                let oppGain: Int
                if opponent == 1 {
                    oppGain = opponentReply.capturesBlack - next.capturesBlack
                } else {
                    oppGain = opponentReply.capturesWhite - next.capturesWhite
                }

                if oppGain > capturesGained {
                    var counter = opponentReply
                    counter.currentPlayer = stone
                    let counterUpside = maxImmediateCaptureFast(
                        for: stone,
                        in: counter,
                        sampleLimit: boardSize <= 9 ? 12 : 8,
                        cache: cache
                    )
                    if counterUpside >= oppGain + 1 {
                        bonus += Int(55.0 * readingMultiplier)
                    } else {
                        let scaled = Int(Double(45 + ((oppGain - capturesGained) * 40)) * readingMultiplier)
                        bonus -= min(300, scaled)
                    }
                }
            }
        }

        // Reward direct capture completion and punish missed urgent defense.
        if enemyAtariAfter >= 2 { bonus += 45 }
        if capturesGained == 0 && ownLibertiesAfterMove == 1 { bonus -= 120 }
        if capturesGained > 0 && ownLibertiesAfterMove == 1 { bonus -= 40 }
        _ = root // keeps signature explicit for future root-relative tactical extensions.
        return bonus
    }

    private func isOwnEyeFast(at index: Int, stone: UInt8, in board: [UInt8]) -> Bool {
        guard index >= 0, index < board.count else { return false }
        guard board[index] == 0 else { return false }

        for neighbor in neighborIndexTable[index] where board[neighbor] != stone {
            return false
        }

        let row = index / boardSize
        let col = index % boardSize
        let diagonals = [
            (row - 1, col - 1),
            (row - 1, col + 1),
            (row + 1, col - 1),
            (row + 1, col + 1)
        ]
        var enemyDiagonals = 0
        var inBoundsDiagonals = 0
        let opponent: UInt8 = stone == 1 ? 2 : 1

        for (r, c) in diagonals where r >= 0 && r < boardSize && c >= 0 && c < boardSize {
            inBoundsDiagonals += 1
            if board[(r * boardSize) + c] == opponent {
                enemyDiagonals += 1
            }
        }

        // Strict but fast true-eye heuristic.
        if inBoundsDiagonals <= 2 {
            return enemyDiagonals == 0
        }
        return enemyDiagonals <= 1
    }

    private func deadShapeRiskPenaltyFast(
        moveIndex: Int,
        stone: UInt8,
        in board: [UInt8],
        capturesGained: Int,
        enemyAtariAfter: Int,
        cache: RolloutThreadCache
    ) -> Int {
        if capturesGained > 0 || enemyAtariAfter > 0 { return 0 }
        guard let group = collectGroupInfoFast(at: moveIndex, in: board, cache: cache) else { return 0 }
        let liberties = group.liberties.count
        if liberties >= 3 { return 0 }

        let eyePotential = group.liberties.reduce(into: 0) { total, liberty in
            if isOwnEyeFast(at: liberty, stone: stone, in: board) { total += 1 }
        }

        if liberties <= 1 && eyePotential == 0 { return 900 }
        if liberties == 2 && eyePotential == 0 { return 360 }
        if liberties == 2 && eyePotential == 1 { return 140 }
        return 0
    }

    private func bestLocalCounterScoreFast(
        for stone: UInt8,
        in state: FastSimState,
        sampleLimit: Int,
        cache: SearchEvalCache,
        rolloutCache: RolloutThreadCache
    ) -> Double {
        guard state.currentPlayer == stone else {
            return staticBoardScoreFast(for: stone, in: state, cache: cache)
        }

        let stateHash = state.currentBoardHash ?? hash(forFastBoard: state.board)
        let points = preferredEmptyIndicesFast(in: state.board, boardHash: stateHash, cache: rolloutCache)
        if points.isEmpty {
            return staticBoardScoreFast(for: stone, in: state, cache: cache)
        }

        var best = -Double.greatestFiniteMagnitude
        var found = false
        for point in points.prefix(sampleLimit) {
            var next = state
            guard applyFastSimMove(at: point, to: &next, cache: rolloutCache) else { continue }
            let score = staticBoardScoreFast(for: stone, in: next, cache: cache)
            if score > best {
                best = score
            }
            found = true
        }
        if found {
            return best
        }
        return staticBoardScoreFast(for: stone, in: state, cache: cache)
    }

    private func countGroupsInAtariFast(for stone: UInt8, in board: [UInt8]) -> Int {
        let cache = threadLocalRolloutCache()
        cache.ensureCapacity(board.count)
        let visitedMark = cache.nextMark()
        var total = 0

        for index in board.indices where board[index] == stone {
            if cache.tempMarks[index] == visitedMark { continue }
            let analysis = fastGroupAnalysis(at: index, in: board, cache: cache, collectGroup: true)
            for point in cache.groupBuffer.prefix(analysis.groupCount) {
                cache.tempMarks[point] = visitedMark
            }
            if analysis.liberties == 1 {
                total += analysis.groupCount
            }
        }

        return total
    }

    private func adjacentAtariGroups(of stone: Stone, around point: Point, in position: [[Stone]]) -> Int {
        var counted = Set<Point>()
        var total = 0

        for neighbor in neighbors(of: point) where position[neighbor.row][neighbor.col] == stone {
            if counted.contains(neighbor) { continue }

            var visited = Set<Point>()
            let group = groupAt(row: neighbor.row, col: neighbor.col, in: position, visited: &visited)
            for p in group {
                counted.insert(p)
            }
            var liberties = Set<Point>()
            for p in group {
                for n in neighbors(of: p) where position[n.row][n.col] == .empty {
                    liberties.insert(n)
                }
            }
            if liberties.count == 1 {
                total += group.count
            }
        }

        return total
    }

    private func countGroupsInAtari(for stone: Stone, in position: [[Stone]]) -> Int {
        var visited = Set<Point>()
        var total = 0

        for row in 0..<boardSize {
            for col in 0..<boardSize where position[row][col] == stone {
                let start = Point(row: row, col: col)
                if visited.contains(start) { continue }

                let group = groupAt(row: row, col: col, in: position, visited: &visited)
                var liberties = Set<Point>()
                for p in group {
                    for n in neighbors(of: p) where position[n.row][n.col] == .empty {
                        liberties.insert(n)
                    }
                }
                if liberties.count == 1 {
                    total += group.count
                }
            }
        }

        return total
    }

    private func runRandomPlayout(from state: SimState, perspective: Stone, maxSteps: Int) -> Double {
        runRandomPlayoutFast(from: makeFastState(from: state), perspective: perspective, maxSteps: maxSteps)
    }

    private func runRandomPlayoutFast(from state: FastSimState, perspective: Stone, maxSteps: Int) -> Double {
        runRandomPlayoutFast(
            from: state,
            perspective: perspective,
            maxSteps: maxSteps,
            rolloutCache: threadLocalRolloutCache()
        )
    }

    private func runRandomPlayoutFast(
        from state: FastSimState,
        perspective: Stone,
        maxSteps: Int,
        rolloutCache: RolloutThreadCache
    ) -> Double {
        var sim = state
        var steps = 0

        while steps < maxSteps, sim.consecutivePasses < 2 {
            if let moveIndex = randomLegalMoveFast(in: sim, cache: rolloutCache) {
                _ = applyFastSimMove(at: moveIndex, to: &sim, cache: rolloutCache)
            } else {
                applyFastPass(to: &sim)
            }
            steps += 1
        }

        let (blackTerritory, whiteTerritory) = territory(onFastBoard: sim.board)
        let blackScore = Double(blackTerritory + sim.capturesBlack)
        let whiteScore = Double(whiteTerritory + sim.capturesWhite) + whiteKomi

        if perspective == .black {
            return blackScore - whiteScore
        }
        return whiteScore - blackScore
    }

    private func runRandomPlayoutBatchFast(
        from state: FastSimState,
        perspective: Stone,
        maxSteps: Int,
        playoutCount: Int
    ) -> Double {
        guard playoutCount > 0 else { return 0 }
        let rolloutCache = threadLocalRolloutCache()
        var total = 0.0
        for _ in 0..<playoutCount {
            total += runRandomPlayoutFast(
                from: state,
                perspective: perspective,
                maxSteps: maxSteps,
                rolloutCache: rolloutCache
            )
        }
        return total
    }

    private func randomLegalMove(in state: SimState) -> Point? {
        let openingLikely = isLikelyOpening(state: state)
        let points = openingLikely
            ? openingExpansionPoints(in: state.board, for: state.currentPlayer)
            : preferredEmptyPoints(in: state.board)
        if points.isEmpty { return nil }

        var topPool: [(point: Point, score: Int)] = []
        let scanLimit = min(points.count, boardSize <= 9 ? 80 : 52)
        let poolLimit = 8
        let endgameLikely = isLikelyEndgame(state: state)
        let afterFirstPass = state.consecutivePasses > 0
        let ownersBeforeMove = emptyRegionOwners(in: state.board)
        let koRecapturePending = hasKoRecaptureOpportunity(for: state.currentPlayer, in: state)

        for point in points.prefix(scanLimit) {
            guard let next = simulateMove(row: point.row, col: point.col, state: state) else { continue }

            let mover = state.currentPlayer
            let capturesGained: Int
            if mover == .black {
                capturesGained = next.capturesBlack - state.capturesBlack
            } else {
                capturesGained = next.capturesWhite - state.capturesWhite
            }

            let ownLiberties = liberties(ofGroupAt: point.row, col: point.col, in: next.board).count
            let enemyAtariAfter = adjacentAtariGroups(of: mover.opposite, around: point, in: next.board)
            let ownerBeforeMove = ownersBeforeMove[point.row][point.col]
            let ownAtariBefore = adjacentAtariGroups(of: mover, around: point, in: state.board)
            let adjacentEnemyBefore = neighbors(of: point).reduce(into: 0) { total, n in
                if state.board[n.row][n.col] == mover.opposite { total += 1 }
            }
            let adjacentOwnBefore = neighbors(of: point).reduce(into: 0) { total, n in
                if state.board[n.row][n.col] == mover { total += 1 }
            }
            let occupiedAdjacentBefore = adjacentEnemyBefore + adjacentOwnBefore
            let selfAtariPenalty = (ownLiberties <= 1 && capturesGained == 0) ? 500 : 0
            let thinPenalty = ownLiberties == 2 ? 14 : 0
            let ownEyeFillNoTactics =
                capturesGained == 0 &&
                enemyAtariAfter == 0 &&
                ownAtariBefore == 0 &&
                isOwnEye(at: point, stone: mover, in: state.board)
            let ownEyeFillPenalty = ownEyeFillNoTactics ? 900 : 0
            let selfFillNoTactics =
                ownerBeforeMove == mover &&
                capturesGained == 0 &&
                enemyAtariAfter == 0 &&
                ownAtariBefore == 0
            let ownTerritoryFillPenalty = selfFillNoTactics
                ? (afterFirstPass && endgameLikely ? 1400 : (endgameLikely ? 760 : 230))
                : 0
            let captureCompletionBonus = capturesGained > 0 ? (90 + capturesGained * 35) : 0
            let koCaptureLikely = isLikelyKoCapture(
                from: state,
                to: next,
                move: point,
                for: mover,
                capturesGained: capturesGained,
                ownLibertiesAfterMove: ownLiberties
            )
            let ownKoThreat = koThreatValue(for: mover, in: state)
            let oppKoThreat = koThreatValue(for: mover.opposite, in: state)
            let koThreatDeficit = max(0, oppKoThreat - ownKoThreat)
            let koTakePenalty = koCaptureLikely ? (95 + (koThreatDeficit * 34)) : 0
            let koTakeBonus = koCaptureLikely ? max(0, (ownKoThreat - oppKoThreat) * 12) : 0
            let koThreatMove = isLikelyKoThreatMove(capturesGained: capturesGained, enemyAtariAfter: enemyAtariAfter)
            let koIgnorePenalty = (koRecapturePending && !koThreatMove) ? 165 : 0
            let koThreatBonus = (koRecapturePending && koThreatMove) ? 40 : 0
            let openingContactPenalty =
                (openingLikely && capturesGained == 0 && adjacentEnemyBefore > adjacentOwnBefore)
                ? (adjacentEnemyBefore - adjacentOwnBefore) * 55
                : 0
            let openingExpansionBonus = openingLikely
                ? ((occupiedAdjacentBefore == 0 ? 72 : 0) + max(0, 2 - occupiedAdjacentBefore) * 16)
                : 0
            let score =
                capturesGained * 170 +
                captureCompletionBonus +
                openingExpansionBonus +
                koTakeBonus +
                koThreatBonus +
                ownLiberties * 5 -
                selfAtariPenalty -
                ownEyeFillPenalty -
                openingContactPenalty -
                ownTerritoryFillPenalty -
                koTakePenalty -
                koIgnorePenalty -
                thinPenalty +
                Int.random(in: 0...6)
            topPool.append((point, score))
            topPool.sort { $0.score > $1.score }
            if topPool.count > poolLimit {
                topPool.removeLast()
            }
        }

        guard !topPool.isEmpty else { return nil }
        let bestScore = topPool.first?.score ?? 0
        let weighted = topPool.map { max(1, $0.score - bestScore + 30) }
        let totalWeight = weighted.reduce(0, +)
        var roll = Int.random(in: 0..<totalWeight)

        for (index, entry) in topPool.enumerated() {
            roll -= weighted[index]
            if roll < 0 {
                return entry.point
            }
        }

        return topPool.first?.point
    }

    private func makeFastState(from state: SimState) -> FastSimState {
        FastSimState(
            board: flattenBoard(state.board),
            currentPlayer: stoneCode(for: state.currentPlayer),
            capturesBlack: state.capturesBlack,
            capturesWhite: state.capturesWhite,
            currentBoardHash: state.currentBoardHash,
            koForbiddenHash: state.koForbiddenHash,
            consecutivePasses: state.consecutivePasses
        )
    }

    private func threadLocalEvalCache() -> SearchEvalCache {
        let key = Self.evalCacheThreadKey
        let dict = Thread.current.threadDictionary
        if let existing = dict[key] as? SearchEvalCache {
            return existing
        }
        let created = SearchEvalCache()
        dict[key] = created
        return created
    }

    private func threadLocalRolloutCache() -> RolloutThreadCache {
        let key = Self.rolloutCacheThreadKey
        let dict = Thread.current.threadDictionary
        if let existing = dict[key] as? RolloutThreadCache {
            existing.trimIfNeeded()
            return existing
        }
        let created = RolloutThreadCache()
        dict[key] = created
        return created
    }

    private func flattenBoard(_ position: [[Stone]]) -> [UInt8] {
        var flat: [UInt8] = []
        flat.reserveCapacity(boardSize * boardSize)
        for row in position {
            for stone in row {
                flat.append(stoneCode(for: stone))
            }
        }
        return flat
    }

    private func stoneCode(for stone: Stone) -> UInt8 {
        switch stone {
        case .empty:
            return 0
        case .black:
            return 1
        case .white:
            return 2
        }
    }

    private func randomLegalMoveFast(in state: FastSimState, cache: RolloutThreadCache) -> Int? {
        let boardHash = state.currentBoardHash ?? hash(forFastBoard: state.board)
        let points = preferredEmptyIndicesFast(in: state.board, boardHash: boardHash, cache: cache)
        if points.isEmpty { return nil }

        var topPool: [(index: Int, score: Int)] = []
        let scanLimit = min(points.count, boardSize <= 9 ? 80 : 52)
        let poolLimit = 8
        let endgameLikely = isLikelyEndgameFast(state: state)
        let openingLikely = isLikelyOpeningFast(state: state)
        let afterFirstPass = state.consecutivePasses > 0
        let ownersBeforeMove = emptyRegionOwnersFast(in: state.board, boardHash: boardHash, cache: cache)
        let koRecapturePending = hasKoRecaptureOpportunityFast(
            for: state.currentPlayer,
            in: state,
            cache: cache
        )

        for pointIndex in points.prefix(scanLimit) {
            var next = state
            guard applyFastSimMove(at: pointIndex, to: &next, cache: cache) else { continue }

            let mover = state.currentPlayer
            let capturesGained: Int
            if mover == 1 {
                capturesGained = next.capturesBlack - state.capturesBlack
            } else {
                capturesGained = next.capturesWhite - state.capturesWhite
            }

            let ownLiberties = fastGroupLiberties(at: pointIndex, in: next.board, cache: cache)
            let enemyAtariAfter = adjacentAtariGroupsFast(
                of: mover == 1 ? 2 : 1,
                around: pointIndex,
                in: next.board,
                cache: cache
            )
            let ownerBeforeMove = ownersBeforeMove[pointIndex]
            let ownAtariBefore = adjacentAtariGroupsFast(
                of: mover,
                around: pointIndex,
                in: state.board,
                cache: cache
            )
            let row = pointIndex / boardSize
            let col = pointIndex % boardSize
            let localEdgeDist = min(min(row, boardSize - 1 - row), min(col, boardSize - 1 - col))
            let adjacentEnemyBefore = neighborIndexTable[pointIndex].reduce(into: 0) { total, n in
                if state.board[n] == (mover == 1 ? 2 : 1) { total += 1 }
            }
            let adjacentOwnBefore = neighborIndexTable[pointIndex].reduce(into: 0) { total, n in
                if state.board[n] == mover { total += 1 }
            }
            let adjacentEmptyBefore = neighborIndexTable[pointIndex].reduce(into: 0) { total, n in
                if state.board[n] == 0 { total += 1 }
            }
            let occupiedAdjacentBefore = adjacentEnemyBefore + adjacentOwnBefore
            let selfAtariPenalty = (ownLiberties <= 1 && capturesGained == 0) ? 500 : 0
            let thinPenalty = ownLiberties == 2 ? 14 : 0
            let ownEyeFillNoTactics =
                capturesGained == 0 &&
                enemyAtariAfter == 0 &&
                ownAtariBefore == 0 &&
                isOwnEyeFast(at: pointIndex, stone: mover, in: state.board)
            let ownEyeFillPenalty = ownEyeFillNoTactics ? 900 : 0
            let selfFillNoTactics =
                ownerBeforeMove == mover &&
                capturesGained == 0 &&
                enemyAtariAfter == 0 &&
                ownAtariBefore == 0
            let ownTerritoryFillPenalty = selfFillNoTactics
                ? (afterFirstPass && endgameLikely ? 1400 : (endgameLikely ? 760 : 230))
                : 0
            let captureCompletionBonus = capturesGained > 0 ? (90 + capturesGained * 35) : 0
            let koCaptureLikely = isLikelyKoCaptureFast(
                from: state,
                to: next,
                moveIndex: pointIndex,
                stone: mover,
                capturesGained: capturesGained,
                ownLibertiesAfterMove: ownLiberties,
                cache: cache
            )
            let ownKoThreat = koThreatValueFast(for: mover, in: state, cache: cache)
            let oppKoThreat = koThreatValueFast(for: mover == 1 ? 2 : 1, in: state, cache: cache)
            let koThreatDeficit = max(0, oppKoThreat - ownKoThreat)
            let koTakePenalty = koCaptureLikely ? (95 + (koThreatDeficit * 34)) : 0
            let koTakeBonus = koCaptureLikely ? max(0, (ownKoThreat - oppKoThreat) * 12) : 0
            let koThreatMove = isLikelyKoThreatMove(capturesGained: capturesGained, enemyAtariAfter: enemyAtariAfter)
            let koIgnorePenalty = (koRecapturePending && !koThreatMove) ? 165 : 0
            let koThreatBonus = (koRecapturePending && koThreatMove) ? 40 : 0
            let openingEdgePenalty: Int
            if openingLikely && capturesGained == 0 && adjacentEnemyBefore == 0 {
                if localEdgeDist == 0 {
                    openingEdgePenalty = 300
                } else if localEdgeDist == 1 {
                    openingEdgePenalty = 130
                } else {
                    openingEdgePenalty = 0
                }
            } else {
                openingEdgePenalty = 0
            }
            let openingExpansionBonus = openingLikely
                ? ((occupiedAdjacentBefore == 0 ? 70 : 0) + max(0, 2 - occupiedAdjacentBefore) * 16)
                : 0
            let openingSelfFillPenalty =
                (openingLikely &&
                 capturesGained == 0 &&
                 adjacentEnemyBefore == 0 &&
                 adjacentOwnBefore >= 2 &&
                 adjacentEmptyBefore <= 1 &&
                 enemyAtariAfter == 0)
                ? 220
                : 0
            let deadShapePenalty = deadShapeRiskPenaltyFast(
                moveIndex: pointIndex,
                stone: mover,
                in: next.board,
                capturesGained: capturesGained,
                enemyAtariAfter: enemyAtariAfter,
                cache: cache
            )
            let score =
                capturesGained * 170 +
                captureCompletionBonus +
                openingExpansionBonus +
                koTakeBonus +
                koThreatBonus +
                ownLiberties * 5 -
                selfAtariPenalty -
                ownEyeFillPenalty -
                openingEdgePenalty -
                openingSelfFillPenalty -
                deadShapePenalty -
                ownTerritoryFillPenalty -
                koTakePenalty -
                koIgnorePenalty -
                thinPenalty +
                Int.random(in: 0...6)
            topPool.append((pointIndex, score))
            topPool.sort { $0.score > $1.score }
            if topPool.count > poolLimit {
                topPool.removeLast()
            }
        }

        guard !topPool.isEmpty else { return nil }
        let bestScore = topPool.first?.score ?? 0
        let weighted = topPool.map { max(1, $0.score - bestScore + 30) }
        let totalWeight = weighted.reduce(0, +)
        var roll = Int.random(in: 0..<totalWeight)

        for (index, entry) in topPool.enumerated() {
            roll -= weighted[index]
            if roll < 0 {
                return entry.index
            }
        }

        return topPool.first?.index
    }

    private func preferredEmptyIndicesFast(in board: [UInt8]) -> [Int] {
        var nearStones: [Int] = []
        var allEmpty: [Int] = []

        for index in board.indices where board[index] == 0 {
            allEmpty.append(index)
            let touchesStone = neighborIndexTable[index].contains { board[$0] != 0 }
            if touchesStone {
                nearStones.append(index)
            }
        }

        if nearStones.count < max(8, boardSize) {
            return allEmpty
        }
        return nearStones
    }

    private func preferredEmptyIndicesFast(
        in board: [UInt8],
        boardHash: UInt64,
        cache: RolloutThreadCache
    ) -> [Int] {
        if let cached = cache.preferredEmptyByHash[boardHash] {
            return cached
        }
        let computed = preferredEmptyIndicesFast(in: board)
        cache.preferredEmptyByHash[boardHash] = computed
        return computed
    }

    private func isLikelyEndgameFast(state: FastSimState) -> Bool {
        let boardHash = state.currentBoardHash ?? hash(forFastBoard: state.board)
        let cache = threadLocalRolloutCache()
        if let cached = cache.endgameLikelyByHash[boardHash] {
            return state.consecutivePasses > 0 ? true : cached
        }
        let emptyCount = state.board.reduce(into: 0) { count, value in
            if value == 0 { count += 1 }
        }
        let totalPoints = boardSize * boardSize
        if state.consecutivePasses > 0 {
            return true
        }
        let computed = emptyCount <= max(10, totalPoints / 4)
        cache.endgameLikelyByHash[boardHash] = computed
        return computed
    }

    private func applyFastPass(to state: inout FastSimState) {
        state.consecutivePasses += 1
        state.currentPlayer = state.currentPlayer == 1 ? 2 : 1
    }

    private func applyFastSimMove(at index: Int, to state: inout FastSimState) -> Bool {
        applyFastSimMove(at: index, to: &state, cache: threadLocalRolloutCache())
    }

    private func applyFastSimMove(at index: Int, to state: inout FastSimState, cache: RolloutThreadCache) -> Bool {
        guard index >= 0, index < state.board.count else { return false }
        guard state.board[index] == 0 else { return false }
        cache.ensureCapacity(state.board.count)

        var nextBoard = state.board
        let mover = state.currentPlayer
        let opponent: UInt8 = mover == 1 ? 2 : 1
        nextBoard[index] = mover

        var capturedPoints: [Int] = []
        let seenMark = cache.nextMark()
        for neighbor in neighborIndexTable[index] where nextBoard[neighbor] == opponent {
            if cache.tempMarks[neighbor] == seenMark { continue }
            let analysis = fastGroupAnalysis(at: neighbor, in: nextBoard, cache: cache, collectGroup: true)
            for point in cache.groupBuffer.prefix(analysis.groupCount) {
                cache.tempMarks[point] = seenMark
            }
            if analysis.liberties == 0 {
                for point in cache.groupBuffer.prefix(analysis.groupCount) {
                    nextBoard[point] = 0
                    capturedPoints.append(point)
                }
            }
        }

        let ownAnalysis = fastGroupAnalysis(at: index, in: nextBoard, cache: cache, collectGroup: false)
        if ownAnalysis.liberties == 0 {
            return false
        }

        let boardHashBeforeMove = state.currentBoardHash ?? hash(forFastBoard: state.board)
        var nextHash = boardHashBeforeMove
        nextHash ^= zobristValue(forStoneCode: mover, at: index)
        for point in capturedPoints {
            nextHash ^= zobristValue(forStoneCode: opponent, at: point)
        }

        if let koForbiddenHash = state.koForbiddenHash, koForbiddenHash == nextHash {
            return false
        }

        state.board = nextBoard
        state.koForbiddenHash = boardHashBeforeMove
        state.currentBoardHash = nextHash
        state.consecutivePasses = 0
        if mover == 1 {
            state.capturesBlack += capturedPoints.count
        } else {
            state.capturesWhite += capturedPoints.count
        }
        state.currentPlayer = opponent
        return true
    }

    private func fastGroupLiberties(at index: Int, in board: [UInt8]) -> Int {
        fastGroupLiberties(at: index, in: board, cache: threadLocalRolloutCache())
    }

    private func fastGroupLiberties(at index: Int, in board: [UInt8], cache: RolloutThreadCache) -> Int {
        cache.ensureCapacity(board.count)
        return fastGroupAnalysis(at: index, in: board, cache: cache, collectGroup: false).liberties
    }

    private func adjacentAtariGroupsFast(of stone: UInt8, around index: Int, in board: [UInt8]) -> Int {
        adjacentAtariGroupsFast(of: stone, around: index, in: board, cache: threadLocalRolloutCache())
    }

    private func adjacentAtariGroupsFast(
        of stone: UInt8,
        around index: Int,
        in board: [UInt8],
        cache: RolloutThreadCache
    ) -> Int {
        cache.ensureCapacity(board.count)
        let countedMark = cache.nextMark()
        var total = 0
        for neighbor in neighborIndexTable[index] where board[neighbor] == stone {
            if cache.tempMarks[neighbor] == countedMark { continue }
            let analysis = fastGroupAnalysis(at: neighbor, in: board, cache: cache, collectGroup: true)
            for point in cache.groupBuffer.prefix(analysis.groupCount) {
                cache.tempMarks[point] = countedMark
            }
            if analysis.liberties == 1 {
                total += analysis.groupCount
            }
        }
        return total
    }

    private func fastGroupAnalysis(
        at start: Int,
        in board: [UInt8],
        cache: RolloutThreadCache,
        collectGroup: Bool
    ) -> (groupCount: Int, liberties: Int) {
        let color = board[start]
        guard color != 0 else { return (0, 0) }
        cache.ensureCapacity(board.count)

        let visitMark = cache.nextMark()
        let libertyMark = cache.nextMark()
        cache.stackBuffer.removeAll(keepingCapacity: true)
        cache.stackBuffer.append(start)
        if collectGroup {
            cache.groupBuffer.removeAll(keepingCapacity: true)
        }

        var groupCount = 0
        var liberties = 0

        while let point = cache.stackBuffer.popLast() {
            if cache.visitMarks[point] == visitMark { continue }
            cache.visitMarks[point] = visitMark
            groupCount += 1
            if collectGroup {
                cache.groupBuffer.append(point)
            }

            for neighbor in neighborIndexTable[point] {
                let value = board[neighbor]
                if value == color {
                    if cache.visitMarks[neighbor] != visitMark {
                        cache.stackBuffer.append(neighbor)
                    }
                } else if value == 0 {
                    if cache.libertyMarks[neighbor] != libertyMark {
                        cache.libertyMarks[neighbor] = libertyMark
                        liberties += 1
                    }
                }
            }
        }

        return (groupCount, liberties)
    }

    private func emptyRegionOwnersFast(in board: [UInt8]) -> [UInt8] {
        var owners = Array(repeating: UInt8(0), count: board.count)
        var visited = Array(repeating: false, count: board.count)

        for start in board.indices where board[start] == 0 && !visited[start] {
            var stack = [start]
            var region: [Int] = []
            var bordersBlack = false
            var bordersWhite = false

            while let point = stack.popLast() {
                if visited[point] { continue }
                visited[point] = true
                guard board[point] == 0 else { continue }
                region.append(point)

                for neighbor in neighborIndexTable[point] {
                    switch board[neighbor] {
                    case 0:
                        if !visited[neighbor] {
                            stack.append(neighbor)
                        }
                    case 1:
                        bordersBlack = true
                    case 2:
                        bordersWhite = true
                    default:
                        break
                    }
                }
            }

            let owner: UInt8
            if bordersBlack && !bordersWhite {
                owner = 1
            } else if bordersWhite && !bordersBlack {
                owner = 2
            } else {
                owner = 0
            }
            for point in region {
                owners[point] = owner
            }
        }

        return owners
    }

    private func emptyRegionOwnersFast(
        in board: [UInt8],
        boardHash: UInt64,
        cache: RolloutThreadCache
    ) -> [UInt8] {
        if let cached = cache.ownersByHash[boardHash] {
            return cached
        }
        let computed = emptyRegionOwnersFast(in: board)
        cache.ownersByHash[boardHash] = computed
        return computed
    }

    private func territory(onFastBoard board: [UInt8]) -> (Int, Int) {
        var visited = Array(repeating: false, count: board.count)
        var black = 0
        var white = 0

        for start in board.indices where board[start] == 0 && !visited[start] {
            var stack = [start]
            var regionCount = 0
            var bordersBlack = false
            var bordersWhite = false

            while let point = stack.popLast() {
                if visited[point] { continue }
                visited[point] = true
                guard board[point] == 0 else { continue }
                regionCount += 1

                for neighbor in neighborIndexTable[point] {
                    switch board[neighbor] {
                    case 0:
                        if !visited[neighbor] {
                            stack.append(neighbor)
                        }
                    case 1:
                        bordersBlack = true
                    case 2:
                        bordersWhite = true
                    default:
                        break
                    }
                }
            }

            if bordersBlack && !bordersWhite {
                black += regionCount
            } else if bordersWhite && !bordersBlack {
                white += regionCount
            }
        }

        return (black, white)
    }

    private func shouldPreferPassOverBestCandidate(
        _ candidate: CandidateMove,
        root: SimState,
        perspective: Stone,
        cache: SearchEvalCache
    ) -> Bool {
        let endgameLikely = isLikelyEndgame(state: root)
        let afterFirstPass = root.consecutivePasses > 0
        let passScore = staticBoardScore(for: perspective, in: root, cache: cache)
        let moveScore = staticBoardScore(for: perspective, in: candidate.stateAfterMove, cache: cache)
        let movePoint = Point(row: candidate.row, col: candidate.col)

        if endgameLikely && afterFirstPass && candidate.selfFillNoTactics {
            return moveScore <= passScore + 0.25
        }

        if endgameLikely {
            let ownEyeFill = isOwnEye(at: movePoint, stone: perspective, in: root.board)
            let rootOpponentThreat = maxImmediateCapture(
                for: perspective.opposite,
                in: root,
                sampleLimit: boardSize <= 9 ? 24 : 16
            )
            let moveOpponentThreat = maxImmediateCapture(
                for: perspective.opposite,
                in: candidate.stateAfterMove,
                sampleLimit: boardSize <= 9 ? 24 : 16
            )
            let defensiveGain = rootOpponentThreat - moveOpponentThreat
            let noTacticalBenefit =
                candidate.capturesGained == 0 &&
                defensiveGain <= 0
            // In endgame, pass over neutral/noise moves that do not improve position.
            if noTacticalBenefit {
                let tinyGain = moveScore - passScore
                if afterFirstPass && tinyGain <= 0.20 {
                    return true
                }
                let totalPoints = boardSize * boardSize
                let emptyCount = root.board.reduce(into: 0) { total, row in
                    for stone in row where stone == .empty { total += 1 }
                }
                let veryLate = emptyCount <= max(6, totalPoints / 8)
                if veryLate && rootOpponentThreat <= 1 && tinyGain <= 0.35 {
                    return true
                }
            }
            if noTacticalBenefit && (candidate.selfFillNoTactics || ownEyeFill) {
                return moveScore <= passScore + 0.55
            }
        }

        return shouldHopelessLateGamePass(
            candidate: candidate,
            root: root,
            perspective: perspective,
            passScore: passScore,
            moveScore: moveScore,
            cache: cache
        )
    }

    private func shouldPreferPassOverBestCandidateFast(
        _ candidate: FastCandidateMove,
        root: FastSimState,
        perspective: UInt8,
        cache: SearchEvalCache
    ) -> Bool {
        let endgameLikely = isLikelyEndgameFast(state: root)
        let afterFirstPass = root.consecutivePasses > 0
        let passScore = staticBoardScoreFast(for: perspective, in: root, cache: cache)
        let moveScore = staticBoardScoreFast(for: perspective, in: candidate.stateAfterMove, cache: cache)
        let ownEyeFill = isOwnEyeFast(at: candidate.index, stone: perspective, in: root.board)

        if endgameLikely && afterFirstPass && candidate.selfFillNoTactics {
            return moveScore <= passScore + 0.25
        }

        if endgameLikely {
            let rolloutCache = threadLocalRolloutCache()
            let opponent: UInt8 = perspective == 1 ? 2 : 1
            let rootOpponentThreat = maxImmediateCaptureFast(
                for: opponent,
                in: root,
                sampleLimit: boardSize <= 9 ? 24 : 16,
                cache: rolloutCache
            )
            let moveOpponentThreat = maxImmediateCaptureFast(
                for: opponent,
                in: candidate.stateAfterMove,
                sampleLimit: boardSize <= 9 ? 24 : 16,
                cache: rolloutCache
            )
            let defensiveGain = rootOpponentThreat - moveOpponentThreat
            let noTacticalBenefit =
                candidate.capturesGained == 0 &&
                defensiveGain <= 0
            // In endgame, pass over neutral/noise moves that do not improve position.
            if noTacticalBenefit {
                let tinyGain = moveScore - passScore
                if afterFirstPass && tinyGain <= 0.20 {
                    return true
                }
                let totalPoints = boardSize * boardSize
                let emptyCount = root.board.reduce(into: 0) { total, value in
                    if value == 0 { total += 1 }
                }
                let veryLate = emptyCount <= max(6, totalPoints / 8)
                if veryLate && rootOpponentThreat <= 1 && tinyGain <= 0.35 {
                    return true
                }
            }
            if noTacticalBenefit && (candidate.selfFillNoTactics || ownEyeFill) {
                return moveScore <= passScore + 0.55
            }
        }

        return shouldHopelessLateGamePassFast(
            candidate: candidate,
            root: root,
            perspective: perspective,
            passScore: passScore,
            moveScore: moveScore,
            cache: cache
        )
    }

    private func shouldHopelessLateGamePass(
        candidate: CandidateMove,
        root: SimState,
        perspective: Stone,
        passScore: Double,
        moveScore: Double,
        cache: SearchEvalCache
    ) -> Bool {
        guard isLikelyEndgame(state: root) else { return false }
        let totalPoints = boardSize * boardSize
        let emptyCount = root.board.reduce(into: 0) { total, row in
            for stone in row where stone == .empty { total += 1 }
        }
        let veryLate = emptyCount <= max(6, totalPoints / 8)
        guard root.consecutivePasses > 0 || veryLate else { return false }

        let immediateGain = moveScore - passScore
        if immediateGain > 1.5 { return false }

        let deficit = -passScore
        guard deficit > 0 else { return false }

        let sampleLimit = boardSize <= 9 ? 24 : 16
        let captureUpside = maxImmediateCapture(
            for: perspective,
            in: root,
            sampleLimit: sampleLimit
        )
        let localCounter = bestLocalCounterScore(
            for: perspective,
            in: root,
            sampleLimit: boardSize <= 9 ? 10 : 7,
            cache: cache
        )
        let localCounterGain = max(0.0, localCounter - passScore)
        let hopelessBaseThreshold = Double(max(boardSize <= 9 ? 12 : 24, totalPoints / 7))
        let tacticalAllowance = (Double(captureUpside) * 3.0) + (localCounterGain * 0.85)

        if candidate.capturesGained >= 2 {
            return false
        }

        return deficit >= (hopelessBaseThreshold + tacticalAllowance)
    }

    private func shouldHopelessLateGamePassFast(
        candidate: FastCandidateMove,
        root: FastSimState,
        perspective: UInt8,
        passScore: Double,
        moveScore: Double,
        cache: SearchEvalCache
    ) -> Bool {
        guard isLikelyEndgameFast(state: root) else { return false }
        let totalPoints = boardSize * boardSize
        let emptyCount = root.board.reduce(into: 0) { total, value in
            if value == 0 { total += 1 }
        }
        let veryLate = emptyCount <= max(6, totalPoints / 8)
        guard root.consecutivePasses > 0 || veryLate else { return false }

        let immediateGain = moveScore - passScore
        if immediateGain > 1.5 { return false }

        let deficit = -passScore
        guard deficit > 0 else { return false }

        let rolloutCache = threadLocalRolloutCache()
        let sampleLimit = boardSize <= 9 ? 24 : 16
        let captureUpside = maxImmediateCaptureFast(
            for: perspective,
            in: root,
            sampleLimit: sampleLimit,
            cache: rolloutCache
        )
        let localCounter = bestLocalCounterScoreFast(
            for: perspective,
            in: root,
            sampleLimit: boardSize <= 9 ? 10 : 7,
            cache: cache,
            rolloutCache: rolloutCache
        )
        let localCounterGain = max(0.0, localCounter - passScore)
        let hopelessBaseThreshold = Double(max(boardSize <= 9 ? 12 : 24, totalPoints / 7))
        let tacticalAllowance = (Double(captureUpside) * 3.0) + (localCounterGain * 0.85)

        if candidate.capturesGained >= 2 {
            return false
        }

        return deficit >= (hopelessBaseThreshold + tacticalAllowance)
    }

    private func isLikelyEndgame(state: SimState) -> Bool {
        var emptyCount = 0
        for row in state.board {
            for stone in row where stone == .empty {
                emptyCount += 1
            }
        }
        let totalPoints = boardSize * boardSize
        if state.consecutivePasses > 0 {
            return true
        }
        return emptyCount <= max(10, totalPoints / 4)
    }

    private func isLikelyOpening(state: SimState) -> Bool {
        if state.consecutivePasses > 0 { return false }
        var occupied = 0
        for row in state.board {
            for stone in row where stone != .empty {
                occupied += 1
            }
        }
        let totalPoints = boardSize * boardSize
        return occupied <= max(10, totalPoints / 8)
    }

    private func isLikelyOpeningFast(state: FastSimState) -> Bool {
        if state.consecutivePasses > 0 { return false }
        let boardHash = state.currentBoardHash ?? hash(forFastBoard: state.board)
        let cache = threadLocalRolloutCache()
        if let cached = cache.openingLikelyByHash[boardHash] {
            return cached
        }
        let occupied = state.board.reduce(into: 0) { count, value in
            if value != 0 { count += 1 }
        }
        let totalPoints = boardSize * boardSize
        let computed = occupied <= max(10, totalPoints / 8)
        cache.openingLikelyByHash[boardHash] = computed
        return computed
    }

    private func localToPoint(
        x: Int,
        y: Int,
        corner: CornerOrientation,
        size: Int
    ) -> Point {
        switch corner {
        case .topLeft:
            return Point(row: y, col: x)
        case .topRight:
            return Point(row: y, col: size - 1 - x)
        case .bottomLeft:
            return Point(row: size - 1 - y, col: x)
        case .bottomRight:
            return Point(row: size - 1 - y, col: size - 1 - x)
        }
    }

    private func josekiRules(for size: Int) -> [JosekiRule] {
        let p = size <= 9 ? 2 : 3
        let q = min(size - 1, p + 2)
        let near = max(0, p - 1)
        let far = min(size - 1, p + 3)

        // Lightweight local joseki continuation set around star/komoku corners.
        return [
            // Approach a star-point corner from either side.
            JosekiRule(requiredOwn: [], requiredOpp: [(p, p)], suggestions: [(q, p), (p, q)]),
            // Opponent approaches your star point: answer with a stable local extension.
            JosekiRule(requiredOwn: [(p, p)], requiredOpp: [(q, p)], suggestions: [(q, near), (q, p + 1)]),
            JosekiRule(requiredOwn: [(p, p)], requiredOpp: [(p, q)], suggestions: [(near, q), (p + 1, q)]),
            // Approach a komoku corner.
            JosekiRule(requiredOwn: [], requiredOpp: [(near, p)], suggestions: [(q, p), (near, q)]),
            JosekiRule(requiredOwn: [], requiredOpp: [(p, near)], suggestions: [(p, q), (q, near)]),
            // Basic continuation when both sides have established local contact.
            JosekiRule(requiredOwn: [(q, p)], requiredOpp: [(p, p)], suggestions: [(far, p), (q, p + 1)]),
            JosekiRule(requiredOwn: [(p, q)], requiredOpp: [(p, p)], suggestions: [(p, far), (p + 1, q)])
        ]
    }

    private func matchesJosekiRule(
        _ rule: JosekiRule,
        corner: CornerOrientation,
        for stone: Stone,
        in board: [[Stone]]
    ) -> Bool {
        let size = boardSize
        for (x, y) in rule.requiredOwn {
            guard x >= 0, y >= 0, x < size, y < size else { return false }
            let p = localToPoint(x: x, y: y, corner: corner, size: size)
            if board[p.row][p.col] != stone { return false }
        }
        for (x, y) in rule.requiredOpp {
            guard x >= 0, y >= 0, x < size, y < size else { return false }
            let p = localToPoint(x: x, y: y, corner: corner, size: size)
            if board[p.row][p.col] != stone.opposite { return false }
        }
        return true
    }

    private func josekiPreferredPoints(in position: [[Stone]], for stone: Stone) -> Set<Point> {
        guard josekiBookEnabled else { return [] }
        let occupied = position.reduce(into: 0) { total, row in
            for value in row where value != .empty { total += 1 }
        }
        let earlyLimit = boardSize <= 9 ? 20 : 42
        guard occupied <= earlyLimit else { return [] }

        let size = boardSize
        let p = size <= 9 ? 2 : 3
        let q = min(size - 1, p + 2)
        let rules = josekiRules(for: size)
        var suggestions: Set<Point> = []

        for corner in CornerOrientation.allCases {
            // First-phase corner occupation preference (4-4 on 18x18, 3-3-ish on 9x9).
            let anchor = localToPoint(x: p, y: p, corner: corner, size: size)
            if position[anchor.row][anchor.col] == .empty {
                suggestions.insert(anchor)
            }

            // Secondary corner claim if anchor unavailable.
            let altA = localToPoint(x: p, y: q, corner: corner, size: size)
            let altB = localToPoint(x: q, y: p, corner: corner, size: size)
            if position[altA.row][altA.col] == .empty { suggestions.insert(altA) }
            if position[altB.row][altB.col] == .empty { suggestions.insert(altB) }

            // Continuation table matching.
            for rule in rules where matchesJosekiRule(rule, corner: corner, for: stone, in: position) {
                for (x, y) in rule.suggestions {
                    guard x >= 0, y >= 0, x < size, y < size else { continue }
                    let p = localToPoint(x: x, y: y, corner: corner, size: size)
                    if position[p.row][p.col] == .empty {
                        suggestions.insert(p)
                    }
                }
            }
        }

        return suggestions
    }

    private func matchesJosekiRuleFast(
        _ rule: JosekiRule,
        corner: CornerOrientation,
        for stone: UInt8,
        in board: [UInt8]
    ) -> Bool {
        let size = boardSize
        let opponent: UInt8 = stone == 1 ? 2 : 1
        for (x, y) in rule.requiredOwn {
            guard x >= 0, y >= 0, x < size, y < size else { return false }
            let p = localToPoint(x: x, y: y, corner: corner, size: size)
            if board[(p.row * size) + p.col] != stone { return false }
        }
        for (x, y) in rule.requiredOpp {
            guard x >= 0, y >= 0, x < size, y < size else { return false }
            let p = localToPoint(x: x, y: y, corner: corner, size: size)
            if board[(p.row * size) + p.col] != opponent { return false }
        }
        return true
    }

    private func josekiPreferredIndicesFast(in board: [UInt8], for stone: UInt8) -> Set<Int> {
        guard josekiBookEnabled else { return [] }
        let occupied = board.reduce(into: 0) { total, value in
            if value != 0 { total += 1 }
        }
        let earlyLimit = boardSize <= 9 ? 20 : 42
        guard occupied <= earlyLimit else { return [] }

        let size = boardSize
        let p = size <= 9 ? 2 : 3
        let q = min(size - 1, p + 2)
        let rules = josekiRules(for: size)
        var suggestions: Set<Int> = []

        for corner in CornerOrientation.allCases {
            let anchor = localToPoint(x: p, y: p, corner: corner, size: size)
            let anchorIndex = (anchor.row * size) + anchor.col
            if board[anchorIndex] == 0 {
                suggestions.insert(anchorIndex)
            }

            let altA = localToPoint(x: p, y: q, corner: corner, size: size)
            let altB = localToPoint(x: q, y: p, corner: corner, size: size)
            let altAIndex = (altA.row * size) + altA.col
            let altBIndex = (altB.row * size) + altB.col
            if board[altAIndex] == 0 { suggestions.insert(altAIndex) }
            if board[altBIndex] == 0 { suggestions.insert(altBIndex) }

            for rule in rules where matchesJosekiRuleFast(rule, corner: corner, for: stone, in: board) {
                for (x, y) in rule.suggestions {
                    guard x >= 0, y >= 0, x < size, y < size else { continue }
                    let p = localToPoint(x: x, y: y, corner: corner, size: size)
                    let idx = (p.row * size) + p.col
                    if board[idx] == 0 {
                        suggestions.insert(idx)
                    }
                }
            }
        }
        return suggestions
    }

    private func openingExpansionPoints(in position: [[Stone]], for stone: Stone) -> [Point] {
        var emptyPoints: [Point] = []
        var stones: [Point] = []
        var ownStones: [Point] = []
        var enemyStones: [Point] = []

        for row in 0..<boardSize {
            for col in 0..<boardSize {
                let p = Point(row: row, col: col)
                if position[row][col] == .empty {
                    emptyPoints.append(p)
                } else {
                    stones.append(p)
                    if position[row][col] == stone {
                        ownStones.append(p)
                    } else {
                        enemyStones.append(p)
                    }
                }
            }
        }

        if emptyPoints.isEmpty { return [] }
        if stones.isEmpty { return emptyPoints }

        let size = boardSize
        let ownStoneCount = ownStones.count
        let totalStones = stones.count
        let josekiPreferred = josekiPreferredPoints(in: position, for: stone)
        let corners = [
            Point(row: 0, col: 0),
            Point(row: 0, col: size - 1),
            Point(row: size - 1, col: 0),
            Point(row: size - 1, col: size - 1)
        ]
        let preferredLine = size <= 9 ? 2 : 3  // 3rd/4th line style opening preference.
        let edgeDist = { (p: Point) in
            min(min(p.row, size - 1 - p.row), min(p.col, size - 1 - p.col))
        }
        let cornerDist = { (p: Point) in
            corners.reduce(Int.max) { best, c in
                min(best, abs(c.row - p.row) + abs(c.col - p.col))
            }
        }

        let center = Double(boardSize - 1) / 2.0
        func score(for point: Point) -> Int {
            let adjacentEnemy = neighbors(of: point).reduce(into: 0) { total, n in
                if position[n.row][n.col] == stone.opposite { total += 1 }
            }
            let adjacentOwn = neighbors(of: point).reduce(into: 0) { total, n in
                if position[n.row][n.col] == stone { total += 1 }
            }
            let adjacentEmpty = neighbors(of: point).reduce(into: 0) { total, n in
                if position[n.row][n.col] == .empty { total += 1 }
            }
            let minDist = stones.reduce(Int.max) { best, s in
                let d = abs(s.row - point.row) + abs(s.col - point.col)
                return min(best, d)
            }
            let minOwnDist = ownStones.isEmpty
                ? minDist
                : ownStones.reduce(Int.max) { best, s in
                    let d = abs(s.row - point.row) + abs(s.col - point.col)
                    return min(best, d)
                }
            let minEnemyDist = enemyStones.isEmpty
                ? minDist
                : enemyStones.reduce(Int.max) { best, s in
                    let d = abs(s.row - point.row) + abs(s.col - point.col)
                    return min(best, d)
                }
            let clampedDist = min(minDist, 6)
            let distanceFromCenter = abs(Double(point.row) - center) + abs(Double(point.col) - center)
            let localEdgeDist = edgeDist(point)
            let localCornerDist = cornerDist(point)
            let contactPenalty = max(0, adjacentEnemy - adjacentOwn) * 40

            // Prefer corner-side frameworks (3rd/4th line), especially in first several moves.
            let lineBonus = max(0, 130 - (abs(localEdgeDist - preferredLine) * 44))
            let earlyCornerBias = totalStones <= (boardSize <= 9 ? 8 : 14)
                ? max(0, 110 - (localCornerDist * 16))
                : max(0, 65 - (localCornerDist * 11))

            // Encourage proper extension from own stones without over-concentrating.
            let extensionTarget = boardSize <= 9 ? 3 : 4
            let extensionBonus = ownStoneCount == 0
                ? 0
                : max(0, 76 - abs(minOwnDist - extensionTarget) * 20)
            let overconcentrationPenalty = ownStoneCount == 0 ? 0 : max(0, 3 - minOwnDist) * 42

            // Opening should avoid direct contact unless tactical pressure exists.
            let earlyContactPenalty = (adjacentEnemy > 0 && minEnemyDist <= 2) ? 42 : 0
            let centerPenalty = localEdgeDist >= preferredLine + 2
                ? Int((Double(boardSize) - distanceFromCenter).rounded()) * 12
                : 0
            let edgeLinePenalty: Int
            if adjacentEnemy == 0 && localEdgeDist == 0 {
                edgeLinePenalty = totalStones <= (boardSize <= 9 ? 10 : 16) ? 300 : 190
            } else if adjacentEnemy == 0 && localEdgeDist == 1 && ownStoneCount > 0 {
                edgeLinePenalty = 95
            } else {
                edgeLinePenalty = 0
            }
            let selfEnclosurePenalty =
                (adjacentEnemy == 0 && adjacentOwn >= 2 && adjacentEmpty <= 1)
                ? 185
                : 0
            let spaciousExpansionBonus =
                (adjacentEnemy == 0 && localEdgeDist >= preferredLine)
                ? (minDist * 12 + (adjacentEmpty * 8))
                : 0
            let josekiBonus = josekiPreferred.contains(point) ? 520 : 0

            return
                (clampedDist * 20) +
                (adjacentEmpty * 14) +
                lineBonus +
                earlyCornerBias +
                spaciousExpansionBonus +
                josekiBonus +
                extensionBonus -
                overconcentrationPenalty -
                contactPenalty -
                earlyContactPenalty -
                centerPenalty -
                edgeLinePenalty -
                selfEnclosurePenalty
        }

        return emptyPoints.sorted { score(for: $0) > score(for: $1) }
    }

    private func openingExpansionIndicesFast(in board: [UInt8], for stone: UInt8) -> [Int] {
        var emptyIndices: [Int] = []
        var stones: [Int] = []
        var ownStones: [Int] = []
        var enemyStones: [Int] = []

        for index in board.indices {
            let value = board[index]
            if value == 0 {
                emptyIndices.append(index)
            } else {
                stones.append(index)
                if value == stone {
                    ownStones.append(index)
                } else {
                    enemyStones.append(index)
                }
            }
        }

        if emptyIndices.isEmpty { return [] }
        if stones.isEmpty { return emptyIndices }

        let size = boardSize
        let ownStoneCount = ownStones.count
        let totalStones = stones.count
        let josekiPreferred = josekiPreferredIndicesFast(in: board, for: stone)
        let corners = [0, size - 1, (size - 1) * size, (size * size) - 1]
        let preferredLine = size <= 9 ? 2 : 3

        func rc(_ index: Int) -> (Int, Int) { (index / size, index % size) }
        func edgeDist(_ index: Int) -> Int {
            let (r, c) = rc(index)
            return min(min(r, size - 1 - r), min(c, size - 1 - c))
        }
        func cornerDist(_ index: Int) -> Int {
            let (r, c) = rc(index)
            return corners.reduce(Int.max) { best, corner in
                let (cr, cc) = rc(corner)
                return min(best, abs(cr - r) + abs(cc - c))
            }
        }
        let center = Double(size - 1) / 2.0

        func score(for index: Int) -> Int {
            let adjacentEnemy = neighborIndexTable[index].reduce(into: 0) { total, n in
                if board[n] == (stone == 1 ? 2 : 1) { total += 1 }
            }
            let adjacentOwn = neighborIndexTable[index].reduce(into: 0) { total, n in
                if board[n] == stone { total += 1 }
            }
            let adjacentEmpty = neighborIndexTable[index].reduce(into: 0) { total, n in
                if board[n] == 0 { total += 1 }
            }
            let minDist = stones.reduce(Int.max) { best, s in
                let (r1, c1) = rc(s)
                let (r2, c2) = rc(index)
                return min(best, abs(r1 - r2) + abs(c1 - c2))
            }
            let minOwnDist = ownStones.isEmpty ? minDist : ownStones.reduce(Int.max) { best, s in
                let (r1, c1) = rc(s)
                let (r2, c2) = rc(index)
                return min(best, abs(r1 - r2) + abs(c1 - c2))
            }
            let minEnemyDist = enemyStones.isEmpty ? minDist : enemyStones.reduce(Int.max) { best, s in
                let (r1, c1) = rc(s)
                let (r2, c2) = rc(index)
                return min(best, abs(r1 - r2) + abs(c1 - c2))
            }

            let (row, col) = rc(index)
            let clampedDist = min(minDist, 6)
            let distanceFromCenter = abs(Double(row) - center) + abs(Double(col) - center)
            let localEdgeDist = edgeDist(index)
            let localCornerDist = cornerDist(index)
            let contactPenalty = max(0, adjacentEnemy - adjacentOwn) * 40
            let lineBonus = max(0, 130 - (abs(localEdgeDist - preferredLine) * 44))
            let earlyCornerBias = totalStones <= (size <= 9 ? 8 : 14)
                ? max(0, 110 - (localCornerDist * 16))
                : max(0, 65 - (localCornerDist * 11))
            let extensionTarget = size <= 9 ? 3 : 4
            let extensionBonus = ownStoneCount == 0
                ? 0
                : max(0, 76 - abs(minOwnDist - extensionTarget) * 20)
            let overconcentrationPenalty = ownStoneCount == 0 ? 0 : max(0, 3 - minOwnDist) * 42
            let earlyContactPenalty = (adjacentEnemy > 0 && minEnemyDist <= 2) ? 42 : 0
            let centerPenalty = localEdgeDist >= preferredLine + 2
                ? Int((Double(size) - distanceFromCenter).rounded()) * 12
                : 0
            let edgeLinePenalty: Int
            if adjacentEnemy == 0 && localEdgeDist == 0 {
                edgeLinePenalty = totalStones <= (size <= 9 ? 10 : 16) ? 300 : 190
            } else if adjacentEnemy == 0 && localEdgeDist == 1 && ownStoneCount > 0 {
                edgeLinePenalty = 95
            } else {
                edgeLinePenalty = 0
            }
            let selfEnclosurePenalty =
                (adjacentEnemy == 0 && adjacentOwn >= 2 && adjacentEmpty <= 1)
                ? 185
                : 0
            let spaciousExpansionBonus =
                (adjacentEnemy == 0 && localEdgeDist >= preferredLine)
                ? (minDist * 12 + (adjacentEmpty * 8))
                : 0
            let josekiBonus = josekiPreferred.contains(index) ? 520 : 0

            return
                (clampedDist * 20) +
                (adjacentEmpty * 14) +
                lineBonus +
                earlyCornerBias +
                spaciousExpansionBonus +
                josekiBonus +
                extensionBonus -
                overconcentrationPenalty -
                contactPenalty -
                earlyContactPenalty -
                centerPenalty -
                edgeLinePenalty -
                selfEnclosurePenalty
        }

        return emptyIndices.sorted { score(for: $0) > score(for: $1) }
    }

    private func simulateMove(row: Int, col: Int, state: SimState) -> SimState? {
        var next = state
        guard applySimMove(row: row, col: col, to: &next) else { return nil }
        return next
    }

    private func applySimMove(row: Int, col: Int, to state: inout SimState) -> Bool {
        guard row >= 0, row < boardSize, col >= 0, col < boardSize else { return false }
        guard state.board[row][col] == .empty else { return false }

        var nextBoard = state.board
        let mover = state.currentPlayer
        nextBoard[row][col] = mover

        let capturedPoints = captureGroupsDetailed(of: mover.opposite, on: &nextBoard)
        if liberties(ofGroupAt: row, col: col, in: nextBoard).isEmpty {
            return false
        }

        let boardHashBeforeMove = state.currentBoardHash ?? hash(for: state.board)
        var nextHash = boardHashBeforeMove
        nextHash ^= zobristValue(for: mover, row: row, col: col)
        for point in capturedPoints {
            nextHash ^= zobristValue(for: mover.opposite, row: point.row, col: point.col)
        }
        if let koForbiddenHash = state.koForbiddenHash, koForbiddenHash == nextHash {
            return false
        }

        state.board = nextBoard
        state.koForbiddenHash = boardHashBeforeMove
        state.currentBoardHash = nextHash
        state.consecutivePasses = 0

        if mover == .black {
            state.capturesBlack += capturedPoints.count
        } else {
            state.capturesWhite += capturedPoints.count
        }

        state.currentPlayer = mover.opposite
        return true
    }

    private func applyPass(to state: inout SimState) {
        state.consecutivePasses += 1
        state.currentPlayer = state.currentPlayer.opposite
    }

    private func saveSnapshot() {
        historyStack.append(snapshot())
        _ = saveGameToDisk(manual: false)
    }

    private func snapshot() -> Snapshot {
        refreshCurrentTurnElapsed()
        return Snapshot(
            board: board,
            currentPlayer: currentPlayer,
            capturesBlack: capturesBlack,
            capturesWhite: capturesWhite,
            territoryBlack: territoryBlack,
            territoryWhite: territoryWhite,
            finalBlackScore: finalBlackScore,
            finalWhiteScore: finalWhiteScore,
            gameOver: gameOver,
            statusMessage: statusMessage,
            currentBoardHash: currentBoardHash,
            koForbiddenHash: koForbiddenHash,
            consecutivePasses: consecutivePasses,
            moveHistory: moveHistory,
            currentTurnElapsed: currentTurnElapsed,
            totalTimeBlack: totalTimeBlack,
            totalTimeWhite: totalTimeWhite,
            lastMoveRow: lastMoveRow,
            lastMoveCol: lastMoveCol
        )
    }

    private func restore(from snapshot: Snapshot) {
        board = snapshot.board
        currentPlayer = snapshot.currentPlayer
        capturesBlack = snapshot.capturesBlack
        capturesWhite = snapshot.capturesWhite
        territoryBlack = snapshot.territoryBlack
        territoryWhite = snapshot.territoryWhite
        finalBlackScore = snapshot.finalBlackScore
        finalWhiteScore = snapshot.finalWhiteScore
        gameOver = snapshot.gameOver
        statusMessage = snapshot.statusMessage
        currentBoardHash = snapshot.currentBoardHash
        koForbiddenHash = snapshot.koForbiddenHash
        consecutivePasses = snapshot.consecutivePasses
        moveHistory = snapshot.moveHistory
        currentTurnElapsed = snapshot.currentTurnElapsed
        totalTimeBlack = snapshot.totalTimeBlack
        totalTimeWhite = snapshot.totalTimeWhite
        lastMoveRow = snapshot.lastMoveRow
        lastMoveCol = snapshot.lastMoveCol
        if gameOver {
            turnStartDate = nil
            currentTurnElapsed = 0
        } else {
            turnStartDate = Date().addingTimeInterval(-currentTurnElapsed)
        }
        pausedAt = nil
    }

    private func apply(savedGame: SavedGame) {
        isRestoringFromLoad = true
        boardSize = savedGame.boardSize
        rebuildNeighborTable()
        blackPlayer = savedGame.blackPlayer
        whitePlayer = savedGame.whitePlayer
        aiStrength = savedGame.aiStrength
        tacticalModeEnabled = savedGame.tacticalModeEnabled ?? false
        captureReadingStrength = savedGame.captureReadingStrength ?? .normal
        showStrategyEnabled = savedGame.showStrategyEnabled ?? false
        josekiBookEnabled = savedGame.josekiBookEnabled ?? true
        isAIPaused = savedGame.isAIPaused
        board = savedGame.board
        currentPlayer = savedGame.currentPlayer
        capturesBlack = savedGame.capturesBlack
        capturesWhite = savedGame.capturesWhite
        territoryBlack = savedGame.territoryBlack
        territoryWhite = savedGame.territoryWhite
        finalBlackScore = savedGame.finalBlackScore
        finalWhiteScore = savedGame.finalWhiteScore
        gameOver = savedGame.gameOver
        statusMessage = savedGame.statusMessage
        moveHistory = savedGame.moveHistory
        currentTurnElapsed = savedGame.currentTurnElapsed ?? 0
        totalTimeBlack = savedGame.totalTimeBlack ?? 0
        totalTimeWhite = savedGame.totalTimeWhite ?? 0
        lastMoveRow = savedGame.lastMoveRow
        lastMoveCol = savedGame.lastMoveCol
        currentBoardHash =
            decodeHashString(savedGame.currentBoardHash) ??
            decodeHashString(savedGame.previousBoardHash) ??
            hash(for: board)
        koForbiddenHash = decodeHashString(savedGame.koForbiddenHash)
        consecutivePasses = savedGame.consecutivePasses
        if gameOver {
            turnStartDate = nil
            currentTurnElapsed = 0
        } else {
            turnStartDate = Date().addingTimeInterval(-currentTurnElapsed)
        }
        pausedAt = nil
        historyStack = [snapshot()]
        isRestoringFromLoad = false
    }

    private func beginStrategySession(for stone: Stone, token: Int) {
        guard showStrategyEnabled else { return }
        activeStrategyToken = token
        strategyGhostPublishLock.lock()
        strategyGhostLastPublishUptime = 0
        strategyGhostLastCurrent = nil
        strategyGhostLastBest = nil
        strategyGhostPublishLock.unlock()
        strategyGhosts = []
    }

    private func clearStrategyDisplay() {
        strategyGhostPublishLock.lock()
        strategyGhostLastPublishUptime = 0
        strategyGhostLastCurrent = nil
        strategyGhostLastBest = nil
        strategyGhostPublishLock.unlock()
        strategyGhosts = []
    }

#if DEBUG
    func runKoRegressionHarness() {
        guard boardSize >= 5 else {
            statusMessage = "Ko self-test unavailable: board too small"
            return
        }

        rebuildNeighborTable()
        let n = boardSize
        var setupBoard = Array(
            repeating: Array(repeating: Stone.empty, count: n),
            count: n
        )

        // Known simple-ko shape near the upper-left.
        // White at (1,1) has one liberty at (1,2).
        setupBoard[1][1] = .white
        setupBoard[0][1] = .black
        setupBoard[2][1] = .black
        setupBoard[1][0] = .black
        setupBoard[0][2] = .white
        setupBoard[2][2] = .white
        setupBoard[1][3] = .white

        let startHash = hash(for: setupBoard)
        let baseState = SimState(
            board: setupBoard,
            currentPlayer: .black,
            capturesBlack: 0,
            capturesWhite: 0,
            currentBoardHash: startHash,
            koForbiddenHash: nil,
            consecutivePasses: 0
        )

        var simState = baseState
        let simCaptureOK = applySimMove(row: 1, col: 2, to: &simState)
        let simRecaptureAllowed = applySimMove(row: 1, col: 1, to: &simState)
        let simKoSet = simState.koForbiddenHash == startHash

        var fastState = makeFastState(from: baseState)
        let captureIndex = (1 * n) + 2
        let recaptureIndex = (1 * n) + 1
        let fastCaptureOK = applyFastSimMove(at: captureIndex, to: &fastState)
        let fastRecaptureAllowed = applyFastSimMove(at: recaptureIndex, to: &fastState)
        let fastKoSet = fastState.koForbiddenHash == startHash

        let passed =
            simCaptureOK &&
            !simRecaptureAllowed &&
            simKoSet &&
            fastCaptureOK &&
            !fastRecaptureAllowed &&
            fastKoSet

        if passed {
            statusMessage = "Ko self-test passed: immediate recapture rejected."
        } else {
            statusMessage =
                "Ko self-test FAILED (sim cap=\(simCaptureOK), sim recapture=\(simRecaptureAllowed), " +
                "fast cap=\(fastCaptureOK), fast recapture=\(fastRecaptureAllowed))."
            assertionFailure(statusMessage)
        }
    }
#endif

    private func previewStrategyMoveFast(
        in state: FastSimState,
        mover: UInt8,
        scanLimit: Int,
        cache: RolloutThreadCache
    ) -> Int? {
        var probe = state
        probe.currentPlayer = mover
        let boardHash = probe.currentBoardHash ?? hash(forFastBoard: probe.board)
        let openingLikely = isLikelyOpeningFast(state: probe)
        let endgameLikely = isLikelyEndgameFast(state: probe)
        let afterFirstPass = probe.consecutivePasses > 0
        let koRecapturePending = hasKoRecaptureOpportunityFast(for: mover, in: probe, cache: cache)
        let ownersBeforeMove = emptyRegionOwnersFast(in: probe.board, boardHash: boardHash, cache: cache)
        let points = openingLikely
            ? openingExpansionIndicesFast(in: probe.board, for: mover)
            : preferredEmptyIndicesFast(in: probe.board, boardHash: boardHash, cache: cache)
        if points.isEmpty { return nil }

        var bestIndex: Int?
        var bestScore = -Double.greatestFiniteMagnitude
        for (rank, pointIndex) in points.prefix(scanLimit).enumerated() {
            var next = probe
            guard applyFastSimMove(at: pointIndex, to: &next, cache: cache) else { continue }
            let immediate = immediateHeuristicFast(
                from: probe,
                to: next,
                moveIndex: pointIndex,
                stone: mover,
                ownerBeforeMove: ownersBeforeMove[pointIndex],
                endgameLikely: endgameLikely,
                openingLikely: openingLikely,
                afterFirstPass: afterFirstPass,
                koRecapturePending: koRecapturePending,
                cache: cache
            )
            let capturesGained: Int
            if mover == 1 {
                capturesGained = next.capturesBlack - probe.capturesBlack
            } else {
                capturesGained = next.capturesWhite - probe.capturesWhite
            }
            let policyRaw = policyPriorRawFast(
                moveIndex: pointIndex,
                root: probe,
                immediateScore: immediate.score,
                capturesGained: capturesGained,
                selfFillNoTactics: immediate.selfFillNoTactics,
                openingLikely: openingLikely,
                endgameLikely: endgameLikely,
                orderRank: rank,
                orderCount: min(scanLimit, points.count)
            )
            let combined = Double(immediate.score) + (policyRaw * 120.0)
            if combined > bestScore {
                bestScore = combined
                bestIndex = pointIndex
            }
        }
        return bestIndex
    }

    private func previewStrategyMove(
        in state: SimState,
        mover: Stone,
        scanLimit: Int
    ) -> Point? {
        var probe = state
        probe.currentPlayer = mover
        let openingLikely = isLikelyOpening(state: probe)
        let endgameLikely = isLikelyEndgame(state: probe)
        let afterFirstPass = probe.consecutivePasses > 0
        let koRecapturePending = hasKoRecaptureOpportunity(for: mover, in: probe)
        let ownersBeforeMove = emptyRegionOwners(in: probe.board)
        let points = openingLikely
            ? openingExpansionPoints(in: probe.board, for: mover)
            : preferredEmptyPoints(in: probe.board)
        if points.isEmpty { return nil }

        var bestPoint: Point?
        var bestScore = -Double.greatestFiniteMagnitude
        for (rank, point) in points.prefix(scanLimit).enumerated() {
            guard let next = simulateMove(row: point.row, col: point.col, state: probe) else { continue }
            let immediate = immediateHeuristic(
                from: probe,
                to: next,
                move: point,
                for: mover,
                ownerBeforeMove: ownersBeforeMove[point.row][point.col],
                endgameLikely: endgameLikely,
                openingLikely: openingLikely,
                afterFirstPass: afterFirstPass,
                koRecapturePending: koRecapturePending
            )
            let capturesGained: Int
            if mover == .black {
                capturesGained = next.capturesBlack - probe.capturesBlack
            } else {
                capturesGained = next.capturesWhite - probe.capturesWhite
            }
            let policyRaw = policyPriorRaw(
                move: point,
                root: probe,
                immediateScore: immediate.score,
                capturesGained: capturesGained,
                selfFillNoTactics: immediate.selfFillNoTactics,
                openingLikely: openingLikely,
                endgameLikely: endgameLikely,
                orderRank: rank,
                orderCount: min(scanLimit, points.count)
            )
            let combined = Double(immediate.score) + (policyRaw * 120.0)
            if combined > bestScore {
                bestScore = combined
                bestPoint = point
            }
        }
        return bestPoint
    }

    private func previewStrategyLineFast(
        from stateAfterAIMove: FastSimState,
        aiStone: Stone
    ) -> (opponentResponse: Int?, aiFollowUp: Int?) {
        let cache = threadLocalRolloutCache()
        let responseScanLimit = boardSize <= 9 ? 18 : 12
        let followUpScanLimit = boardSize <= 9 ? 14 : 10
        let response = previewStrategyMoveFast(
            in: stateAfterAIMove,
            mover: stateAfterAIMove.currentPlayer,
            scanLimit: responseScanLimit,
            cache: cache
        )
        guard let response else {
            return (nil, nil)
        }
        guard tacticalModeEnabled || aiStrength == .strong else {
            return (response, nil)
        }

        var afterResponse = stateAfterAIMove
        guard applyFastSimMove(at: response, to: &afterResponse, cache: cache) else {
            return (response, nil)
        }
        let aiCode = stoneCode(for: aiStone)
        let followUp = previewStrategyMoveFast(
            in: afterResponse,
            mover: aiCode,
            scanLimit: followUpScanLimit,
            cache: cache
        )
        return (response, followUp)
    }

    private func previewStrategyLine(
        from stateAfterAIMove: SimState,
        aiStone: Stone
    ) -> (opponentResponse: Point?, aiFollowUp: Point?) {
        let responseScanLimit = boardSize <= 9 ? 18 : 12
        let followUpScanLimit = boardSize <= 9 ? 14 : 10
        let response = previewStrategyMove(
            in: stateAfterAIMove,
            mover: stateAfterAIMove.currentPlayer,
            scanLimit: responseScanLimit
        )
        guard let response else {
            return (nil, nil)
        }
        guard tacticalModeEnabled || aiStrength == .strong else {
            return (response, nil)
        }

        guard let afterResponse = simulateMove(
            row: response.row,
            col: response.col,
            state: stateAfterAIMove
        ) else {
            return (response, nil)
        }
        let followUp = previewStrategyMove(
            in: afterResponse,
            mover: aiStone,
            scanLimit: followUpScanLimit
        )
        return (response, followUp)
    }

    private func shouldPublishStrategyGhosts(
        currentMove: (row: Int, col: Int),
        bestMove: (row: Int, col: Int)?
    ) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let minInterval: TimeInterval
        if isAIThinking {
            switch aiStrength {
            case .fast:
                minInterval = 1.0 / 8.0
            case .normal:
                minInterval = 1.0 / 6.0
            case .strong:
                minInterval = 1.0 / 4.0
            }
        } else {
            switch aiStrength {
            case .fast:
                minInterval = 1.0 / 12.0
            case .normal:
                minInterval = 1.0 / 10.0
            case .strong:
                minInterval = 1.0 / 8.0
            }
        }

        strategyGhostPublishLock.lock()
        defer { strategyGhostPublishLock.unlock() }

        let moveChanged =
            strategyGhostLastCurrent?.row != currentMove.row ||
            strategyGhostLastCurrent?.col != currentMove.col ||
            strategyGhostLastBest?.row != bestMove?.row ||
            strategyGhostLastBest?.col != bestMove?.col

        if !moveChanged {
            return false
        }

        let firstPublish = strategyGhostLastPublishUptime == 0
        let enoughTimeElapsed = (now - strategyGhostLastPublishUptime) >= minInterval
        guard firstPublish || enoughTimeElapsed else {
            return false
        }

        strategyGhostLastCurrent = currentMove
        strategyGhostLastBest = bestMove
        strategyGhostLastPublishUptime = now
        return true
    }

    private func publishContemplatedMove(
        currentMove: CandidateMove,
        bestMove: (Int, Int)?,
        stone: Stone,
        token: Int,
        includePreviewLine: Bool = true
    ) {
        guard showStrategyEnabled else { return }
        let current = (row: currentMove.row, col: currentMove.col)
        let bestTuple = bestMove.map { (row: $0.0, col: $0.1) }
        guard shouldPublishStrategyGhosts(currentMove: current, bestMove: bestTuple) else { return }
        let preview = includePreviewLine
            ? previewStrategyLine(from: currentMove.stateAfterMove, aiStone: stone)
            : (opponentResponse: nil, aiFollowUp: nil)

        var ghosts: [StrategyGhostStone] = [
            StrategyGhostStone(
                row: currentMove.row,
                col: currentMove.col,
                stone: stone,
                kind: .current
            )
        ]
        if let bestMove {
            ghosts.append(
                StrategyGhostStone(
                    row: bestMove.0,
                    col: bestMove.1,
                    stone: stone,
                    kind: .best
                )
            )
        }
        if let response = preview.opponentResponse {
            ghosts.append(
                StrategyGhostStone(
                    row: response.row,
                    col: response.col,
                    stone: stone.opposite,
                    kind: .opponentResponse
                )
            )
        }
        if let followUp = preview.aiFollowUp {
            ghosts.append(
                StrategyGhostStone(
                    row: followUp.row,
                    col: followUp.col,
                    stone: stone,
                    kind: .aiFollowUp
                )
            )
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.showStrategyEnabled else { return }
            guard token == self.activeStrategyToken else { return }
            self.strategyGhosts = ghosts
        }
    }

    private func publishContemplatedMoveFast(
        currentMove: FastCandidateMove,
        bestMoveIndex: Int?,
        stone: Stone,
        token: Int,
        includePreviewLine: Bool = true
    ) {
        guard showStrategyEnabled else { return }
        let current = (row: currentMove.index / boardSize, col: currentMove.index % boardSize)
        let bestTuple = bestMoveIndex.map { (row: $0 / boardSize, col: $0 % boardSize) }
        guard shouldPublishStrategyGhosts(currentMove: current, bestMove: bestTuple) else { return }
        let preview = includePreviewLine
            ? previewStrategyLineFast(from: currentMove.stateAfterMove, aiStone: stone)
            : (opponentResponse: nil, aiFollowUp: nil)

        var ghosts: [StrategyGhostStone] = [
            StrategyGhostStone(
                row: current.row,
                col: current.col,
                stone: stone,
                kind: .current
            )
        ]
        if let bestTuple {
            ghosts.append(
                StrategyGhostStone(
                    row: bestTuple.row,
                    col: bestTuple.col,
                    stone: stone,
                    kind: .best
                )
            )
        }
        if let responseIndex = preview.opponentResponse {
            ghosts.append(
                StrategyGhostStone(
                    row: responseIndex / boardSize,
                    col: responseIndex % boardSize,
                    stone: stone.opposite,
                    kind: .opponentResponse
                )
            )
        }
        if let followUpIndex = preview.aiFollowUp {
            ghosts.append(
                StrategyGhostStone(
                    row: followUpIndex / boardSize,
                    col: followUpIndex % boardSize,
                    stone: stone,
                    kind: .aiFollowUp
                )
            )
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.showStrategyEnabled else { return }
            guard token == self.activeStrategyToken else { return }
            self.strategyGhosts = ghosts
        }
    }

    private func saveFileURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("Go", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("last-game.json")
    }

    private func captureGroups(of stone: Stone, on position: inout [[Stone]]) -> Int {
        captureGroupsDetailed(of: stone, on: &position).count
    }

    private func captureGroupsDetailed(of stone: Stone, on position: inout [[Stone]]) -> [Point] {
        var removed: [Point] = []
        var visited = Set<Point>()

        for row in 0..<boardSize {
            for col in 0..<boardSize where position[row][col] == stone {
                let p = Point(row: row, col: col)
                if visited.contains(p) { continue }

                let group = groupAt(row: row, col: col, in: position, visited: &visited)
                let hasLiberty = group.contains { point in
                    neighbors(of: point).contains { n in
                        position[n.row][n.col] == .empty
                    }
                }

                if !hasLiberty {
                    removed.append(contentsOf: group)
                    for point in group {
                        position[point.row][point.col] = .empty
                    }
                }
            }
        }

        return removed
    }

    private func liberties(ofGroupAt row: Int, col: Int, in position: [[Stone]]) -> Set<Point> {
        guard position[row][col] != .empty else { return [] }

        var visited = Set<Point>()
        let group = groupAt(row: row, col: col, in: position, visited: &visited)

        var liberties = Set<Point>()
        for point in group {
            for neighbor in neighbors(of: point) where position[neighbor.row][neighbor.col] == .empty {
                liberties.insert(neighbor)
            }
        }

        return liberties
    }

    private func groupAt(row: Int, col: Int, in position: [[Stone]], visited: inout Set<Point>) -> [Point] {
        let color = position[row][col]
        guard color != .empty else { return [] }

        var stack = [Point(row: row, col: col)]
        var group: [Point] = []

        while let point = stack.popLast() {
            if visited.contains(point) { continue }
            visited.insert(point)
            group.append(point)

            for neighbor in neighbors(of: point) where position[neighbor.row][neighbor.col] == color {
                if !visited.contains(neighbor) {
                    stack.append(neighbor)
                }
            }
        }

        return group
    }

    private func neighbors(of point: Point) -> [Point] {
        neighborTable[(point.row * boardSize) + point.col]
    }

    private func rebuildNeighborTable() {
        var table: [[Point]] = Array(repeating: [], count: boardSize * boardSize)
        var indexTable: [[Int]] = Array(repeating: [], count: boardSize * boardSize)
        for row in 0..<boardSize {
            for col in 0..<boardSize {
                var result: [Point] = []
                var indexResult: [Int] = []
                if row > 0 { result.append(Point(row: row - 1, col: col)) }
                if row < boardSize - 1 { result.append(Point(row: row + 1, col: col)) }
                if col > 0 { result.append(Point(row: row, col: col - 1)) }
                if col < boardSize - 1 { result.append(Point(row: row, col: col + 1)) }
                for neighbor in result {
                    indexResult.append((neighbor.row * boardSize) + neighbor.col)
                }
                let idx = (row * boardSize) + col
                table[idx] = result
                indexTable[idx] = indexResult
            }
        }
        neighborTable = table
        neighborIndexTable = indexTable
        rebuildZobristTable()
    }

    private func updateTerritory() {
        let (black, white) = territory(on: board)
        territoryBlack = black
        territoryWhite = white
    }

    private func territory(on position: [[Stone]]) -> (Int, Int) {
        var visited = Set<Point>()
        var black = 0
        var white = 0

        for row in 0..<boardSize {
            for col in 0..<boardSize where position[row][col] == .empty {
                let start = Point(row: row, col: col)
                if visited.contains(start) { continue }

                let (region, bordersBlack, bordersWhite) = emptyRegion(
                    from: start,
                    in: position,
                    visited: &visited
                )

                if bordersBlack && !bordersWhite {
                    black += region.count
                } else if bordersWhite && !bordersBlack {
                    white += region.count
                }
            }
        }

        return (black, white)
    }

    private func emptyRegion(
        from start: Point,
        in position: [[Stone]],
        visited: inout Set<Point>
    ) -> ([Point], Bool, Bool) {
        var stack = [start]
        var region: [Point] = []
        var bordersBlack = false
        var bordersWhite = false

        while let point = stack.popLast() {
            if visited.contains(point) { continue }
            visited.insert(point)
            guard position[point.row][point.col] == .empty else { continue }
            region.append(point)

            for neighbor in neighbors(of: point) {
                let stone = position[neighbor.row][neighbor.col]
                switch stone {
                case .empty:
                    if !visited.contains(neighbor) {
                        stack.append(neighbor)
                    }
                case .black:
                    bordersBlack = true
                case .white:
                    bordersWhite = true
                }
            }
        }

        return (region, bordersBlack, bordersWhite)
    }

    private func isOwnEye(at point: Point, stone: Stone, in position: [[Stone]]) -> Bool {
        guard position[point.row][point.col] == .empty else { return false }
        for neighbor in neighbors(of: point) where position[neighbor.row][neighbor.col] != stone {
            return false
        }

        let diagonals = [
            Point(row: point.row - 1, col: point.col - 1),
            Point(row: point.row - 1, col: point.col + 1),
            Point(row: point.row + 1, col: point.col - 1),
            Point(row: point.row + 1, col: point.col + 1)
        ]
        var enemyDiagonals = 0
        var inBoundsDiagonals = 0
        for diag in diagonals where diag.row >= 0 && diag.row < boardSize && diag.col >= 0 && diag.col < boardSize {
            inBoundsDiagonals += 1
            if position[diag.row][diag.col] == stone.opposite {
                enemyDiagonals += 1
            }
        }
        if inBoundsDiagonals <= 2 {
            return enemyDiagonals == 0
        }
        return enemyDiagonals <= 1
    }

    private func deadShapeRiskPenalty(
        move: Point,
        stone: Stone,
        in position: [[Stone]],
        capturesGained: Int,
        enemyAtariAfter: Int
    ) -> Int {
        if capturesGained > 0 || enemyAtariAfter > 0 { return 0 }

        var visited = Set<Point>()
        let group = groupAt(row: move.row, col: move.col, in: position, visited: &visited)
        if group.isEmpty { return 0 }

        var liberties: Set<Point> = []
        for point in group {
            for neighbor in neighbors(of: point) where position[neighbor.row][neighbor.col] == .empty {
                liberties.insert(neighbor)
            }
        }
        let libertyCount = liberties.count
        if libertyCount >= 3 { return 0 }

        let eyePotential = liberties.reduce(into: 0) { total, liberty in
            if isOwnEye(at: liberty, stone: stone, in: position) { total += 1 }
        }

        if libertyCount <= 1 && eyePotential == 0 { return 900 }
        if libertyCount == 2 && eyePotential == 0 { return 360 }
        if libertyCount == 2 && eyePotential == 1 { return 140 }
        return 0
    }

    private func emptyRegionOwner(at start: Point, in position: [[Stone]]) -> Stone? {
        guard position[start.row][start.col] == .empty else { return nil }
        var visited = Set<Point>()
        let (_, bordersBlack, bordersWhite) = emptyRegion(from: start, in: position, visited: &visited)
        if bordersBlack && !bordersWhite { return .black }
        if bordersWhite && !bordersBlack { return .white }
        return nil
    }

    private func emptyRegionOwners(in position: [[Stone]]) -> [[Stone?]] {
        var owners = Array(repeating: Array<Stone?>(repeating: nil, count: boardSize), count: boardSize)
        var visited = Array(repeating: Array(repeating: false, count: boardSize), count: boardSize)

        for row in 0..<boardSize {
            for col in 0..<boardSize where position[row][col] == .empty && !visited[row][col] {
                let start = Point(row: row, col: col)
                var stack: [Point] = [start]
                var region: [Point] = []
                var bordersBlack = false
                var bordersWhite = false

                while let point = stack.popLast() {
                    if visited[point.row][point.col] { continue }
                    visited[point.row][point.col] = true
                    guard position[point.row][point.col] == .empty else { continue }
                    region.append(point)

                    for neighbor in neighbors(of: point) {
                        let stone = position[neighbor.row][neighbor.col]
                        switch stone {
                        case .empty:
                            if !visited[neighbor.row][neighbor.col] {
                                stack.append(neighbor)
                            }
                        case .black:
                            bordersBlack = true
                        case .white:
                            bordersWhite = true
                        }
                    }
                }

                let owner: Stone?
                if bordersBlack && !bordersWhite {
                    owner = .black
                } else if bordersWhite && !bordersBlack {
                    owner = .white
                } else {
                    owner = nil
                }

                for point in region {
                    owners[point.row][point.col] = owner
                }
            }
        }

        return owners
    }

    private func hash(for position: [[Stone]]) -> UInt64 {
        var value = zobristBoardSalt
        for row in 0..<boardSize {
            for col in 0..<boardSize {
                switch position[row][col] {
                case .black:
                    value ^= zobristValue(for: .black, row: row, col: col)
                case .white:
                    value ^= zobristValue(for: .white, row: row, col: col)
                case .empty:
                    break
                }
            }
        }
        return value
    }

    private func hash(forFastBoard board: [UInt8]) -> UInt64 {
        var value = zobristBoardSalt
        for index in board.indices {
            switch board[index] {
            case 1:
                value ^= zobristBlack[index]
            case 2:
                value ^= zobristWhite[index]
            default:
                break
            }
        }
        return value
    }

    private func boardFingerprint(for position: [[Stone]]) -> Int {
        Int(truncatingIfNeeded: hash(for: position))
    }

    private func rebuildZobristTable() {
        let cellCount = boardSize * boardSize
        var generator = SplitMix64(state: UInt64(0x9E3779B97F4A7C15) ^ UInt64(boardSize &* 0x1009))
        zobristBoardSalt = generator.next()
        zobristBlack = Array(repeating: 0, count: cellCount)
        zobristWhite = Array(repeating: 0, count: cellCount)
        for index in 0..<cellCount {
            zobristBlack[index] = generator.next()
            zobristWhite[index] = generator.next()
        }
    }

    private func zobristValue(for stone: Stone, row: Int, col: Int) -> UInt64 {
        let index = (row * boardSize) + col
        switch stone {
        case .black:
            return zobristBlack[index]
        case .white:
            return zobristWhite[index]
        case .empty:
            return 0
        }
    }

    private func zobristValue(forStoneCode code: UInt8, at index: Int) -> UInt64 {
        switch code {
        case 1:
            return zobristBlack[index]
        case 2:
            return zobristWhite[index]
        default:
            return 0
        }
    }

    private func encodeHashString(_ value: UInt64?) -> String? {
        guard let value else { return nil }
        return String(value, radix: 16)
    }

    private func decodeHashString(_ value: String?) -> UInt64? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("0x") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed, radix: 16)
    }

    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func shortLabel(for stone: Stone) -> String {
        stone == .black ? "B" : "W"
    }

    private func label(for stone: Stone) -> String {
        stone == .black ? "Black" : "White"
    }

    private func coordinateLabel(row: Int, col: Int) -> String {
        let columns = Array("ABCDEFGHJKLMNOPQRST")
        let colLabel: String
        if col < columns.count {
            colLabel = String(columns[col])
        } else {
            colLabel = "C\(col + 1)"
        }

        return "\(colLabel)\(boardSize - row)"
    }

    private func startTurnTicker() {
        turnTicker?.invalidate()
        turnTicker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refreshCurrentTurnElapsed()
        }
    }

    private func refreshCurrentTurnElapsed() {
        guard !gameOver else {
            currentTurnElapsed = 0
            return
        }
        guard !isAIPaused else { return }
        guard let turnStartDate else {
            currentTurnElapsed = 0
            return
        }
        currentTurnElapsed = max(0, Date().timeIntervalSince(turnStartDate))
    }

    private func commitCurrentTurnTime(for stone: Stone) {
        refreshCurrentTurnElapsed()
        pausedAt = nil
        let elapsed = currentTurnElapsed
        guard elapsed > 0 else { return }

        if stone == .black {
            totalTimeBlack += elapsed
        } else {
            totalTimeWhite += elapsed
        }
        currentTurnElapsed = 0
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let rounded = Int(interval.rounded())
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let seconds = rounded % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
