/// 本地书库
/// --------
/// 和站内书架刻意分开：站内作品是 P2P 同步来的，本地书是用户自己的文件，
/// 两家各有各的空，不能替对方发言。
///
/// 索引与正文分离：启动时只读 `library.json`；打开某本书才读 `books/<id>.json`
/// —— 几十本书没必要同时挤进内存。原始文件也留一份在 `sources/`，
/// 方便用户以后导出或换设备时带走。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'book_parser.dart';
import 'local_book.dart';

class LocalLibrary extends ChangeNotifier {
  LocalLibrary({Directory? root}) : _explicitRoot = root;

  final Directory? _explicitRoot;
  Directory? _root;
  File? _indexFile;

  final List<LocalBook> _books = [];
  final Map<String, LocalBook> _content = {};

  bool _loaded = false;
  String? _error;

  bool get loaded => _loaded;
  String? get error => _error;

  /// 最近导入的在前。
  List<LocalBook> get books => List.unmodifiable(_books);

  int get totalBooks => _books.length;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final root = _explicitRoot ?? await _defaultRoot();
      _root = root;
      await root.create(recursive: true);
      await Directory(p.join(root.path, 'books')).create(recursive: true);
      await Directory(p.join(root.path, 'sources')).create(recursive: true);
      _indexFile = File(p.join(root.path, 'library.json'));

