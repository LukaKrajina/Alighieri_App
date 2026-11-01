/// 本地书籍解析
/// ------------
/// 支持 TXT（UTF-8 / UTF-16 / GBK / Big5）、EPUB 2/3、Markdown、HTML。
/// 解析结果只依赖文件本身，不写盘、不回调 —— 测试也就不必替它准备舞台。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

import 'local_book.dart';

class ParsedBook {
  ParsedBook({
    required this.title,
    required this.author,
    required this.format,
    required this.chapters,
  });

  final String title;
  final String author;
  final String format;
  final List<LocalChapter> chapters;
}

/// 从文件名猜格式；未知后缀按纯文本处理 —— 很多人把 `.text` 甚至无后缀当 TXT，
/// 猜错也还有救。
String detectFormat(String fileName) {
  final ext = p.extension(fileName).toLowerCase();
  return switch (ext) {
    '.epub' => 'epub',
    '.md' || '.markdown' || '.mdown' => 'md',
    '.html' || '.htm' || '.xhtml' => 'html',
    _ => 'txt',
  };
}

ParsedBook parseBook(Uint8List bytes, String fileName) {
  final base = p.basenameWithoutExtension(fileName);
  final format = detectFormat(fileName);
  switch (format) {
    case 'epub':
      final parsed = _parseEpub(bytes, fallbackTitle: base);
      if (parsed.chapters.isNotEmpty) return parsed;
      // 损坏 / 非标准 EPUB：当作压缩包失败后，退回按纯文本读，
      // 整本书比格式面子重要。
      break;
    case 'md':
      return _parseMarkdown(decodeText(bytes), base);
    case 'html':
      return _parseHtmlBook(decodeText(bytes), base);
  }
  return _parseText(decodeText(bytes), base);
}

/* ------------------------- 编码 ------------------------- */

/// 自动识别编码。
///
/// 顺序不是「先试 UTF-8，失败就 GBK」那么简单：一些 GBK 文本恰好也能被
/// UTF-8 解出一串乱码而不抛错。这里让几个候选解码器都跑一遍，按
/// 「汉字加分、替换符/控制字符扣分」挑最好的结果 —— 像一场只看汉字数量的选美。
String decodeText(List<int> bytes) {
  if (bytes.isEmpty) return '';
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }

  final sample = bytes.length > 65536 ? bytes.sublist(0, 65536) : bytes;
  final zeroCount = sample.where((b) => b == 0).length;
  final looksUtf16 = zeroCount > sample.length ~/ 8;

  // 合法 UTF-8 直接采用。GBK 文本里出现成对的合法 UTF-8 序列很罕见，
  // 反过来「先猜 GBK」等于主动把整本中文书变成乱码。
  if (!looksUtf16) {
    try {
      return utf8.decode(bytes);
    } catch (_) {}
  }

  final utf8Sample = utf8.decode(sample, allowMalformed: true);
  final gbkSample = const GbkDecoder(allowInvalid: true).convert(sample);
  final big5Sample = const Big5Decoder(allowInvalid: true).convert(sample);
  final utf16leSample = _decodeUtf16(sample, littleEndian: true);
  final utf16beSample = _decodeUtf16(sample, littleEndian: false);
  final latinSample = latin1.decode(sample);

  final candidates = [
    utf8Sample,
    gbkSample,
    big5Sample,
    utf16leSample,
    utf16beSample,
    latinSample,
  ];
  var best = 0;
  var bestScore = _score(candidates[0]);
  for (var i = 1; i < candidates.length; i++) {
    final score = _score(candidates[i]);
    if (score > bestScore) {
      best = i;
      bestScore = score;
    }
  }

  return switch (best) {
    0 => utf8.decode(bytes, allowMalformed: true),
    1 => const GbkDecoder(allowInvalid: true).convert(bytes),
    2 => const Big5Decoder(allowInvalid: true).convert(bytes),
    3 => _decodeUtf16(bytes, littleEndian: true),
    4 => _decodeUtf16(bytes, littleEndian: false),
    _ => latin1.decode(bytes),
  };
}

int _score(String s) {
  var score = 0;
  for (final r in s.runes) {
    if (r == 0xFFFD) {
      score -= 8;
    } else if (r == 0) {
      score -= 6;
    } else if (r < 0x09) {
      score -= 4;
    } else if (r >= 0x4E00 && r <= 0x9FFF) {
      score += 2;
    } else if (r >= 0x3000 && r <= 0x30FF) {
      score += 1;
    } else if (r > 0x7F && r < 0xA0) {
      score -= 2;
    }
  }
  return score;
}

