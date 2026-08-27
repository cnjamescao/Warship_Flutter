import 'package:flutter/material.dart';
import 'package:flame/game.dart';

import 'game/warship_game.dart';

void main() {
  runApp(const WarshipApp());
}

class WarshipApp extends StatelessWidget {
  const WarshipApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Warship',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const GameScreen(),
    );
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late final WarshipGame _game;

  static const _hudStyle = TextStyle(
    color: Colors.black87,
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );

  @override
  void initState() {
    super.initState();
    _game = WarshipGame();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE6E6E6),
      body: SizedBox.expand(
        child: Stack(
          children: [
            Positioned.fill(
              child: GameWidget(game: _game),
            ),
            _buildHud(),
            Positioned.fill(
              child: _buildOverlay(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHud() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<int>(
              valueListenable: _game.livesNotifier,
              builder: (context, lives, _) {
                return Text('Ships: $lives', style: _hudStyle);
              },
            ),
            ValueListenableBuilder<int>(
              valueListenable: _game.highScoreNotifier,
              builder: (context, highScore, _) {
                return Text('High Score: $highScore', style: _hudStyle);
              },
            ),
            ValueListenableBuilder<int>(
              valueListenable: _game.scoreNotifier,
              builder: (context, score, _) {
                return Text('Score: $score', style: _hudStyle);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverlay() {
    return ValueListenableBuilder<GameState>(
      valueListenable: _game.stateNotifier,
      builder: (context, state, _) {
        if (state == GameState.playing) {
          return const SizedBox.shrink();
        }

        final isMenu = state == GameState.menu;

        return Container(
          color: Colors.black45,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isMenu ? 'Alien Invasion' : 'Game Over',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 42,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (!isMenu) ...[
                const SizedBox(height: 12),
                ValueListenableBuilder<int>(
                  valueListenable: _game.scoreNotifier,
                  builder: (context, score, _) {
                    return Text(
                      'Score: $score',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _game.startNewGame,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Text(
                    isMenu ? 'Play' : 'Play Again',
                    style: const TextStyle(fontSize: 20),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
