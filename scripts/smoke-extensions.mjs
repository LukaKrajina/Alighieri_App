/**
 * 扩展端冒烟测试
 * --------------
 * 不依赖 VS Code / Obsidian 进程，只验证两件最容易出错的事：
 *   1. 本地书库能解析 TXT / Markdown / HTML / EPUB，并正确分章；
 *   2. 本地 HTTP 服务能同时提供 Web 客户端、本地书架与 API。
 *
 * 用法：node scripts/smoke-extensions.mjs
 *
 * 冒烟不是全面体检，但至少能确认引擎点得着。
 */
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { LocalLibrary, parseBook } = require("../extensions/shared/local-library.js");
const { createLocalServer } = require("../extensions/shared/server.js");

const root = path.join(os.tmpdir(), `alighieri-smoke-${Date.now()}`);
const libraryRoot = path.join(root, "library");
const extensionRoot = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "dist",
  "extensions",
  "vscode",
  "extension",
);
const webRoot = path.join(extensionRoot, "web");
const uiRoot = path.join(extensionRoot, "ui");

let failures = 0;
function check(name, condition, detail = "") {
  if (condition) {
    console.log(`  ok   ${name}`);
  } else {
    failures++;
    console.log(`  FAIL ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

function zipStore(entries) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const [name, data] of entries) {
    const nameBuf = Buffer.from(name, "utf8");
    const body = Buffer.isBuffer(data) ? data : Buffer.from(data, "utf8");
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x800, 6);
    local.writeUInt16LE(0, 8);
    local.writeUInt32LE(body.length, 18);
    local.writeUInt32LE(body.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    locals.push(local, nameBuf, body);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x800, 8);
    central.writeUInt16LE(0, 10);
    central.writeUInt32LE(body.length, 20);
    central.writeUInt32LE(body.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt32LE(offset, 42);
    centrals.push(central, nameBuf);
    offset += 30 + nameBuf.length + body.length;
  }
  const centralBuf = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, centralBuf, eocd]);
}

function makeEpub() {
  const container = `<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>`;
  const opf = `<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>星海拾遗</dc:title><dc:creator>测试作者</dc:creator>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>`;
  const nav = `<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><nav>
  <a href="chapter1.xhtml">第一章 启航</a>
  <a href="chapter2.xhtml">第二章 潮汐</a>
</nav></body></html>`;
  const c1 = `<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head>
<body><h1>第一章 启航</h1><p>风从舷窗外掠过。</p><p>她把星图铺在桌上。</p></body></html>`;
  const c2 = `<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>第二章 潮汐</h1><p>潮水淹没了旧码头。</p></body></html>`;
  return zipStore([
    ["mimetype", "application/epub+zip"],
    ["META-INF/container.xml", container],
    ["OEBPS/content.opf", opf],
    ["OEBPS/nav.xhtml", nav],
    ["OEBPS/chapter1.xhtml", c1],
    ["OEBPS/chapter2.xhtml", c2],
  ]);
}

async function main() {
  console.log("解析器");
  const txt = Buffer.from(
    "序言\n这是序言。\n\n第一章 风起\n正文一。\n\n第二章 潮落\n正文二。\n",
    "utf8",
  );
  const txtBook = parseBook(txt, "测试书.txt");
  check("TXT 分章", txtBook.chapters.length >= 2, `chapters=${txtBook.chapters.length}`);
  check("TXT 标题", txtBook.title === "测试书");

  const mdBook = parseBook(
    Buffer.from("# 灯下\n\n## 第一章\n正文。\n\n## 第二章\n正文二。\n", "utf8"),
    "灯下.md",
  );
  check("Markdown 分章", mdBook.chapters.length === 2, `chapters=${mdBook.chapters.length}`);
  check("Markdown 书名", mdBook.title === "灯下");

  const htmlBook = parseBook(
    Buffer.from("<html><body><h1>夏日</h1><h2>上</h2><p>蝉鸣。</p><h2>下</h2><p>雨落。</p></body></html>", "utf8"),
    "夏日.html",
  );
  check("HTML 分章", htmlBook.chapters.length >= 2, `chapters=${htmlBook.chapters.length}`);

  const epubBytes = makeEpub();
  const epubBook = parseBook(epubBytes, "星海.epub");
  check("EPUB 分章", epubBook.chapters.length === 2, `chapters=${epubBook.chapters.length}`);
  check("EPUB 书名", epubBook.title === "星海拾遗", epubBook.title);
  check("EPUB 作者", epubBook.author === "测试作者", epubBook.author);
  check("EPUB 目录标题", epubBook.chapters[0].title.includes("启航"), epubBook.chapters[0].title);

  console.log("本地书库");
  const library = new LocalLibrary(libraryRoot).load();
  const imported = library.importBytes(epubBytes, "星海.epub");
  check("导入 EPUB", imported.chapterCount === 2, `chapterCount=${imported.chapterCount}`);
  check("导入后有索引", library.summaries().length === 1);
  const opened = library.open(imported.id);
  check("打开正文", opened.chapters.length === 2);
  const progressed = library.saveProgress(imported.id, 1, 0.5);
  check("保存进度", progressed.chapterIndex === 1 && progressed.scrollOffset === 0.5);
  const renamed = library.rename(imported.id, "新名字", "新作者");
  check("重命名", renamed.title === "新名字" && renamed.author === "新作者");

  console.log("本地服务");
  const handle = await createLocalServer({
    webRoot,
    uiRoot,
    library,
    preferredPort: 47891,
    logger: { info: () => {}, error: () => {} },
  });

  async function get(pathname, options) {
    const res = await fetch(`${handle.url}${pathname}`, options);
    const text = await res.text();
    return { res, text };
  }

  const index = await get("/");
  check("Web 客户端首页", index.res.ok && index.text.includes("<html"), `status=${index.res.status}`);
  const browse = await get("/browse/");
  check("Web 客户端路由", browse.res.ok && browse.text.includes("<html"), `status=${browse.res.status}`);
  const local = await get("/local");
  check("本地书架页面", local.res.ok && local.text.includes("本地书架"), `status=${local.res.status}`);
  const js = await get("/local.js");
  check("本地书架脚本", js.res.ok && js.res.headers.get("content-type")?.includes("javascript"));
  const books = await get("/api/local/books");
  const booksJson = JSON.parse(books.text);
  check("书库 API", books.res.ok && booksJson.books.length === 1);
  const book = await get(`/api/local/book?id=${encodeURIComponent(imported.id)}`);
  const bookJson = JSON.parse(book.text);
  check("正文 API", book.res.ok && bookJson.book.chapters.length === 2);
  const progress = await get("/api/local/progress", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id: imported.id, chapterIndex: 1, scrollOffset: 0.2 }),
  });
  check("进度 API", progress.res.ok);
  const bad = await get("/api/local/book?id=missing");
  check("未知书籍返回错误", bad.res.status === 400 || bad.res.status === 404, `status=${bad.res.status}`);

  await new Promise((resolve) => handle.server.close(resolve));
  fs.rmSync(root, { recursive: true, force: true });

  console.log(failures ? `\n${failures} 项失败` : "\n全部通过");
  process.exit(failures ? 1 : 0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});