String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(
      littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  return String.fromCharCodes(units);
}

/* ------------------------- TXT ------------------------- */

final _chapterHeading = RegExp(
  r'^\s*(?:'
  r'第\s*[0-9零〇一二三四五六七八九十百千万两]+\s*[章回节話话卷篇部集]'
  r'|(?:chapter|part|volume|book)\s+[0-9ivxlcdm]+'
  r'|(?:序章|序言|前言|引子|楔子|尾声|终章|后记|番外|外传|尾声)'
  r'|(?:prologue|epilogue|afterword|interlude)'
  r')\s*[^\n]*$',
  multiLine: true,
  caseSensitive: false,
);

final _numberedHeading = RegExp(
  r'^\s*\d{1,4}\s*[.、．]\s*\S[^\n]{0,60}$',
  multiLine: true,
);

ParsedBook _parseText(String raw, String fallbackTitle) {
  final text = _normalizeText(raw);
  if (text.isEmpty) {
    return ParsedBook(
      title: fallbackTitle,
      author: '',
      format: 'txt',
      chapters: [LocalChapter(title: fallbackTitle, text: '')],
    );
  }

  var matches = _headingMatches(text, _chapterHeading);
  if (matches.length < 2) {
    final numbered = _headingMatches(text, _numberedHeading);
    // 纯数字标题很容易把正文里的「1. 他说」误判成章节；
    // 「1. 他说」只是他说，不是章节 —— 只有数量够多且分布均匀才采用。
    if (numbered.length >= 3 && numbered.length <= 500) matches = numbered;
  }

  if (matches.length < 2) {
    // 没有可识别目录：按长度切成若干节，避免一话几十万字，让进度条失去意义。
    final chapters = <LocalChapter>[];
    const chunk = 6000;
    if (text.length <= chunk * 1.5) {
      chapters.add(LocalChapter(title: fallbackTitle, text: text));
    } else {
      var start = 0;
      var index = 1;
      while (start < text.length) {
        var end = (start + chunk).clamp(0, text.length);
        if (end < text.length) {
          final nl = text.lastIndexOf('\n', end);
          if (nl > start + chunk ~/ 2) end = nl;
        }
        chapters.add(
          LocalChapter(title: '第$index节', text: text.substring(start, end).trim()),
        );
        start = end;
        index++;
      }
    }
    return ParsedBook(
      title: fallbackTitle,
      author: '',
      format: 'txt',
      chapters: chapters.where((c) => c.text.isNotEmpty).toList(),
    );
  }

  final chapters = <LocalChapter>[];
  final preface = text.substring(0, matches.first.start).trim();
  if (preface.isNotEmpty) {
    chapters.add(LocalChapter(title: '前言', text: preface));
  }
  for (var i = 0; i < matches.length; i++) {
    final start = matches[i].start;
    final end = i + 1 < matches.length ? matches[i + 1].start : text.length;
    final block = text.substring(start, end).trim();
    if (block.isEmpty) continue;
    final nl = block.indexOf('\n');
    final title = (nl < 0 ? block : block.substring(0, nl)).trim();
    final body = nl < 0 ? '' : block.substring(nl + 1).trim();
    if (body.isEmpty) continue;
    chapters.add(LocalChapter(title: title, text: body));
  }
  if (chapters.isEmpty) {
    chapters.add(LocalChapter(title: fallbackTitle, text: text));
  }
  return ParsedBook(
    title: fallbackTitle,
    author: '',
    format: 'txt',
    chapters: chapters,
  );
}

List<RegExpMatch> _headingMatches(String text, RegExp pattern) {
  final out = <RegExpMatch>[];
  var last = -100000;
  for (final m in pattern.allMatches(text)) {
    // 两个标题至少隔 8 个字符：目录页里的标题挤在一起，不能全当正文。
    if (m.start - last < 8) continue;
    out.add(m);
    last = m.start;
  }
  return out;
}

/* ------------------------- Markdown ------------------------- */

