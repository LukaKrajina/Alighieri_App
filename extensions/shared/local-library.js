/**
 * Alighieri 本地书库（扩展端共用）
 * --------------------------------
 * 与 Flutter 端 `lib/local/` 保持同一份数据结构：
 *   library.json            书架索引（只存元数据与进度）
 *   books/<id>.json         某本书的完整正文
 *   sources/<id>.<ext>      原始文件副本
 *
 * 支持 TXT（UTF-8 / UTF-16 / GBK / Big5）、EPUB 2/3、Markdown、HTML。
 * 这里不依赖任何第三方包：EPUB 的 ZIP 读取与章节解析都在本文件里完成，
 * 相当于自带开罐器，不点外卖。
 */
"use strict";

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const crypto = require("crypto");

const FORMATS = {
  ".epub": "epub",
  ".md": "md",
  ".markdown": "md",
  ".mdown": "md",
  ".html": "html",
  ".htm": "html",
  ".xhtml": "html",
};

function detectFormat(fileName) {
  return FORMATS[path.extname(fileName).toLowerCase()] || "txt";
}

class LocalLibrary {
  constructor(root) {
    this.root = root;
    this.indexFile = path.join(root, "library.json");
    this.books = [];
    this.cache = new Map();
    this.loaded = false;
  }

  load() {
    if (this.loaded) return this;
    fs.mkdirSync(this.root, { recursive: true });
    fs.mkdirSync(path.join(this.root, "books"), { recursive: true });
    fs.mkdirSync(path.join(this.root, "sources"), { recursive: true });
    try {
      const raw = JSON.parse(fs.readFileSync(this.indexFile, "utf8"));
      if (raw && Array.isArray(raw.books)) {
        this.books = raw.books
          .filter((b) => b && typeof b.id === "string" && b.id)
          .map((b) => ({
            id: b.id,
            title: String(b.title || ""),
            author: String(b.author || ""),
            format: String(b.format || "txt"),
            importedAtMs: Number(b.importedAtMs || 0),
            sourceName: String(b.sourceName || ""),
            chapterIndex: Number(b.chapterIndex || 0),
            scrollOffset: Number(b.scrollOffset || 0),
            chapterCount: Number(b.chapterCount || 0),
            wordCount: Number(b.wordCount || 0),
          }));
      }
    } catch (e) {
      if (e.code !== "ENOENT") console.error("[alighieri] 读取本地书库索引失败", e);
    }
    this.sort();
    this.loaded = true;
    return this;
  }

  sort() {
    this.books.sort((a, b) => b.importedAtMs - a.importedAtMs);
  }

  summaries() {
    this.load();
    return this.books.map((b) => ({ ...b }));
  }

  importFile(filePath, displayName) {
    this.load();
    if (!fs.existsSync(filePath)) throw new Error("文件不存在或无法访问");
    const fileName = displayName || path.basename(filePath);
    const bytes = fs.readFileSync(filePath);
    if (!bytes.length) throw new Error("文件是空的");
    return this.importBytes(bytes, fileName);
  }

  importBytes(bytes, fileName) {
    this.load();
    const parsed = parseBook(Buffer.from(bytes), fileName);
    const chapters = parsed.chapters.filter((c) => c.text.trim());
    if (!chapters.length) throw new Error("没有找到可读正文");

    const now = Date.now();
    const id = `lb_${now}_${crypto.randomBytes(3).toString("hex")}`;
    const book = {
      id,
      title: (parsed.title || "").trim() || path.basename(fileName, path.extname(fileName)),
      author: (parsed.author || "").trim(),
      format: parsed.format,
      importedAtMs: now,
      sourceName: fileName,
      chapterIndex: 0,
      scrollOffset: 0,
      chapterCount: chapters.length,
      wordCount: chapters.reduce((n, c) => n + countWords(c.text), 0),
      chapters: chapters.map((c, i) => ({
        title: c.title || `第${i + 1}章`,
        text: c.text,
      })),
    };

    const bookFile = path.join(this.root, "books", `${id}.json`);
    const ext = path.extname(fileName) || ".txt";
    const sourceFile = path.join(this.root, "sources", `${id}${ext}`);
    fs.writeFileSync(bookFile, JSON.stringify(book));
    fs.writeFileSync(sourceFile, bytes);
    this.books.push(book);
    this.sort();
    this.cache.set(id, book);
    this.saveIndex();
    return publicBook(book, true);
  }

