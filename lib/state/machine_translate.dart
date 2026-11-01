/// 机器翻译（MyMemory 公开接口）
/// ------------------------------
/// 与 Web 版一致：不需要 API key、浏览器/客户端直连，按段落翻译。
/// **不自动翻译** —— 请求会把正文发给第三方，界面必须先说明；
/// 失败只赔一段，不赔整章。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class MachineChapterTranslation {
  const MachineChapterTranslation({
    required this.paragraphs,
    required this.done,
    required this.total,
    this.error,
    this.stoppedEarly = false,
  });

  final List<String> paragraphs;
  final int done;
  final int total;

  /// `rate-limited` / `failed` / `unsupported`
  final String? error;
  final bool stoppedEarly;
}

class MachineTranslator {
  final Map<String, String> _cache = {};

  static const _codes = {
    'en': 'en',
    'ja': 'ja',
    'ko': 'ko',
    'ru': 'ru',
    'zh': 'zh-CN',
  };

  /// 与 Web 版相同的 FNV-1a 32 位缓存键。这里只需要「同文命中」，
  /// 不需要抗碰撞 —— 缓存键不是保险柜。
  static String _key(String text, String from, String to) {
    var h = 2166136261;
    for (final unit in text.codeUnits) {
      h ^= unit;
      h = (h * 16777619) & 0xFFFFFFFF;
    }
    return '$to|$from|${h.toRadixString(36)}:${text.length.toRadixString(36)}';
  }

  Future<MachineChapterTranslation> translateChapter(
    List<String> paragraphs,
    String to, {
    String from = 'auto',
    void Function(int done, int total)? onProgress,
  }) async {
    final toCode = _codes[to];
    if (toCode == null) {
      return MachineChapterTranslation(
        paragraphs: List<String>.from(paragraphs),
        done: 0,
        total: paragraphs.length,
        error: 'unsupported',
      );
    }

    final out = List<String>.from(paragraphs);
    var done = 0;
    var rateLimited = 0;
    var stoppedEarly = false;
    String? error;

    for (var i = 0; i < paragraphs.length; i++) {
      final clean = paragraphs[i].trim();
      if (clean.isEmpty) {
        done++;
        onProgress?.call(done, paragraphs.length);
        continue;
      }
      final cached = _cache[_key(clean, from, to)];
      if (cached != null) {
        out[i] = cached;
        done++;
        onProgress?.call(done, paragraphs.length);
        continue;
      }

      final result = await _translateOne(clean, from, toCode);
      if (result.text != null) {
        out[i] = result.text!;
        _cache[_key(clean, from, to)] = result.text!;
        done++;
        rateLimited = 0;
      } else {
        error = result.error ?? 'failed';
        if (result.error == 'rate-limited') {
          rateLimited++;
          if (rateLimited >= 3) {
            stoppedEarly = true;
            break;
          }
        }
      }
      onProgress?.call(done, paragraphs.length);
      if (i + 1 < paragraphs.length) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }

    return MachineChapterTranslation(
      paragraphs: out,
      done: done,
      total: paragraphs.length,
      error: error,
      stoppedEarly: stoppedEarly,
    );
  }

  Future<({String? text, String? error})> _translateOne(
    String text,
    String from,
    String toCode,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.https('api.mymemory.translated.net', '/get', {
        'q': text,
        'langpair': from == 'auto' ? 'autodetect|$toCode' : '$from|$toCode',
      });
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 12));
      req.headers.set(HttpHeaders.userAgentHeader, 'Alighieri/0.1');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 429) {
        return (text: null, error: 'rate-limited');
      }
      if (res.statusCode != 200) {
        return (text: null, error: 'failed');
      }
      final data = jsonDecode(body);
      if (data is! Map) return (text: null, error: 'failed');
      final status = data['responseStatus'];
      if (status != null && int.tryParse('$status') != 200) {
        final details = '${data['responseDetails'] ?? ''}'.toLowerCase();
        if (details.contains('limit') || details.contains('quota')) {
          return (text: null, error: 'rate-limited');
        }
        return (text: null, error: 'failed');
      }
      final responseData = data['responseData'];
      final translated = responseData is Map
          ? '${responseData['translatedText'] ?? ''}'.trim()
          : '';
      if (translated.isEmpty) return (text: null, error: 'failed');
      return (text: translated, error: null);
    } catch (_) {
      return (text: null, error: 'failed');
    } finally {
      client.close(force: true);
    }
  }
}