ParsedBook _parseMarkdown(String raw, String fallbackTitle) {
  final text = _normalizeText(raw);
  final lines = text.split('\n');
  final chapters = <LocalChapter>[];
  var title = fallbackTitle;
  var currentTitle = '';
  final current = <String>[];
  var foundTitle = false;

  void flush() {
    final body = current.join('\n').trim();
    if (body.isNotEmpty) {
      chapters.add(
        LocalChapter(
          title: currentTitle.isEmpty ? (chapters.isEmpty ? fallbackTitle : '第${chapters.length + 1}节') : currentTitle,
          text: body,
        ),
      );
    }
    current.clear();
  }

  for (final line in lines) {
    final h = RegExp(r'^(#{1,2})\s+(.+)$').firstMatch(line);
    if (h != null) {
      flush();
      final rawTitle = _inlineMarkdown(h.group(2)!.trim());
      currentTitle = rawTitle;
      if (!foundTitle) {
        title = rawTitle;
        foundTitle = true;
      }
      continue;
    }
    current.add(_inlineMarkdown(line));
  }
  flush();

  if (chapters.isEmpty) {
    chapters.add(LocalChapter(title: title, text: text));
  }
  return ParsedBook(
    title: title,
    author: '',
    format: 'md',
    chapters: chapters,
  );
}

String _inlineMarkdown(String line) {
  var s = line;
  s = s.replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => m[1] ?? '');
  s = s.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1] ?? '');
  s = s.replaceAll(RegExp(r'`{1,3}'), '');
  s = s.replaceAllMapped(RegExp(r'(\*\*|__)(.*?)\1'), (m) => m[2] ?? '');
  s = s.replaceAllMapped(RegExp(r'(\*|_)(.*?)\1'), (m) => m[2] ?? '');
  s = s.replaceAll(RegExp(r'^\s{0,3}>\s?'), '');
  s = s.replaceAll(RegExp(r'^\s{0,3}[-*+]\s+'), '· ');
  s = s.replaceAll(RegExp(r'^\s{0,3}\d+[.)]\s+'), '');
  s = s.replaceAll(RegExp(r'^\s*([-*_]\s*){3,}$'), '');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  return s;
}

/* ------------------------- HTML ------------------------- */

ParsedBook _parseHtmlBook(String raw, String fallbackTitle) {
  final doc = html_parser.parse(raw);
  _cleanDocument(doc);
  final title =
      _documentText(doc, 'title') ??
      _documentText(doc, 'h1') ??
      fallbackTitle;
  final chapters = <LocalChapter>[];
  final body = doc.body;
  if (body != null) {
    final buffer = <String>[];
    _collectMarked(body, buffer);
    final joined = buffer.join();
    // 标题被写成 `\u0000标题\u0000` 标记；按标记切开即可同时保留
    // 标题之前的前言与标题之后的正文。
    final parts = joined.split('\u0000');
    if (parts.length >= 3) {
      final preface = _normalizeText(parts[0]);
      if (preface.isNotEmpty) {
        chapters.add(LocalChapter(title: '前言', text: preface));
      }
      for (var i = 1; i + 1 < parts.length; i += 2) {
        final heading = _normalizeText(parts[i]);
        final text = _normalizeText(parts[i + 1]);
        if (text.isEmpty) continue;
        chapters.add(
          LocalChapter(
            title: heading.isEmpty ? '第${chapters.length + 1}章' : heading,
            text: text,
          ),
        );
      }
    } else {
      final text = _normalizeText(joined);
      if (text.isNotEmpty) chapters.add(LocalChapter(title: title, text: text));
    }
  }
  if (chapters.isEmpty) {
    final text = _bodyText(doc);
    if (text.isNotEmpty) {
      chapters.add(LocalChapter(title: title, text: text));
    }
  }
  return ParsedBook(
    title: title,
    author: '',
    format: 'html',
    chapters: chapters,
  );
}

/* ------------------------- EPUB ------------------------- */