  open(id) {
    this.load();
    if (this.cache.has(id)) return this.cache.get(id);
    const file = path.join(this.root, "books", `${id}.json`);
    if (!fs.existsSync(file)) throw new Error("这本书的文件已丢失");
    const book = JSON.parse(fs.readFileSync(file, "utf8"));
    const summary = this.books.find((b) => b.id === id);
    if (summary) {
      book.chapterIndex = summary.chapterIndex;
      book.scrollOffset = summary.scrollOffset;
    }
    this.cache.set(id, book);
    return book;
  }

  saveProgress(id, chapterIndex, scrollOffset) {
    this.load();
    const summary = this.books.find((b) => b.id === id);
    if (!summary) return null;
    const chapter = clamp(Number(chapterIndex) || 0, 0, Math.max(0, summary.chapterCount - 1));
    const offset = clamp(Number(scrollOffset) || 0, 0, 1);
    summary.chapterIndex = chapter;
    summary.scrollOffset = offset;
    const cached = this.cache.get(id);
    if (cached) {
      cached.chapterIndex = chapter;
      cached.scrollOffset = offset;
    }
    this.saveIndex();
    return { ...summary };
  }

  rename(id, title, author) {
    this.load();
    const summary = this.books.find((b) => b.id === id);
    if (!summary) return null;
    summary.title = String(title || "").trim() || summary.title;
    summary.author = String(author || "").trim();
    const cached = this.cache.get(id);
    if (cached) {
      cached.title = summary.title;
      cached.author = summary.author;
      fs.writeFileSync(path.join(this.root, "books", `${id}.json`), JSON.stringify(cached));
    }
    this.saveIndex();
    return { ...summary };
  }

  delete(id) {
    this.load();
    const before = this.books.length;
    this.books = this.books.filter((b) => b.id !== id);
    this.cache.delete(id);
    try {
      const file = path.join(this.root, "books", `${id}.json`);
      if (fs.existsSync(file)) fs.unlinkSync(file);
    } catch (e) {
      console.error("[alighieri] 删除正文失败", e);
    }
    try {
      const sources = path.join(this.root, "sources");
      for (const name of fs.readdirSync(sources)) {
        if (name.startsWith(`${id}.`)) fs.unlinkSync(path.join(sources, name));
      }
    } catch (e) {
      console.error("[alighieri] 删除原始文件失败", e);
    }
    if (before !== this.books.length) this.saveIndex();
    return { removed: before !== this.books.length };
  }

  exportJson(id) {
    return this.open(id);
  }

