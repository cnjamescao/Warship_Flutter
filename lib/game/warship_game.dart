import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum GameState { menu, playing, gameOver }

class WarshipGame extends FlameGame with KeyboardEvents {
  WarshipGame();

  final ValueNotifier<int> scoreNotifier = ValueNotifier<int>(0);
  final ValueNotifier<int> highScoreNotifier = ValueNotifier<int>(0);
  final ValueNotifier<int> livesNotifier = ValueNotifier<int>(3);
  final ValueNotifier<GameState> stateNotifier =
      ValueNotifier<GameState>(GameState.menu);

  static const double _shipSpeed = 420;
  static const double _bulletSpeed = 520;
  static const double _baseAlienSpeed = 90;
  static const double _alienDropSpeed = 30;
  static const int _alienPoints = 50;
  static const double _shipWidth = 64;
  static const double _shipHeight = 48;
  static const double _alienWidth = 48;
  static const double _alienHeight = 40;

  late Sprite _shipSprite;
  late Sprite _alienSprite;
  late PlayerShip _ship;
  RectangleComponent? _background;
  final List<AlienEnemy> _aliens = <AlienEnemy>[];
  final List<Bullet> _bullets = <Bullet>[];

  int _score = 0;
  int _highScore = 0;
  int _lives = 3;
  GameState _state = GameState.menu;

  double _alienSpeed = _baseAlienSpeed;
  double _alienDirection = 1;
  double _shootCooldown = 0;

  bool _leftPressed = false;
  bool _rightPressed = false;
  bool _spacePressed = false;

  bool _spritesLoaded = false;
  bool _layoutReady = false;
  bool _initialized = false;
  bool _uiSyncScheduled = false;

  @override
  Future<void> onLoad() async {
    _shipSprite = await Sprite.load('ship.png');
    _alienSprite = await Sprite.load('alien.png');

    _ship = PlayerShip(
      sprite: _shipSprite,
      size: Vector2(_shipWidth, _shipHeight),
    );
    add(_ship);

    _spritesLoaded = true;
    _tryInitialize();
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);

    if (_background == null) {
      _background = RectangleComponent(
        size: size,
        paint: Paint()..color = const Color(0xFFE6E6E6),
        priority: -1000,
      );
      add(_background!);
    } else {
      _background!.size = size;
    }

