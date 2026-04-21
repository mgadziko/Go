import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var game: GoGameViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button("New Game") {
                    game.newGame()
                }
                .fixedSize(horizontal: true, vertical: false)

                Button("Save") {
                    _ = game.saveGameToDisk()
                }
                .fixedSize(horizontal: true, vertical: false)

                Button("Load") {
                    _ = game.loadGameFromDisk()
                }
                .fixedSize(horizontal: true, vertical: false)

                Button("Pass") {
                    game.passTurn()
                }
                .disabled(!game.isHumanTurn() || game.gameOver)
                .fixedSize(horizontal: true, vertical: false)

                Button("Undo") {
                    game.undoMove()
                }
                .disabled(game.moveHistory.count <= 1)
                .fixedSize(horizontal: true, vertical: false)

                Button(game.isAIPaused ? "Resume AI" : "Pause AI") {
                    game.toggleAIPause()
                }
                .disabled(!game.canPauseAI() && !game.isAIPaused)
                .fixedSize(horizontal: true, vertical: false)

#if DEBUG
                Button("Ko Self-Test") {
                    game.runKoRegressionHarness()
                }
                .fixedSize(horizontal: true, vertical: false)
#endif
            }

            HStack(spacing: 16) {
                Picker("Board Size", selection: $game.boardSize) {
                    Text("9x9").tag(9)
                    Text("18x18").tag(18)
                }
                .frame(width: 130)

                Picker("Black", selection: $game.blackPlayer) {
                    ForEach(PlayerType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .frame(width: 140)

                Picker("White", selection: $game.whitePlayer) {
                    ForEach(PlayerType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .frame(width: 140)

                Picker("AI Strength", selection: $game.aiStrength) {
                    ForEach(AIStrength.allCases) { strength in
                        Text(strength.rawValue).tag(strength)
                    }
                }
                .frame(width: 160)

                Picker("Capture Reading", selection: $game.captureReadingStrength) {
                    ForEach(CaptureReadingStrength.allCases) { strength in
                        Text(strength.rawValue).tag(strength)
                    }
                }
                .frame(width: 210)

            }

            HStack(spacing: 20) {
                Toggle("Show AI Strategy", isOn: $game.showStrategyEnabled)
                    .toggleStyle(.switch)
                    .fixedSize(horizontal: true, vertical: false)

                Toggle("Deeper Tactics", isOn: $game.tacticalModeEnabled)
                    .toggleStyle(.switch)
                    .fixedSize(horizontal: true, vertical: false)

                Toggle("Joseki Boost", isOn: $game.josekiBookEnabled)
                    .toggleStyle(.switch)
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 24) {
                Label("Black captures: \(game.capturesBlack)", systemImage: "circle.fill")
                Label("White captures: \(game.capturesWhite)", systemImage: "circle.fill")
                Text("Black territory: \(game.territoryBlack)")
                Text("White territory: \(game.territoryWhite)")
            }

            HStack(spacing: 24) {
                Text("Black time: \(game.formattedTotalTime(for: .black))")
                Text("White time: \(game.formattedTotalTime(for: .white))")
                Text("Turn time: \(game.formattedCurrentTurnTime())")
                Text(game.gameOver
                     ? "Game over"
                     : "\(game.currentPlayer == .black ? "Black's" : "White's") turn")
                if game.isAIThinking && !game.isAIPaused {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("AI thinking...")
                    }
                }
            }

            if game.statusMessage != "Black to move" && game.statusMessage != "White to move" {
                Text(game.statusMessage)
                    .font(.headline)
            }
            
            if let blackScore = game.finalBlackScore, let whiteScore = game.finalWhiteScore {
                HStack(spacing: 24) {
                    Text("Final Black: \(blackScore, specifier: "%.1f")")
                    Text("Final White: \(whiteScore, specifier: "%.1f") (includes 6.5 komi)")
                }
                .font(.headline)
            }

            GroupBox("History") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(game.moveHistory.enumerated()), id: \.offset) { index, entry in
                            Text("\(index). \(entry)")
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }

            GoBoardView(
                board: game.board,
                strategyGhosts: game.showStrategyEnabled ? game.strategyGhosts : [],
                lastMoveRow: game.lastMoveRow,
                lastMoveCol: game.lastMoveCol
            ) { row, col in
                game.playHuman(row: row, col: col)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
    }
}

private struct GoBoardView: View {
    let board: [[Stone]]
    var strategyGhosts: [StrategyGhostStone] = []
    var lastMoveRow: Int?
    var lastMoveCol: Int?
    var onTap: (Int, Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let boardSize = board.count
            let margin = max(22.0, size * 0.06)
            let step = (size - (margin * 2)) / CGFloat(boardSize - 1)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.91, green: 0.78, blue: 0.52))
                    .shadow(radius: 2)

                Path { path in
                    for index in 0..<boardSize {
                        let x = margin + CGFloat(index) * step
                        path.move(to: CGPoint(x: x, y: margin))
                        path.addLine(to: CGPoint(x: x, y: size - margin))

                        let y = margin + CGFloat(index) * step
                        path.move(to: CGPoint(x: margin, y: y))
                        path.addLine(to: CGPoint(x: size - margin, y: y))
                    }
                }
                .stroke(.black.opacity(0.85), lineWidth: 1.2)

                ForEach(0..<boardSize, id: \ .self) { row in
                    ForEach(0..<boardSize, id: \ .self) { col in
                        if board[row][col] != .empty {
                            Circle()
                                .fill(board[row][col] == .black ? .black : .white)
                                .overlay {
                                    ZStack {
                                        Circle().stroke(.black.opacity(0.3), lineWidth: 1)
                                        if row == lastMoveRow, col == lastMoveCol {
                                            Circle()
                                                .fill(Color.red)
                                                .frame(width: step * 0.18, height: step * 0.18)
                                        }
                                    }
                                }
                                .frame(width: step * 0.82, height: step * 0.82)
                                .position(
                                    x: margin + CGFloat(col) * step,
                                    y: margin + CGFloat(row) * step
                                )
                                .shadow(radius: board[row][col] == .black ? 2 : 1)
                        }
                    }
                }

                ForEach(strategyGhosts) { ghost in
                    let fillOpacity: Double = {
                        switch ghost.kind {
                        case .current:
                            return ghost.stone == .black ? 0.32 : 0.40
                        case .best:
                            return ghost.stone == .black ? 0.60 : 0.70
                        case .opponentResponse:
                            return ghost.stone == .black ? 0.44 : 0.56
                        case .aiFollowUp:
                            return ghost.stone == .black ? 0.28 : 0.36
                        }
                    }()
                    let strokeColor: Color = {
                        switch ghost.kind {
                        case .current:
                            return Color.blue.opacity(0.7)
                        case .best:
                            return Color.green.opacity(0.9)
                        case .opponentResponse:
                            return Color.orange.opacity(0.9)
                        case .aiFollowUp:
                            return Color.cyan.opacity(0.9)
                        }
                    }()
                    let strokeWidth: CGFloat = {
                        switch ghost.kind {
                        case .best:
                            return 2.0
                        case .opponentResponse:
                            return 1.7
                        case .aiFollowUp:
                            return 1.5
                        case .current:
                            return 1.2
                        }
                    }()
                    let sizeFactor: CGFloat = {
                        switch ghost.kind {
                        case .aiFollowUp:
                            return 0.72
                        default:
                            return 0.78
                        }
                    }()
                    Circle()
                        .fill(ghost.stone == .black ? .black.opacity(fillOpacity) : .white.opacity(fillOpacity))
                        .overlay {
                            Circle()
                                .stroke(strokeColor, lineWidth: strokeWidth)
                        }
                        .frame(width: step * sizeFactor, height: step * sizeFactor)
                        .position(
                            x: margin + CGFloat(ghost.col) * step,
                            y: margin + CGFloat(ghost.row) * step
                        )
                }
            }
            .frame(width: size, height: size)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let local = value.location
                        let row = Int(round((local.y - margin) / step))
                        let col = Int(round((local.x - margin) / step))
                        guard row >= 0, row < boardSize, col >= 0, col < boardSize else { return }
                        onTap(row, col)
                    }
            )
        }
    }
}