  saveIndex() {
    const data = {
      version: 1,
      books: this.books.map((b) => ({
        id: b.id,
        title: b.title,
        author: b.author,
        format: b.format,
        importedAtMs: b.importedAtMs,
        sourceName: b.sourceName,
        chapterIndex: b.chapterIndex,
        scrollOffset: b.scrollOffset,
        chapterCount: b.chapterCount,
        wordCount: b.wordCount,
      })),
    };
    const tmp = `${this.indexFile}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(data));
    fs.renameSync(tmp, this.indexFile);
  }
}

function publicBook(book, withChapters) {
  const out = {
    id: book.id,
    title: book.title,
    author: book.author,
    format: book.format,
    importedAtMs: book.importedAtMs,
    sourceName: book.sourceName,
    chapterIndex: book.chapterIndex,
    scrollOffset: book.scrollOffset,
    chapterCount: book.chapterCount,
    wordCount: book.wordCount,
  };
  if (withChapters) out.chapters = book.chapters;
  return out;
}

/* ------------------------------ 解析 ------------------------------ */

function parseBook(bytes, fileName) {
  const base = path.basename(fileName, path.extname(fileName));
  const format = detectFormat(fileName);
  if (format === "epub") {
    try {
      const parsed = parseEpub(bytes, base);
      if (parsed.chapters.length) return parsed;
    } catch (e) {
      console.warn("[alighieri] EPUB 解析失败，回落为纯文本", e.message);
    }
  }
  const text = decodeText(bytes);
  if (format === "md") return parseMarkdown(text, base);
  if (format === "html") return parseHtmlBook(text, base);
  return parseText(text, base);
}

function countWords(text) {
  return text.replace(/\s/g, "").length;
}

function clamp(n, min, max) {
  return Math.min(max, Math.max(min, n));
}

/* ------------------------------ 编码 ------------------------------ */

function decodeText(bytes) {
  if (!bytes.length) return "";
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return new TextDecoder("utf-8", { fatal: false }).decode(bytes.subarray(3));
  }
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    return decodeUtf16(bytes.subarray(2), true);
  }
  if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    return decodeUtf16(bytes.subarray(2), false);
  }
  const sample = bytes.subarray(0, Math.min(bytes.length, 65536));
  const zeros = sample.reduce((n, b) => n + (b === 0 ? 1 : 0), 0);
  const looksUtf16 = zeros > sample.length / 8;

  if (!looksUtf16) {
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    } catch (_) {}
  }

  const candidates = [];
  const push = (label, decoderName) => {
    try {
      candidates.push({ label, text: new TextDecoder(decoderName, { fatal: false }).decode(sample) });
    } catch (_) {}
  };
  push("utf8", "utf-8");
  push("gb18030", "gb18030");
  push("big5", "big5");
  candidates.push({ label: "utf16le", text: decodeUtf16(sample, true) });
  candidates.push({ label: "utf16be", text: decodeUtf16(sample, false) });
  candidates.push({ label: "latin1", text: Buffer.from(sample).toString("latin1") });

  let best = candidates[0];
  let bestScore = scoreText(best.text);
  for (const c of candidates.slice(1)) {
    const score = scoreText(c.text);
    if (score > bestScore) {
      best = c;
      bestScore = score;
    }
  }

  try {
    if (best.label === "utf8") return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
    if (best.label === "gb18030" || best.label === "big5") {
      return new TextDecoder(best.label, { fatal: false }).decode(bytes);
    }
  } catch (_) {}
  return best.label === "utf16le"
    ? decodeUtf16(bytes, true)
    : best.label === "utf16be"
      ? decodeUtf16(bytes, false)
      : Buffer.from(bytes).toString("latin1");
}

function decodeUtf16(bytes, littleEndian) {
  const parts = [];
  let units = "";
  for (let i = 0; i + 1 < bytes.length; i += 2) {
    units += String.fromCharCode(
      littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1],
    );
    if (units.length >= 4096) {
      parts.push(units);
      units = "";
    }
  }
  if (units) parts.push(units);
  return parts.join("");
}

function scoreText(s) {
  let score = 0;
  for (const ch of s) {
    const code = ch.codePointAt(0);
    if (code === 0xfffd) score -= 8;
    else if (code === 0) score -= 6;
    else if (code < 9) score -= 4;
    else if (code >= 0x4e00 && code <= 0x9fff) score += 2;
    else if (code >= 0x3000 && code <= 0x30ff) score += 1;
    else if (code > 0x7f && code < 0xa0) score -= 2;
  }
  return score;
}

/* ------------------------------ TXT ------------------------------ */

const CHAPTER_HEADING =
  /^[ \t]*(?:第\s*[0-9零〇一二三四五六七八九十百千万两]+\s*[章回节話话卷篇部集]|(?:chapter|part|volume|book)\s+[0-9ivxlcdm]+|(?:序章|序言|前言|引子|楔子|尾声|终章|后记|番外|外传|prologue|epilogue|afterword|interlude))[^\n]*$/gim;

const NUMBERED_HEADING = /^[ \t]*\d{1,4}\s*[.、．]\s*\S[^\n]{0,60}$/gm;

function parseText(raw, fallbackTitle) {
  const text = normalizeText(raw);
  if (!text) {
    return { title: fallbackTitle, author: "", format: "txt", chapters: [{ title: fallbackTitle, text: "" }] };
  }

  let matches = headingMatches(text, CHAPTER_HEADING);
  if (matches.length < 2) {
    const numbered = headingMatches(text, NUMBERED_HEADING);
    if (numbered.length >= 3 && numbered.length <= 500) matches = numbered;
  }

  if (matches.length < 2) {
    const chapters = [];
    const chunk = 6000;
    if (text.length <= chunk * 1.5) {
      chapters.push({ title: fallbackTitle, text });
    } else {
      let start = 0;
      let index = 1;
      while (start < text.length) {
        let end = Math.min(start + chunk, text.length);
        if (end < text.length) {
          const nl = text.lastIndexOf("\n", end);
          if (nl > start + chunk / 2) end = nl;
        }
        chapters.push({ title: `第${index}节`, text: text.slice(start, end).trim() });
        start = end;
        index++;
      }
    }
    return { title: fallbackTitle, author: "", format: "txt", chapters: chapters.filter((c) => c.text) };
  }

  const chapters = [];
  const preface = text.slice(0, matches[0].start).trim();
  if (preface) chapters.push({ title: "前言", text: preface });
  for (let i = 0; i < matches.length; i++) {
    const start = matches[i].start;
    const end = i + 1 < matches.length ? matches[i + 1].start : text.length;
    const block = text.slice(start, end).trim();
    if (!block) continue;
    const nl = block.indexOf("\n");
    const title = (nl < 0 ? block : block.slice(0, nl)).trim();
    const body = nl < 0 ? "" : block.slice(nl + 1).trim();
    if (!body) continue;
    chapters.push({ title, text: body });
  }
  if (!chapters.length) chapters.push({ title: fallbackTitle, text });
  return { title: fallbackTitle, author: "", format: "txt", chapters };
}

function headingMatches(text, pattern) {
  const out = [];
  pattern.lastIndex = 0;
  let match;
  let last = -100000;
  while ((match = pattern.exec(text))) {
    if (match.index - last >= 8) {
      out.push({ start: match.index, end: match.index + match[0].length });
      last = match.index;
    }
    if (match[0].length === 0) pattern.lastIndex++;
  }
  return out;
}

/* --------------------------- Markdown --------------------------- */

function parseMarkdown(raw, fallbackTitle) {
  const text = normalizeText(raw);
  const lines = text.split("\n");
  const chapters = [];
  let title = fallbackTitle;
  let currentTitle = "";
  let current = [];
  let foundTitle = false;

  const flush = () => {
    const body = current.join("\n").trim();
    if (body) {
      chapters.push({
        title: currentTitle || (chapters.length ? `第${chapters.length + 1}节` : fallbackTitle),
        text: body,
      });
    }
    current = [];
  };

  for (const line of lines) {
    const h = /^(#{1,2})\s+(.+)$/.exec(line);
    if (h) {
      flush();
      const rawTitle = inlineMarkdown(h[2].trim());
      currentTitle = rawTitle;
      if (!foundTitle) {
        title = rawTitle;
        foundTitle = true;
      }
      continue;
    }
    current.push(inlineMarkdown(line));
  }
  flush();
  if (!chapters.length) chapters.push({ title, text });
  return { title, author: "", format: "md", chapters };
}

function inlineMarkdown(line) {
  return line
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/`{1,3}/g, "")
    .replace(/(\*\*|__)(.*?)\1/g, "$2")
    .replace(/(\*|_)(.*?)\1/g, "$2")
    .replace(/^\s{0,3}>\s?/, "")
    .replace(/^\s{0,3}[-*+]\s+/, "· ")
    .replace(/^\s{0,3}\d+[.)]\s+/, "")
    .replace(/^\s*([-*_]\s*){3,}$/, "")
    .replace(/<[^>]+>/g, "");
}

