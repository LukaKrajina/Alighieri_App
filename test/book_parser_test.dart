import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alighieri/local/book_parser.dart';
import 'package:alighieri/local/local_library.dart';
import 'package:archive/archive.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('TXT', () {
    test('按中文章节标题切分', () {
      final text = '''
第一章 起点

这是第一段。
这是第二段。

第二章 远方

这是第二章的正文。
''';
      final book = parseBook(_bytes(text), '测试.txt');
      expect(book.title, '测试');
      expect(book.chapters.length, 2);
      expect(book.chapters.first.title, '第一章 起点');
      expect(book.chapters.first.text, contains('这是第一段'));
      expect(book.chapters[1].title, '第二章 远方');
    });

    test('识别 GBK 编码', () {
      final gbk = Uint8List.fromList(
        const GbkEncoder().convert('第一章 风起\n\n正文在这里。\n\n第二章 云涌\n\n又一章。'),
      );
      final book = parseBook(gbk, 'gbk.txt');
      expect(book.chapters.length, 2);
      expect(book.chapters.first.title, contains('风起'));
    });

    test('没有章节标记时按长度分节', () {
      final text = List.filled(3000, '这是一段很长的正文。').join('\n');
      final book = parseBook(_bytes(text), '长文.txt');
      expect(book.chapters.length, greaterThan(1));
      expect(book.chapters.length, lessThan(10));
    });
  });

  group('Markdown / HTML', () {
    test('Markdown 一级标题分章并去掉标记', () {
      const text = '''
# 序章

这是**加粗**与[链接](https://example.com)。

# 第一章

正文。
''';
      final book = parseBook(_bytes(text), 'note.md');
      expect(book.title, '序章');
      expect(book.chapters.length, 2);
      expect(book.chapters.first.text, contains('加粗'));
      expect(book.chapters.first.text, isNot(contains('**')));
      expect(book.chapters.first.text, isNot(contains('https://')));
    });

    test('HTML 用 h1/h2 分章且保留段落', () {
      const text = '''
<html><head><title>网页书</title></head><body>
<h1>第一章</h1><p>第一段。</p><p>第二段。</p>
<h1>第二章</h1><p>另一段。</p>
</body></html>
''';
      final book = parseBook(_bytes(text), 'page.html');
      expect(book.title, '网页书');
      expect(book.chapters.length, 2);
      expect(book.chapters.first.title, '第一章');
      expect(book.chapters.first.text, contains('第一段'));
      expect(book.chapters.first.text, contains('第二段'));
    });
  });

  group('EPUB', () {
    test('读取 container / OPF / spine / nav', () {
      final archive = Archive();
      void add(String name, String content) {
        final bytes = utf8.encode(content);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add('mimetype', 'application/epub+zip');
      add(
        'META-INF/container.xml',
        '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
      );
      add(
        'OEBPS/content.opf',
        '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>星之书</dc:title><dc:creator>某作者</dc:creator>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>''',
      );
      add(
        'OEBPS/nav.xhtml',
        '''<html><body><nav><ol>
<li><a href="c1.xhtml">第一章 出发</a></li>
<li><a href="c2.xhtml">第二章 抵达</a></li>
</ol></nav></body></html>''',
      );
      add(
        'OEBPS/c1.xhtml',
        '<html><body><h1>Ignored</h1><p>第一章正文。</p></body></html>',
      );
      add(
        'OEBPS/c2.xhtml',
        '<html><body><p>第二章正文。</p></body></html>',
      );

      final zip = ZipEncoder().encode(archive)!;
      final book = parseBook(Uint8List.fromList(zip), 'star.epub');
      expect(book.title, '星之书');
      expect(book.author, '某作者');
      expect(book.chapters.length, 2);
      expect(book.chapters.first.title, '第一章 出发');
      expect(book.chapters[1].title, '第二章 抵达');
      expect(book.chapters.first.text, contains('第一章正文'));
    });
  });

  group('本地书库', () {
    test('导入、读回、保存进度并重新载入索引', () async {
      final dir = await Directory.systemTemp.createTemp('alighieri_lib_test_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final lib = LocalLibrary(root: dir);
      await lib.load();
      expect(lib.books, isEmpty);

      final bytes = _bytes('第一章 开始\n\n正文一。\n\n第二章 继续\n\n正文二。');
      final book = await lib.importBytes(bytes, 'demo.txt');
      expect(lib.books.length, 1);
      expect(book.chapters.length, 2);

      await lib.saveProgress(book.id, chapterIndex: 1, scrollOffset: 0.5);
      final reopened = await lib.open(book.id);
      expect(reopened.chapters.length, 2);
      expect(reopened.chapterIndex, 1);
      expect(reopened.scrollOffset, 0.5);

      // 新实例从索引恢复，正文按需读取。
      final lib2 = LocalLibrary(root: dir);
      await lib2.load();
      expect(lib2.books.length, 1);
      expect(lib2.books.first.chapterIndex, 1);
      final full = await lib2.open(book.id);
      expect(full.chapters.length, 2);
      expect(full.chapters[1].title, '第二章 继续');

      await lib2.deleteBook(book.id);
      expect(lib2.books, isEmpty);
    });
  });
}