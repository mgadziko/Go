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

private struct Point: Hashable {
    let row: Int
    let col: Int
}

private struct SimState {
    var board: [[Stone]]
    var currentPlayer: Stone
    var capturesBlack: Int
    var capturesWhite: Int
    var previousBoardHash: String?
    var consecutivePasses: Int
}

private struct CandidateMove {
    let row: Int
    let col: Int
    let immediateScore: Int
    let stateAfterMove: SimState
}

private struct StaticEvalKey: Hashable {
    let boardFingerprint: Int
    let capturesBlack: Int
    let capturesWhite: Int
    let perspective: Stone
}

private final class SearchEvalCache {
    private let lock = NSLock()
    private var staticScores: [StaticEvalKey: Double] = [:]

    func value(for key: StaticEvalKey) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return staticScores[key]
    }

    func store(_ value: Double, for key: StaticEvalKey) {
        lock.lock()
        staticScores[key] = value
        lock.unlock()
    }
}

final class GoGameViewModel: ObservableObject {
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

    private var previousBoardHash: String?
    private var consecutivePasses = 0
    private var historyStack: [Snapshot] = []
    private var neighborTable: [[Point]] = []

    private struct SavedGame: Codable {
        let boardSize: Int
        let blackPlayer: PlayerType
        let whitePlayer: PlayerType
        let aiStrength: AIStrength
        let tacticalModeEnabled: Bool?
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
        let previousBoardHash: String?
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
        let previousBoardHash: String?
        let consecutivePasses: Int
        let moveHistory: [String]
        let currentTurnElapsed: TimeInterval
        let totalTimeBlack: TimeInterval
        let totalTimeWhite: TimeInterval
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
        previousBoardHash = hash(for: board)
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
                previousBoardHash: previousBoardHash,
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
        isAIThinking = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let move = self.bestMove(for: stone)

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

        let captured = captureGroups(of: mover.opposite, on: &next)

        if liberties(ofGroupAt: row, col: col, in: next).isEmpty {
            statusMessage = "Illegal move: suicide"
            return false
        }

        let nextHash = hash(for: next)
        if let previousBoardHash, previousBoardHash == nextHash {
            statusMessage = "Illegal move: ko"
            return false
        }

        board = next
        commitCurrentTurnTime(for: mover)
        if mover == .black {
            capturesBlack += captured
        } else {
            capturesWhite += captured
        }

        updateTerritory()
        consecutivePasses = 0
        previousBoardHash = nextHash
        currentPlayer = mover.opposite
        turnStartDate = Date()
        currentTurnElapsed = 0

        moveHistory.append("\(shortLabel(for: mover)) \(coordinateLabel(row: row, col: col))")
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