/* ------------------------------ HTML ------------------------------ */

function parseHtmlBook(raw, fallbackTitle) {
  const cleaned = raw
    .replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/<nav[\s\S]*?<\/nav>/gi, "")
    .replace(/<svg[\s\S]*?<\/svg>/gi, "");
  const titleMatch = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(cleaned);
  const h1Match = /<h1[^>]*>([\s\S]*?)<\/h1>/i.exec(cleaned);
  const title = stripInline(titleMatch ? titleMatch[1] : "") || stripInline(h1Match ? h1Match[1] : "") || fallbackTitle;

  const body = cleaned.replace(/^[\s\S]*?<body[^>]*>/i, "").replace(/<\/body>[\s\S]*$/i, "");
  const headings = [...body.matchAll(/<h([12])\b[^>]*>([\s\S]*?)<\/h\1>/gi)];
  const chapters = [];
  if (headings.length >= 2) {
    const preface = stripHtml(body.slice(0, headings[0].index));
    if (preface) chapters.push({ title: "前言", text: preface });
    for (let i = 0; i < headings.length; i++) {
      const start = headings[i].index + headings[i][0].length;
      const end = i + 1 < headings.length ? headings[i + 1].index : body.length;
      const heading = stripInline(headings[i][2]);
      const text = stripHtml(body.slice(start, end));
      if (text) chapters.push({ title: heading || `第${chapters.length + 1}章`, text });
    }
  }
  if (!chapters.length) {
    const text = stripHtml(body);
    if (text) chapters.push({ title, text });
  }
  return { title, author: "", format: "html", chapters };
}

