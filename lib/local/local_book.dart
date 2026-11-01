/// 本地书籍模型
/// ------------
/// 本地书库不经过 P2P，也不产生任何 op：它只是把用户自己设备上的
/// TXT / EPUB / Markdown / HTML 读成一个统一的「章节列表」，让阅读器
/// 复用同一套翻页、字号与进度逻辑 —— 读者不必知道自己在读哪种格式。
///
/// 存储结构刻意拆成两层：
///   * `library.json` —— 书架列表需要的轻量元数据（含进度），启动时只读它；
///   * `books/<id>.json` —— 正文，打开某本书时才读，避免几十本书一起进内存
///     —— 手机不会为此感谢你。
library;

class LocalChapter {
  LocalChapter({required this.title, required this.text});

  final String title;
  final String text;

  /// 与站内作品相同的字数口径：去掉空白后的字符数。
  int get words => text.replaceAll(RegExp(r'\s'), '').runes.length;

  Map<String, Object?> toJson() => {'title': title, 'text': text};

  static LocalChapter fromJson(Map<String, Object?> json) => LocalChapter(
    title: (json['title'] as String?) ?? '',
    text: (json['text'] as String?) ?? '',
  );
}

class LocalBook {
  LocalBook({
    required this.id,
    required this.title,
    required this.author,
    required this.format,
    required this.importedAtMs,
    required this.chapters,
    this.sourceName = '',
    this.chapterIndex = 0,
    this.scrollOffset = 0,
    int? chapterCount,
    int? wordCount,
  }) : chapterCount = chapterCount ?? chapters.length,
       wordCount =
           wordCount ?? chapters.fold<int>(0, (sum, c) => sum + c.words);

  final String id;
  final String title;
  final String author;
  /// `txt` / `epub` / `md` / `html`
  final String format;
  final int importedAtMs;
  final String sourceName;

  /// 打开索引条目时正文尚未载入，这时用保存下来的计数；
  /// 打开正文后由实际章节重新计算。
  final List<LocalChapter> chapters;
  final int chapterCount;
  final int wordCount;

  /// 上次读到的章节下标与章节内滚动位置（0–1）。
  int chapterIndex;
  double scrollOffset;

  int get words => wordCount;

  bool get isEmpty => chapterCount == 0;

  bool get loaded => chapters.isNotEmpty;

  /// 书架列表只需要这些字段；正文不写进索引。
  Map<String, Object?> toSummaryJson() => {
    'id': id,
    'title': title,
    'author': author,
    'format': format,
    'importedAtMs': importedAtMs,
    'sourceName': sourceName,
    'chapterCount': chapterCount,
    'words': wordCount,
    'chapterIndex': chapterIndex,
    'scrollOffset': scrollOffset,
  };

  Map<String, Object?> toJson() => {
    ...toSummaryJson(),
    'chapters': [for (final c in chapters) c.toJson()],
  };

  static LocalBook fromJson(Map<String, Object?> json) {
    final chapters = <LocalChapter>[];
    final raw = json['chapters'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          chapters.add(LocalChapter.fromJson(item.cast<String, Object?>()));
        }
      }
    }
    return LocalBook(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      author: (json['author'] as String?) ?? '',
      format: (json['format'] as String?) ?? 'txt',
      importedAtMs: (json['importedAtMs'] as num?)?.toInt() ?? 0,
      sourceName: (json['sourceName'] as String?) ?? '',
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      scrollOffset: (json['scrollOffset'] as num?)?.toDouble() ?? 0,
      chapters: chapters,
    );
  }

  /// 从索引条目还原一个「只有元数据」的书。打开正文前先用它占位，不必让书架干等。
  static LocalBook summaryFromJson(Map<String, Object?> json) => LocalBook(
    id: (json['id'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    author: (json['author'] as String?) ?? '',
    format: (json['format'] as String?) ?? 'txt',
    importedAtMs: (json['importedAtMs'] as num?)?.toInt() ?? 0,
    sourceName: (json['sourceName'] as String?) ?? '',
    chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
    scrollOffset: (json['scrollOffset'] as num?)?.toDouble() ?? 0,
    chapters: const [],
    chapterCount: (json['chapterCount'] as num?)?.toInt() ?? 0,
    wordCount: (json['words'] as num?)?.toInt() ?? 0,
  );
}