ParsedBook _parseEpub(Uint8List bytes, {required String fallbackTitle}) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final files = <String, ArchiveFile>{};
  for (final f in archive.files) {
    if (f.isFile) files[_normZipPath(f.name)] = f;
  }

  String? readText(String path) {
    final f = files[_normZipPath(path)];
    if (f == null) return null;
    return decodeText(f.content);
  }

  var opfPath = '';
  final container = readText('META-INF/container.xml');
  if (container != null) {
    final doc = html_parser.parse(container);
    final rootfile = doc.querySelector('rootfile');
    opfPath = rootfile?.attributes['full-path'] ?? '';
  }
  if (opfPath.isEmpty) {
    for (final name in files.keys) {
      if (name.toLowerCase().endsWith('.opf')) {
        opfPath = name;
        break;
      }
    }
  }
  if (opfPath.isEmpty) {
    throw const FormatException('EPUB 缺少 OPF 清单');
  }

  final opfText = readText(opfPath);
  if (opfText == null) throw const FormatException('EPUB 的 OPF 文件无法读取');
  final opf = html_parser.parse(opfText);
  final opfDir = p.posix.dirname(opfPath);

  String meta(List<String> names) {
    for (final el in opf.getElementsByTagName('*')) {
      final local = (el.localName ?? '').toLowerCase().split(':').last;
      if (names.contains(local)) {
        final t = el.text.trim();
        if (t.isNotEmpty) return t;
      }
    }
    return '';
  }

  final title = meta(['title']);
  final author = meta(['creator']);

  final manifest = <String, _ManifestItem>{};
  for (final el in opf.getElementsByTagName('item')) {
    final id = el.attributes['id'] ?? '';
    final href = el.attributes['href'] ?? '';
    if (id.isEmpty || href.isEmpty) continue;
    manifest[id] = _ManifestItem(
      id: id,
      href: href,
      mediaType: (el.attributes['media-type'] ?? '').toLowerCase(),
      properties: (el.attributes['properties'] ?? '').toLowerCase(),
    );
  }

  final spine = <_ManifestItem>[];
  for (final el in opf.getElementsByTagName('itemref')) {
    final idref = el.attributes['idref'] ?? '';
    final item = manifest[idref];
    if (item != null) spine.add(item);
  }
  if (spine.isEmpty) {
    // 有些 EPUB 的 spine 标签大小写/命名空间不规范，退回按 manifest 顺序
    // —— 标准写得再细，也总有人自由发挥。
    spine.addAll(
      manifest.values.where(
        (m) => m.mediaType.contains('html') || m.href.toLowerCase().endsWith('.html') || m.href.toLowerCase().endsWith('.xhtml'),
      ),
    );
  }

  final toc = _readEpubToc(files, opfDir, readText, manifest);

  final chapters = <LocalChapter>[];
  for (final item in spine) {
    if (!(item.mediaType.contains('html') ||
        item.href.toLowerCase().endsWith('.html') ||
        item.href.toLowerCase().endsWith('.xhtml') ||
        item.mediaType.isEmpty)) {
      continue;
    }
    final path = _resolve(opfDir, item.href);
    // 文件名可能被 URL 编码过，解一下再找。
    final text = readText(path) ?? readText(Uri.decodeFull(path));
    if (text == null) continue;

    final doc = html_parser.parse(text);
    _cleanDocument(doc);
    final body = _bodyText(doc);
    if (body.trim().isEmpty) continue;

    final heading =
        _documentText(doc, 'h1') ??
        _documentText(doc, 'h2') ??
        _documentText(doc, 'h3') ??
        _documentText(doc, 'title');
    final tocTitle = _lookupToc(toc, path);
    final chapterTitle = (tocTitle ?? heading ?? '').trim();
    chapters.add(
      LocalChapter(
        title: chapterTitle.isEmpty
            ? '第${chapters.length + 1}章'
            : chapterTitle,
        text: body.trim(),
      ),
    );
  }

  if (chapters.isEmpty) throw const FormatException('EPUB 没有可读正文');
  return ParsedBook(
    title: title.isEmpty ? fallbackTitle : title,
    author: author,
    format: 'epub',
    chapters: chapters,
  );
}

class _ManifestItem {
  _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    required this.properties,
  });

  final String id;
  final String href;
  final String mediaType;
  final String properties;
}

Map<String, String> _readEpubToc(
  Map<String, ArchiveFile> files,
  String opfDir,
  String? Function(String) readText,
  Map<String, _ManifestItem> manifest,
) {
  final out = <String, String>{};

  _ManifestItem? navItem;
  for (final item in manifest.values) {
    if (item.properties.split(RegExp(r'\s+')).contains('nav') ||
        item.href.toLowerCase().endsWith('nav.xhtml') ||
        item.href.toLowerCase().endsWith('toc.xhtml')) {
      navItem = item;
      break;
    }
  }
  if (navItem != null) {
    final text = readText(_resolve(opfDir, navItem.href));
    if (text != null) {
      final doc = html_parser.parse(text);
      for (final a in doc.querySelectorAll('nav a[href]')) {
        final href = a.attributes['href'] ?? '';
        final label = a.text.trim();
        if (href.isEmpty || label.isEmpty) continue;
        final path = _resolve(p.posix.dirname(_resolve(opfDir, navItem.href)), href);
        out[path] = label;
      }
    }
  }

  // NCX：EPUB 2 的目录格式，老但有效。
  String? ncxPath;
  for (final item in manifest.values) {
    if (item.mediaType == 'application/x-dtbncx+xml' ||
        item.href.toLowerCase().endsWith('.ncx')) {
      ncxPath = _resolve(opfDir, item.href);
      break;
    }
  }
  if (ncxPath != null) {
    final text = readText(ncxPath);
    if (text != null) {
      final doc = html_parser.parse(text);
      for (final navPoint in doc.getElementsByTagName('navpoint')) {
        final label = _firstText(navPoint, 'text') ??
            _firstText(navPoint, 'navlabel');
        final content = navPoint.getElementsByTagName('content');
        final src = content.isEmpty ? '' : (content.first.attributes['src'] ?? '');
        if (label == null || label.trim().isEmpty || src.isEmpty) continue;
        final path = _resolve(p.posix.dirname(ncxPath), src);
        out.putIfAbsent(path, () => label.trim());
      }
    }
  }
  return out;
}