/* ------------------------------ EPUB ------------------------------ */

function parseEpub(bytes, fallbackTitle) {
  const files = unzip(bytes);
  const readText = (name) => {
    const data = files.get(normalizeZipPath(name));
    return data ? decodeText(data) : null;
  };

  let opfPath = "";
  const container = readText("META-INF/container.xml");
  if (container) {
    const m = /<rootfile\b[^>]*\bfull-path\s*=\s*["']([^"']+)["']/i.exec(container);
    if (m) opfPath = m[1];
  }
  if (!opfPath) {
    for (const name of files.keys()) {
      if (name.toLowerCase().endsWith(".opf")) {
        opfPath = name;
        break;
      }
    }
  }
  if (!opfPath) throw new Error("EPUB 缺少 OPF 清单");
  const opfText = readText(opfPath);
  if (!opfText) throw new Error("EPUB 的 OPF 文件无法读取");
  const opfDir = posixDirname(opfPath);

  const title = firstTagText(opfText, "dc:title") || firstTagText(opfText, "title");
  const author = firstTagText(opfText, "dc:creator") || firstTagText(opfText, "creator");

  const manifest = {};
  for (const m of opfText.matchAll(/<item\b([^>]*)\/?>/gi)) {
    const attrs = parseAttrs(m[1]);
    if (attrs.id && attrs.href) {
      manifest[attrs.id] = {
        id: attrs.id,
        href: decodeEntities(attrs.href),
        mediaType: (attrs["media-type"] || "").toLowerCase(),
        properties: (attrs.properties || "").toLowerCase(),
      };
    }
  }

  const spine = [];
  for (const m of opfText.matchAll(/<itemref\b([^>]*)\/?>/gi)) {
    const attrs = parseAttrs(m[1]);
    const item = manifest[attrs.idref];
    if (item) spine.push(item);
  }
  const htmlItems = Object.values(manifest).filter(
    (m) => m.mediaType.includes("html") || /\.(x?html?|xhtml)$/i.test(m.href),
  );
  const ordered = spine.length ? spine : htmlItems;
  if (!ordered.length) throw new Error("EPUB 没有可读章节");

  const toc = readEpubToc(files, opfDir, readText, manifest);
  const chapters = [];
  for (const item of ordered) {
    if (!(item.mediaType.includes("html") || /\.x?html?$/i.test(item.href) || item.mediaType === "")) continue;
    const filePath = resolvePath(opfDir, item.href);
    const text = readText(filePath) || readText(safeDecodeUri(filePath));
    if (!text) continue;
    const cleaned = text
      .replace(/<script[\s\S]*?<\/script>/gi, "")
      .replace(/<style[\s\S]*?<\/style>/gi, "")
      .replace(/<nav[\s\S]*?<\/nav>/gi, "");
    const bodyText = stripHtml(cleaned);
    if (!bodyText) continue;
    const heading =
      stripInline(firstTagInner(cleaned, "h1")) ||
      stripInline(firstTagInner(cleaned, "h2")) ||
      stripInline(firstTagInner(cleaned, "h3")) ||
      stripInline(firstTagInner(cleaned, "title")) ||
      "";
    const chapterTitle = (toc[normalizeZipPath(filePath)] || heading || "").trim();
    chapters.push({
      title: chapterTitle || `第${chapters.length + 1}章`,
      text: bodyText,
    });
  }

  if (!chapters.length) throw new Error("EPUB 没有可读正文");
  return {
    title: (title || "").trim() || fallbackTitle,
    author: (author || "").trim(),
    format: "epub",
    chapters,
  };
}

