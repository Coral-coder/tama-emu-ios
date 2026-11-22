import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The platform side: buzzer tone and keeping the app alive in the background
/// (iOS: an audio session that keeps running; Android: a foreground service).
class NativeBridge {
  static const MethodChannel _ch = MethodChannel('tama/native');

  static int _lastFreq = -1;
  static bool _lastOn = false;
  static double volume = 0.35;

  static Future<void> tone(int freqDhz, bool on) async {
    if (freqDhz == _lastFreq && on == _lastOn) return;
    _lastFreq = freqDhz;
    _lastOn = on;
    try {
      await _ch.invokeMethod('tone', {'freq': freqDhz / 10.0, 'on': on, 'volume': volume});
    } catch (e) {
      debugPrint('tone: $e');
    }
  }

  static Future<void> keepAlive(bool on, {String title = 'Tama', String text = 'Your Tamagotchi keeps living'}) async {
    try {
      await _ch.invokeMethod('keepAlive', {'on': on, 'title': title, 'text': text});
    } catch (e) {
      debugPrint('keepAlive: $e');
    }
  }

  /// Asks once for permission to post notifications (the pet calling while the app is away).
  static Future<void> askToNotify() async {
    try {
      await _ch.invokeMethod('askToNotify');
    } catch (e) {
      debugPrint('askToNotify: $e');
    }
  }

  static Future<void> notify(String title, String body) async {
    try {
      await _ch.invokeMethod('notify', {'title': title, 'body': body});
    } catch (e) {
      debugPrint('notify: $e');
    }
  }

  /// Keeps the phone's screen from locking while a game is shown.
  static Future<void> keepScreenOn(bool on) async {
    try {
      await _ch.invokeMethod('keepScreenOn', {'on': on});
    } catch (e) {
      debugPrint('keepScreenOn: $e');
    }
  }
}