String? _lookupToc(Map<String, String> toc, String path) {
  final normalized = _normZipPath(path);
  final exact = toc[normalized];
  if (exact != null) return exact;
  final noFrag = normalized.split('#').first;
  for (final e in toc.entries) {
    if (_normZipPath(e.key).split('#').first == noFrag) return e.value;
  }
  return null;
}

String _resolve(String baseDir, String href) {
  var h = href.split('#').first.split('?').first;
  h = Uri.decodeFull(h);
  if (h.startsWith('/')) h = h.substring(1);
  return _normZipPath(p.posix.normalize(p.posix.join(baseDir, h)));
}

String _normZipPath(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'^\./'), '');

/* ------------------------- 公共工具 ------------------------- */

String _normalizeText(String raw) {
  var s = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  s = s.replaceAll('\u0000', '');
  s = s.replaceAll(RegExp(r'[ \t]+\n'), '\n');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

void _cleanDocument(dom.Document doc) {
  for (final sel in ['script', 'style', 'noscript', 'nav', 'svg']) {
    for (final el in doc.querySelectorAll(sel)) {
      el.remove();
    }
  }
}

String? _firstText(dom.Element root, String selector) {
  final el = root.querySelector(selector);
  final t = el?.text.trim();
  return (t == null || t.isEmpty) ? null : t;
}

String? _documentText(dom.Document doc, String selector) {
  final el = doc.querySelector(selector);
  final t = el?.text.trim();
  return (t == null || t.isEmpty) ? null : t;
}

String _bodyText(dom.Document doc) {
  final body = doc.body;
  if (body == null) return _normalizeText(doc.documentElement?.text ?? '');
  final buffer = <String>[];
  _collectBlocks(body, buffer);
  return _normalizeText(buffer.join('\n'));
}

void _collectBlocks(dom.Node node, List<String> out) {
  if (node is dom.Text) {
    out.add(node.text);
    return;
  }
  if (node is! dom.Element) return;
  final tag = node.localName ?? '';
  if (tag == 'br') {
    out.add('\n');
    return;
  }
  const blockTags = {
    'p', 'div', 'section', 'article', 'li', 'blockquote', 'pre',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'tr', 'td', 'th', 'figcaption',
    'ul', 'ol', 'table', 'body', 'html',
  };
  final isBlock = blockTags.contains(tag);
  if (isBlock) out.add('\n');
  for (final child in node.nodes) {
    _collectBlocks(child, out);
  }
  if (isBlock) out.add('\n');
}

/// 与 `_collectBlocks` 相同，但把 h1/h2 输出成 `\u0000标题\u0000` 标记，
/// 供 HTML 分章使用。
void _collectMarked(dom.Node node, List<String> out) {
  if (node is dom.Text) {
    out.add(node.text);
    return;
  }
  if (node is! dom.Element) return;
  final tag = node.localName ?? '';
  if (tag == 'h1' || tag == 'h2') {
    out.add('\u0000${node.text.trim()}\u0000');
    return;
  }
  if (tag == 'br') {
    out.add('\n');
    return;
  }
  const blockTags = {
    'p', 'div', 'section', 'article', 'li', 'blockquote', 'pre',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'tr', 'td', 'th', 'figcaption',
    'ul', 'ol', 'table', 'body', 'html',
  };
  final isBlock = blockTags.contains(tag);
  if (isBlock) out.add('\n');
  for (final child in node.nodes) {
    _collectMarked(child, out);
  }
  if (isBlock) out.add('\n');
}