function readEpubToc(files, opfDir, readText, manifest) {
  const toc = {};
  const navItem = Object.values(manifest).find(
    (i) => i.properties.split(/\s+/).includes("nav") || /nav\.xhtml$|toc\.xhtml$/i.test(i.href),
  );
  if (navItem) {
    const navPath = resolvePath(opfDir, navItem.href);
    const text = readText(navPath);
    if (text) {
      const navDir = posixDirname(navPath);
      for (const m of text.matchAll(/<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi)) {
        const href = decodeEntities(m[1]);
        const label = stripInline(m[2]).trim();
        if (href && label) toc[resolvePath(navDir, href)] = label;
      }
    }
  }

  const ncxItem = Object.values(manifest).find(
    (i) => i.mediaType === "application/x-dtbncx+xml" || i.href.toLowerCase().endsWith(".ncx"),
  );
  if (ncxItem) {
    const ncxPath = resolvePath(opfDir, ncxItem.href);
    const text = readText(ncxPath);
    if (text) {
      const base = posixDirname(ncxPath);
      for (const m of text.matchAll(/<navPoint\b[\s\S]*?<navLabel>\s*<text>([\s\S]*?)<\/text>\s*<\/navLabel>[\s\S]*?<content\b[^>]*src\s*=\s*["']([^"']+)["']/gi)) {
        const label = stripInline(m[1]).trim();
        const src = resolvePath(base, decodeEntities(m[2]));
        if (label && src && !toc[src]) toc[src] = label;
      }
    }
  }
  return toc;
}

/* ------------------------------ ZIP ------------------------------ */