    if (size.x > 0 && size.y > 0) {
      _layoutReady = true;
      _tryInitialize();
    }
  }

  void _tryInitialize() {
    if (_initialized || !_spritesLoaded || !_layoutReady) {
      return;
    }

    _initialized = true;
    _resetShip();
    _createFleet();
  }

  void startNewGame() {
    _score = 0;
    _lives = 3;
    _alienSpeed = _baseAlienSpeed;
    _alienDirection = 1;
    _shootCooldown = 0;
    _leftPressed = false;
    _rightPressed = false;
    _spacePressed = false;

    if (_initialized) {
      _clearAliensAndBullets();
      _resetShip();
      _createFleet();
    }

    _state = GameState.playing;
    _markUiDirty();
  }

  @override
  KeyEventResult onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  ) {
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyA) {
      _leftPressed = event is KeyDownEvent;
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyD) {
      _rightPressed = event is KeyDownEvent;
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.space) {
      _spacePressed = event is KeyDownEvent;
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  void update(double dt) {
    super.update(dt);

    if (_state != GameState.playing || !_initialized) {
      return;
    }

    if (size.x <= 0 || size.y <= 0) {
      return;
    }

    if (_leftPressed) {
      _ship.x -= _shipSpeed * dt;
    }
    if (_rightPressed) {
      _ship.x += _shipSpeed * dt;
    }
    _ship.x = _ship.x.clamp(0.0, size.x - _ship.width);

    _shootCooldown -= dt;
    if (_spacePressed && _shootCooldown <= 0) {
      _spawnBullet();
      _shootCooldown = 0.28;
    }

    _updateBullets(dt);
    _updateAliens(dt);
    _checkCollisions();
  }

  void _spawnBullet() {
    final bullet = Bullet(
      Vector2(_ship.x + _ship.width / 2 - 2, _ship.y - 12),
    );
    _bullets.add(bullet);
    add(bullet);
  }

  void _updateBullets(double dt) {
    final toRemove = <Bullet>[];

    for (final bullet in _bullets) {
      bullet.y -= _bulletSpeed * dt;
      if (bullet.y < -bullet.height) {
        toRemove.add(bullet);
      }
    }

    for (final bullet in toRemove) {
      bullet.removeFromParent();
      _bullets.remove(bullet);
    }
  }

  void _updateAliens(double dt) {
    for (final alien in _aliens) {
      alien.x += _alienSpeed * _alienDirection * dt;
    }

    var changeDirection = false;
    for (final alien in _aliens) {
      if (alien.x <= 0 || alien.x + alien.width >= size.x) {
        changeDirection = true;
        break;
      }
    }

    if (changeDirection) {
      _alienDirection *= -1;
      for (final alien in _aliens) {
        alien.y += _alienDropSpeed;
      }
    }
  }

  void _checkCollisions() {
    final aliensToRemove = <AlienEnemy>[];
    final bulletsToRemove = <Bullet>[];

    for (final bullet in _bullets) {
      for (final alien in _aliens) {
        if (_overlaps(bullet, alien)) {
          bulletsToRemove.add(bullet);
          aliensToRemove.add(alien);
          break;
        }
      }
    }

    for (final bullet in bulletsToRemove) {
      bullet.removeFromParent();
      _bullets.remove(bullet);
    }

    for (final alien in aliensToRemove) {
      alien.removeFromParent();
      _aliens.remove(alien);
    }

    if (aliensToRemove.isNotEmpty) {
      _score += _alienPoints * aliensToRemove.length;
      if (_score > _highScore) {
        _highScore = _score;
      }
      _markUiDirty();
    }

    if (_aliens.isEmpty) {
      _alienSpeed += 10;
      _createFleet();
      return;
    }

    for (final alien in _aliens) {
      if (_overlaps(_ship, alien)) {
        _shipHit();
        return;
      }
    }

    for (final alien in _aliens) {
      if (alien.y + alien.height >= size.y) {
        _shipHit();
        return;
      }
    }
  }

  bool _overlaps(PositionComponent a, PositionComponent b) {
    return a.x < b.x + b.width &&
        a.x + a.width > b.x &&
        a.y < b.y + b.height &&
        a.y + a.height > b.y;
  }

  void _shipHit() {
    _lives -= 1;
    _markUiDirty();

    _clearAliensAndBullets();

    if (_lives > 0) {
      _resetShip();
      _createFleet();
    } else {
      _state = GameState.gameOver;
      _markUiDirty();
    }
  }

  void _clearAliensAndBullets() {
    for (final alien in _aliens) {
      alien.removeFromParent();
    }
    _aliens.clear();

    for (final bullet in _bullets) {
      bullet.removeFromParent();
    }
    _bullets.clear();
  }

  void _resetShip() {
    _ship.position = Vector2(
      (size.x - _ship.width) / 2,
      size.y - _ship.height - 20,
    );
  }

  void _createFleet() {
    final availableX = size.x - 2 * _alienWidth;
    final cols = math.max(1, (availableX / (2 * _alienWidth)).floor());

    final availableY = size.y - 3 * _alienHeight - _shipHeight - 20;
    final rows = math.max(1, (availableY / (2 * _alienHeight)).floor());

    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final x = _alienWidth + 2 * _alienWidth * col;
        final y = _alienHeight + 2 * _alienHeight * row;
        final alien = AlienEnemy(
          sprite: _alienSprite,
          position: Vector2(x, y),
          size: Vector2(_alienWidth, _alienHeight),
        );
        _aliens.add(alien);
        add(alien);
      }
    }
  }

  void _markUiDirty() {
    if (_uiSyncScheduled) {
      return;
    }
    _uiSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _uiSyncScheduled = false;
      scoreNotifier.value = _score;
      highScoreNotifier.value = _highScore;
      livesNotifier.value = _lives;
      stateNotifier.value = _state;
    });
  }
}

class PlayerShip extends SpriteComponent {
  PlayerShip({required Sprite sprite, required Vector2 size})
      : super(sprite: sprite, size: size, anchor: Anchor.topLeft);
}

class AlienEnemy extends SpriteComponent {
  AlienEnemy({
    required Sprite sprite,
    required Vector2 position,
    required Vector2 size,
  }) : super(sprite: sprite, position: position, size: size, anchor: Anchor.topLeft);
}

class Bullet extends RectangleComponent {
  Bullet(Vector2 position)
      : super(
          position: position,
          size: Vector2(4, 12),
          paint: Paint()..color = const Color(0xFF000000),
        );
}