    private func bestMove(for stone: Stone) -> (Int, Int)? {
        let root = SimState(
            board: board,
            currentPlayer: stone,
            capturesBlack: capturesBlack,
            capturesWhite: capturesWhite,
            previousBoardHash: previousBoardHash,
            consecutivePasses: consecutivePasses
        )

        let candidateLimit: Int
        switch aiStrength {
        case .fast:
            candidateLimit = boardSize <= 9 ? 18 : 10
        case .normal:
            candidateLimit = boardSize <= 9 ? 28 : 16
        case .strong:
            candidateLimit = boardSize <= 9 ? 32 : 20
        }

        let candidates = monteCarloCandidates(for: stone, from: root, maxCandidates: candidateLimit)
        guard !candidates.isEmpty else { return nil }

        let baseSimulationsPerMove = boardSize <= 9 ? 36 : 14
        let baseRolloutDepth = boardSize <= 9 ? 120 : 180
        let simulationsPerMove: Int
        let rolloutDepth: Int
        let tacticalWeight: Double
        let runTacticalLookahead: Bool
        switch aiStrength {
        case .fast:
            simulationsPerMove = max(6, baseSimulationsPerMove / 2)
            rolloutDepth = max(60, baseRolloutDepth / 2)
            tacticalWeight = 0
            runTacticalLookahead = false
        case .normal:
            simulationsPerMove = baseSimulationsPerMove
            rolloutDepth = baseRolloutDepth
            tacticalWeight = tacticalModeEnabled ? 0.7 : 0.5
            runTacticalLookahead = true
        case .strong:
            simulationsPerMove = baseSimulationsPerMove * 2
            rolloutDepth = baseRolloutDepth + (boardSize <= 9 ? 80 : 120)
            tacticalWeight = tacticalModeEnabled ? 0.85 : 0.7
            runTacticalLookahead = true
        }

        let evalCache = SearchEvalCache()
        var best: (move: (Int, Int), score: Double)?
        let cpuCores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let shouldParallelizeCandidates =
            aiStrength != .fast &&
            candidates.count >= 6 &&
            simulationsPerMove >= 12
        let shouldParallelizeRollouts =
            aiStrength != .fast &&
            !shouldParallelizeCandidates &&
            simulationsPerMove >= 24 &&
            cpuCores >= 4

        func combinedScore(for candidate: CandidateMove) -> Double {
            let totalScore: Double
            if shouldParallelizeRollouts {
                let workerCount = min(cpuCores, simulationsPerMove)
                let totalLock = NSLock()
                var aggregate = 0.0

                DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                    var subtotal = 0.0
                    var simIndex = worker
                    while simIndex < simulationsPerMove {
                        subtotal += runRandomPlayout(
                            from: candidate.stateAfterMove,
                            perspective: stone,
                            maxSteps: rolloutDepth
                        )
                        simIndex += workerCount
                    }
                    totalLock.lock()
                    aggregate += subtotal
                    totalLock.unlock()
                }
                totalScore = aggregate
            } else {
                var sequentialTotal = 0.0
                for _ in 0..<simulationsPerMove {
                    sequentialTotal += runRandomPlayout(
                        from: candidate.stateAfterMove,
                        perspective: stone,
                        maxSteps: rolloutDepth
                    )
                }
                totalScore = sequentialTotal
            }

            let average = totalScore / Double(simulationsPerMove)
            let tacticalLookahead = runTacticalLookahead
                ? tacticalReplySwing(for: candidate, perspective: stone, cache: evalCache)
                : 0
            let combined =
                average +
                (Double(candidate.immediateScore) * 0.018) +
                (tacticalLookahead * tacticalWeight)
            return combined
        }

        if shouldParallelizeCandidates {
            let bestLock = NSLock()
            DispatchQueue.concurrentPerform(iterations: candidates.count) { idx in
                let candidate = candidates[idx]
                let combined = combinedScore(for: candidate)
                bestLock.lock()
                defer { bestLock.unlock() }
                if let best, combined <= best.score {
                    return
                }
                best = ((candidate.row, candidate.col), combined)
            }
        } else {
            for candidate in candidates {
                let combined = combinedScore(for: candidate)
                if let best, combined <= best.score {
                    continue
                }
                best = ((candidate.row, candidate.col), combined)
            }
        }

        return best?.move
    }