function unzip(buf) {
  const eocd = findEocd(buf);
  if (eocd < 0) throw new Error("不是有效的 EPUB（找不到 ZIP 目录）");
  const count = buf.readUInt16LE(eocd + 10);
  let offset = buf.readUInt32LE(eocd + 16);
  const out = new Map();

  for (let i = 0; i < count; i++) {
    if (offset + 46 > buf.length || buf.readUInt32LE(offset) !== 0x02014b50) break;
    const flags = buf.readUInt16LE(offset + 8);
    const method = buf.readUInt16LE(offset + 10);
    const compSize = buf.readUInt32LE(offset + 20);
    const nameLen = buf.readUInt16LE(offset + 28);
    const extraLen = buf.readUInt16LE(offset + 30);
    const commentLen = buf.readUInt16LE(offset + 32);
    const localOffset = buf.readUInt32LE(offset + 42);
    const name = buf.toString(flags & 0x800 ? "utf8" : "latin1", offset + 46, offset + 46 + nameLen);

    if (localOffset + 30 <= buf.length && buf.readUInt32LE(localOffset) === 0x04034b50) {
      const localNameLen = buf.readUInt16LE(localOffset + 26);
      const localExtraLen = buf.readUInt16LE(localOffset + 28);
      const start = localOffset + 30 + localNameLen + localExtraLen;
      const data = buf.subarray(start, start + compSize);
      try {
        if (method === 0) out.set(normalizeZipPath(name), data);
        else if (method === 8) out.set(normalizeZipPath(name), zlib.inflateRawSync(data));
      } catch (e) {
        console.warn("[alighieri] ZIP 条目解压失败", name, e.message);
      }
    }
    offset += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

function findEocd(buf) {
  const start = Math.max(0, buf.length - 65557);
  for (let i = buf.length - 22; i >= start; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) return i;
  }
  return -1;
}

/* --------------------------- 公共工具 --------------------------- */

function normalizeText(raw) {
  return String(raw || "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .replace(/\u0000/g, "")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function stripHtml(html) {
  return normalizeText(
    String(html || "")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/(p|div|section|article|li|blockquote|pre|h[1-6]|tr|td|th|figcaption|ul|ol|table)>/gi, "\n")
      .replace(/<(p|div|section|article|li|blockquote|pre|h[1-6]|tr|td|th|figcaption|ul|ol|table)\b[^>]*>/gi, "\n")
      .replace(/<[^>]+>/g, "")
      .replace(/&nbsp;/gi, " "),
  )
    ? decodeEntities(
        String(html || "")
          .replace(/<br\s*\/?>/gi, "\n")
          .replace(/<\/(p|div|section|article|li|blockquote|pre|h[1-6]|tr|td|th|figcaption|ul|ol|table)>/gi, "\n")
          .replace(/<(p|div|section|article|li|blockquote|pre|h[1-6]|tr|td|th|figcaption|ul|ol|table)\b[^>]*>/gi, "\n")
          .replace(/<[^>]+>/g, "")
          .replace(/&nbsp;/gi, " "),
      )
        .replace(/[ \t]+\n/g, "\n")
        .replace(/\n{3,}/g, "\n\n")
        .trim()
    : "";
}

function stripInline(html) {
  return decodeEntities(String(html || "").replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();
}

function decodeEntities(s) {
  return String(s || "")
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => safeChar(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec) => safeChar(parseInt(dec, 10)))
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&");
}

function safeChar(code) {
  try {
    return String.fromCodePoint(code);
  } catch (_) {
    return "";
  }
}

function parseAttrs(raw) {
  const out = {};
  for (const m of String(raw || "").matchAll(/([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*["']([^"']*)["']/g)) {
    out[m[1].toLowerCase()] = m[2];
  }
  return out;
}

function firstTagText(xml, tag) {
  const m = new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)<\\/${tag}>`, "i").exec(xml);
  return m ? stripInline(m[1]) : "";
}

function firstTagInner(xml, tag) {
  const m = new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)<\\/${tag}>`, "i").exec(xml);
  return m ? m[1] : "";
}

function resolvePath(baseDir, href) {
  const clean = String(href || "").split("#")[0].split("?")[0];
  const decoded = safeDecodeUri(clean);
  const joined = decoded.startsWith("/")
    ? decoded.slice(1)
    : path.posix.join(baseDir || ".", decoded);
  return normalizeZipPath(path.posix.normalize(joined));
}

function safeDecodeUri(s) {
  try {
    return decodeURIComponent(s);
  } catch (_) {
    return s;
  }
}

function posixDirname(p) {
  return path.posix.dirname(normalizeZipPath(p));
}

function normalizeZipPath(p) {
  return String(p || "").replace(/\\/g, "/").replace(/^\.\//, "");
}

module.exports = {
  LocalLibrary,
  detectFormat,
  parseBook,
  decodeText,
  normalizeText,
  stripHtml,
  stripInline,
  decodeEntities,
};