      if (await _indexFile!.exists()) {
        final raw = jsonDecode(await _indexFile!.readAsString());
        if (raw is Map && raw['books'] is List) {
          for (final item in raw['books'] as List) {
            if (item is Map) {
              final book = LocalBook.summaryFromJson(
                item.cast<String, Object?>(),
              );
              if (book.id.isNotEmpty) _books.add(book);
            }
          }
        }
        _books.sort((a, b) => b.importedAtMs.compareTo(a.importedAtMs));
      }
      _error = null;
    } catch (e) {
      _error = '$e';
      debugPrint('[local-library] 载入索引失败：$e');
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  static Future<Directory> _defaultRoot() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'local_library'));
  }

  /// 导入一个文件。解析失败时抛出可读的错误，让界面去解释，别让异常自己表演。
  Future<LocalBook> importFile(String path, {String? displayName}) async {
    await load();
    final file = File(path);
    if (!await file.exists()) {
      throw const FormatException('文件不存在或无法访问');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw const FormatException('文件是空的');
    final name = displayName ?? p.basename(path);
    return importBytes(bytes, name);
  }

  Future<LocalBook> importBytes(Uint8List bytes, String fileName) async {
    await load();
    final parsed = parseBook(bytes, fileName);
    final chapters = parsed.chapters
        .where((c) => c.text.trim().isNotEmpty)
        .toList(growable: false);
    if (chapters.isEmpty) {
      throw const FormatException('没有找到可读正文');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'lb_${now}_${Random().nextInt(0xFFFFFF).toRadixString(16)}';
    final book = LocalBook(
      id: id,
      title: parsed.title.trim().isEmpty
          ? p.basenameWithoutExtension(fileName)
          : parsed.title.trim(),
      author: parsed.author.trim(),
      format: parsed.format,
      importedAtMs: now,
      sourceName: fileName,
      chapters: chapters,
    );

    final root = _root;
    if (root == null) throw StateError('本地书库尚未初始化');

    // 写正文与原始文件；两边都成功才更新索引 ——
    // 宁可书架少一本，也不放一本点开就报错的书进去。
    final bookFile = File(p.join(root.path, 'books', '$id.json'));
    final sourceExt = p.extension(fileName).isEmpty ? '.txt' : p.extension(fileName);
    final sourceFile = File(p.join(root.path, 'sources', '$id$sourceExt'));
    await bookFile.writeAsString(jsonEncode(book.toJson()), flush: true);
    await sourceFile.writeAsBytes(bytes, flush: true);

    _books.add(book);
    _books.sort((a, b) => b.importedAtMs.compareTo(a.importedAtMs));
    _content[id] = book;
    await _saveIndex();
    notifyListeners();
    return book;
  }

  /// 打开一本书的正文。第一次打开时读 JSON，之后走内存缓存，翻页时就不用每次去打扰硬盘。
  Future<LocalBook> open(String id) async {
    final cached = _content[id];
    if (cached != null) return cached;
    final root = _root;
    if (root == null) throw StateError('本地书库尚未初始化');
    final file = File(p.join(root.path, 'books', '$id.json'));
    if (!await file.exists()) throw const FormatException('这本书的文件已丢失');
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map) throw const FormatException('书籍文件损坏');
    final book = LocalBook.fromJson(raw.cast<String, Object?>());
    // 进度以索引为准：阅读器关得快，索引可能比正文记得更勤。
    final summary = _books.where((b) => b.id == id);
    if (summary.isNotEmpty) {
      book.chapterIndex = summary.first.chapterIndex;
      book.scrollOffset = summary.first.scrollOffset;
    }
    _content[id] = book;
    return book;
  }

  /// 只保存书架可见的进度，整本正文没必要陪跑。
  Future<void> saveProgress(
    String id, {
    required int chapterIndex,
    double scrollOffset = 0,
  }) async {
    final idx = _books.indexWhere((b) => b.id == id);
    if (idx < 0) return;
    final summary = _books[idx];
    final clampedChapter = chapterIndex
        .clamp(0, max(0, summary.chapterCount - 1))
        .toInt();
    final clampedOffset = scrollOffset.clamp(0.0, 1.0).toDouble();
    summary.chapterIndex = clampedChapter;
    summary.scrollOffset = clampedOffset;
    final cached = _content[id];
    if (cached != null) {
      cached.chapterIndex = clampedChapter;
      cached.scrollOffset = clampedOffset;
    }
    await _saveIndex();
    notifyListeners();
  }

  Future<void> deleteBook(String id) async {
    final root = _root;
    final removed = _books.where((b) => b.id == id).toList();
    _books.removeWhere((b) => b.id == id);
    _content.remove(id);
    if (root != null) {
      for (final file in [
        File(p.join(root.path, 'books', '$id.json')),
      ]) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      // 原始文件后缀不可信，按 id 前缀一网打尽。
      try {
        final sources = Directory(p.join(root.path, 'sources'));
        if (await sources.exists()) {
          await for (final entity in sources.list()) {
            if (entity is File && p.basename(entity.path).startsWith('$id.')) {
              await entity.delete();
            }
          }
        }
      } catch (_) {}
    }
    if (removed.isNotEmpty) {
      await _saveIndex();
      notifyListeners();
    }
  }

  Future<void> rename(String id, String title, String author) async {
    final idx = _books.indexWhere((b) => b.id == id);
    if (idx < 0) return;
    final book = _books[idx];
    final renamed = LocalBook(
      id: book.id,
      title: title.trim().isEmpty ? book.title : title.trim(),
      author: author.trim(),
      format: book.format,
      importedAtMs: book.importedAtMs,
      sourceName: book.sourceName,
      chapterIndex: book.chapterIndex,
      scrollOffset: book.scrollOffset,
      chapters: const [],
      chapterCount: book.chapterCount,
      wordCount: book.wordCount,
    );
    _books[idx] = renamed;
    final cached = _content[id];
    if (cached != null) {
      final full = LocalBook(
        id: cached.id,
        title: renamed.title,
        author: renamed.author,
        format: cached.format,
        importedAtMs: cached.importedAtMs,
        sourceName: cached.sourceName,
        chapterIndex: cached.chapterIndex,
        scrollOffset: cached.scrollOffset,
        chapters: cached.chapters,
      );
      _content[id] = full;
      final root = _root;
      if (root != null) {
        await File(p.join(root.path, 'books', '$id.json'))
            .writeAsString(jsonEncode(full.toJson()), flush: true);
      }
    }
    await _saveIndex();
    notifyListeners();
  }

  Future<void> _saveIndex() async {
    final file = _indexFile;
    if (file == null) return;
    final data = {
      'version': 1,
      'books': [for (final b in _books) b.toSummaryJson()],
    };
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (e) {
      _error = '$e';
      debugPrint('[local-library] 保存索引失败：$e');
    }
  }
}