    private func monteCarloCandidates(
        for stone: Stone,
        from root: SimState,
        maxCandidates: Int? = nil
    ) -> [CandidateMove] {
        var scored: [CandidateMove] = []

        for point in preferredEmptyPoints(in: root.board) {
            guard let simulated = simulateMove(row: point.row, col: point.col, state: root) else {
                continue
            }

            let immediate = immediateHeuristic(
                from: root,
                to: simulated,
                move: point,
                for: stone
            )
            scored.append(
                CandidateMove(
                    row: point.row,
                    col: point.col,
                    immediateScore: immediate,
                    stateAfterMove: simulated
                )
            )
        }

        scored.sort { $0.immediateScore > $1.immediateScore }

        let resolvedMaxCandidates = maxCandidates ?? (boardSize <= 9 ? 28 : 16)
        guard scored.count > resolvedMaxCandidates else { return scored }

        let headCount = resolvedMaxCandidates / 2
        var chosen = Array(scored.prefix(headCount))
        var tailPool = Array(scored.dropFirst(headCount))

        while chosen.count < resolvedMaxCandidates, !tailPool.isEmpty {
            let randomIndex = Int.random(in: 0..<tailPool.count)
            chosen.append(tailPool.remove(at: randomIndex))
        }

        return chosen
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

    private func immediateHeuristic(from root: SimState, to next: SimState, move: Point, for stone: Stone) -> Int {
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
        let center = Double(boardSize - 1) / 2.0
        let distanceFromCenter = abs(Double(move.row) - center) + abs(Double(move.col) - center)
        let centerBonus = Int((Double(boardSize) - distanceFromCenter).rounded())
        let shapeBonus = ownLiberties >= 4 ? 8 : 0

        // Strongly avoid self-atari unless it captures something meaningful.
        if ownLiberties <= 1 && capturesGained == 0 {
            return -1200
        }

        let ownLibertyPenalty = ownLiberties == 2 ? -22 : 0

        return
            capturesGained * 160 +
            ownAtariBefore * 85 +
            enemyAtariAfter * 22 +
            ownLiberties * 6 +
            centerBonus +
            shapeBonus +
            ownLibertyPenalty -
            (opponentCaptureThreat * 130) +
            Int.random(in: 0...2)
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
        var sim = state
        var steps = 0

        while steps < maxSteps, sim.consecutivePasses < 2 {
            if let move = randomLegalMove(in: sim) {
                _ = applySimMove(row: move.row, col: move.col, to: &sim)
            } else {
                applyPass(to: &sim)
            }
            steps += 1
        }

        let (blackTerritory, whiteTerritory) = territory(on: sim.board)
        let blackScore = Double(blackTerritory + sim.capturesBlack)
        let whiteScore = Double(whiteTerritory + sim.capturesWhite) + whiteKomi

        if perspective == .black {
            return blackScore - whiteScore
        }
        return whiteScore - blackScore
    }

    private func randomLegalMove(in state: SimState) -> Point? {
        let points = preferredEmptyPoints(in: state.board)
        if points.isEmpty { return nil }

        var topPool: [(point: Point, score: Int)] = []
        let scanLimit = min(points.count, boardSize <= 9 ? 80 : 52)
        let poolLimit = 8

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
            let selfAtariPenalty = (ownLiberties <= 1 && capturesGained == 0) ? 500 : 0
            let thinPenalty = ownLiberties == 2 ? 14 : 0
            let score =
                capturesGained * 120 +
                ownLiberties * 5 -
                selfAtariPenalty -
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

        let captured = captureGroups(of: mover.opposite, on: &nextBoard)
        if liberties(ofGroupAt: row, col: col, in: nextBoard).isEmpty {
            return false
        }

        let nextHash = hash(for: nextBoard)
        if let previousBoardHash = state.previousBoardHash, previousBoardHash == nextHash {
            return false
        }

        state.board = nextBoard
        state.previousBoardHash = nextHash
        state.consecutivePasses = 0

        if mover == .black {
            state.capturesBlack += captured
        } else {
            state.capturesWhite += captured
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
            previousBoardHash: previousBoardHash,
            consecutivePasses: consecutivePasses,
            moveHistory: moveHistory,
            currentTurnElapsed: currentTurnElapsed,
            totalTimeBlack: totalTimeBlack,
            totalTimeWhite: totalTimeWhite
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
        previousBoardHash = snapshot.previousBoardHash
        consecutivePasses = snapshot.consecutivePasses
        moveHistory = snapshot.moveHistory
        currentTurnElapsed = snapshot.currentTurnElapsed
        totalTimeBlack = snapshot.totalTimeBlack
        totalTimeWhite = snapshot.totalTimeWhite
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
        previousBoardHash = savedGame.previousBoardHash
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
        var removed = 0
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
                    removed += group.count
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
        for row in 0..<boardSize {
            for col in 0..<boardSize {
                var result: [Point] = []
                if row > 0 { result.append(Point(row: row - 1, col: col)) }
                if row < boardSize - 1 { result.append(Point(row: row + 1, col: col)) }
                if col > 0 { result.append(Point(row: row, col: col - 1)) }
                if col < boardSize - 1 { result.append(Point(row: row, col: col + 1)) }
                table[(row * boardSize) + col] = result
            }
        }
        neighborTable = table
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

    private func hash(for position: [[Stone]]) -> String {
        position
            .flatMap { $0 }
            .map { $0.rawValue }
            .joined(separator: "|")
    }

    private func boardFingerprint(for position: [[Stone]]) -> Int {
        var hasher = Hasher()
        hasher.combine(boardSize)
        for row in position {
            for stone in row {
                switch stone {
                case .empty:
                    hasher.combine(0)
                case .black:
                    hasher.combine(1)
                case .white:
                    hasher.combine(2)
                }
            }
        }
        return hasher.finalize()
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
