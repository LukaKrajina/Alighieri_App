/**
 * Alighieri 扩展端本地服务器
 * --------------------------
 * 两个插件端（VSCode / Obsidian）共用：
 *   /                 Alighieri Web 客户端（随插件打包的静态站）
 *   /local            本地书架（TXT / EPUB / Markdown / HTML）
 *   /api/local/*      本地书库的读写接口
 *
 * 只监听 127.0.0.1，不对外暴露；端口被占用时自动向上找空闲端口，
 * 一般爬几层就能落脚。
 * 不设置 CORS 头 —— 页面与接口同源，其它站点无法读取返回内容。
 */
"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");
const { URL } = require("url");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".htm": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".map": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json",
  ".wasm": "application/wasm",
};

function createLocalServer(options) {
  const {
    webRoot,
    uiRoot,
    library,
    preferredPort = 47831,
    portAttempts = 20,
    logger = console,
    onPort,
  } = options;

  const server = http.createServer((req, res) => {
    let url;
    try {
      url = new URL(req.url, "http://127.0.0.1");
    } catch (_) {
      return sendText(res, 400, "Bad request");
    }
    const pathname = safeDecode(url.pathname);

    if (pathname.startsWith("/api/local/")) {
      return handleApi(req, res, pathname, library, logger);
    }

    // 旧的赞助入口统一跳到关于我们，赞助退役后改行做自我介绍。
    if (pathname === "/sponsor" || pathname === "/sponsor/") {
      res.writeHead(302, { Location: "/about" });
      return res.end();
    }
    if (pathname === "/about" || pathname === "/about/") {
      return serveFile(res, path.join(uiRoot, "about.html"));
    }

    if (pathname === "/local" || pathname === "/local/") {
      return serveFile(res, path.join(uiRoot, "local.html"));
    }
    if (pathname === "/local.js") {
      return serveFile(res, path.join(uiRoot, "local.js"));
    }
    if (pathname === "/local.css") {
      return serveFile(res, path.join(uiRoot, "local.css"));
    }
    if (pathname === "/local-icon.svg") {
      return serveFile(res, path.join(uiRoot, "icon.svg"));
    }

    return serveWeb(req, res, pathname, webRoot);
  });

  function listen(port, remaining) {
    return new Promise((resolve, reject) => {
      const onError = (err) => {
        server.removeListener("listening", onListening);
        if (err.code === "EADDRINUSE" && remaining > 0) {
          resolve(listen(port + 1, remaining - 1));
        } else {
          reject(err);
        }
      };
      const onListening = () => {
        server.removeListener("error", onError);
        const actualPort = server.address().port;
        const url = `http://127.0.0.1:${actualPort}`;
        if (onPort) onPort(actualPort);
        logger.info(`[alighieri] 本地服务已启动：${url}`);
        resolve({ server, port: actualPort, url });
      };
      server.once("error", onError);
      server.once("listening", onListening);
      server.listen(port, "127.0.0.1");
    });
  }

  return listen(preferredPort, portAttempts);
}

/* ----------------------------- 静态资源 ----------------------------- */

function serveWeb(req, res, pathname, webRoot) {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return sendText(res, 405, "Method not allowed");
  }
  if (!webRoot || !fs.existsSync(webRoot)) {
    return sendHtml(
      res,
      503,
      `<!doctype html><meta charset="utf-8"><title>Alighieri</title>
       <body style="font:16px/1.7 system-ui;padding:48px;max-width:720px;margin:auto">
       <h1>Alighieri 客户端尚未打包</h1>
       <p>请先运行 <code>scripts/build-extensions.ps1</code>，它会把 Web 静态站复制到插件目录。</p>
       <p><a href="/local">仍然可以打开本地书架 →</a></p>`,
    );
  }

  let file = path.join(webRoot, pathname.replace(/^\/+/, ""));
  if (!isInside(webRoot, file)) return sendText(res, 403, "Forbidden");

  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    // Next.js 静态导出把每个路由放在独立目录；尾斜杠与无尾斜杠都接受，不必为它较真。
    const routeIndex = path.join(file, "index.html");
    if (fs.existsSync(routeIndex)) {
      file = routeIndex;
    } else if (!path.extname(pathname)) {
      // 客户端路由（如 /novel?id=… 之外的路径）统一回落到首页，迷路的都送回家。
      file = path.join(webRoot, "index.html");
    } else {
      return sendText(res, 404, "Not found");
    }
  }
  return serveFile(res, file, req);
}

function serveFile(res, file, req) {
  fs.stat(file, (err, stat) => {
    if (err || !stat.isFile()) return sendText(res, 404, "Not found");
    const type = MIME[path.extname(file).toLowerCase()] || "application/octet-stream";
    res.writeHead(200, {
      "Content-Type": type,
      "Content-Length": stat.size,
      "Cache-Control": file.includes(`${path.sep}_next${path.sep}`)
        ? "public, max-age=31536000, immutable"
        : "no-cache",
      "X-Content-Type-Options": "nosniff",
    });
    if (req && req.method === "HEAD") return res.end();
    fs.createReadStream(file).pipe(res);
  });
}

/* ------------------------------- API ------------------------------- */

function handleApi(req, res, pathname, library, logger) {
  try {
    if (req.method === "GET") {
      if (pathname === "/api/local/books") {
        return sendJson(res, 200, { ok: true, books: library.summaries() });
      }
      if (pathname === "/api/local/book") {
        const id = new URL(req.url, "http://127.0.0.1").searchParams.get("id") || "";
        return sendJson(res, 200, { ok: true, book: library.open(id) });
      }
      if (pathname === "/api/local/export") {
        const id = new URL(req.url, "http://127.0.0.1").searchParams.get("id") || "";
        const book = library.exportJson(id);
        res.writeHead(200, {
          "Content-Type": "application/json; charset=utf-8",
          "Content-Disposition": `attachment; filename="${safeFileName(book.title || id)}.json"`,
        });
        return res.end(JSON.stringify(book, null, 2));
      }
      return sendJson(res, 404, { ok: false, error: "未知接口" });
    }

    if (req.method !== "POST") return sendJson(res, 405, { ok: false, error: "Method not allowed" });

    readJson(req, 160 * 1024 * 1024)
      .then((body) => {
        if (pathname === "/api/local/import") {
          const name = String(body.name || "book.txt");
          const data = Buffer.from(String(body.data || ""), "base64");
          if (!data.length) throw new Error("文件是空的");
          const book = library.importBytes(data, name);
          return sendJson(res, 200, { ok: true, book: stripChapters(book) });
        }
        if (pathname === "/api/local/progress") {
          const summary = library.saveProgress(body.id, body.chapterIndex, body.scrollOffset);
          return sendJson(res, summary ? 200 : 404, { ok: Boolean(summary), book: summary });
        }
        if (pathname === "/api/local/rename") {
          const summary = library.rename(body.id, body.title, body.author);
          return sendJson(res, summary ? 200 : 404, { ok: Boolean(summary), book: summary });
        }
        if (pathname === "/api/local/delete") {
          return sendJson(res, 200, library.delete(body.id));
        }
        return sendJson(res, 404, { ok: false, error: "未知接口" });
      })
      .catch((err) => {
        logger.error("[alighieri] 本地书库接口失败", err);
        sendJson(res, 400, { ok: false, error: String(err.message || err) });
      });
    return;
  } catch (err) {
    logger.error("[alighieri] 本地书库接口异常", err);
    return sendJson(res, 400, { ok: false, error: String(err.message || err) });
  }
}

function readJson(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error("请求体过大"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"));
      } catch (err) {
        reject(new Error("请求体不是合法 JSON"));
      }
    });
    req.on("error", reject);
  });
}

function stripChapters(book) {
  const copy = { ...book };
  delete copy.chapters;
  return copy;
}

/* ------------------------------ 工具 ------------------------------ */

function sendJson(res, status, data) {
  const body = Buffer.from(JSON.stringify(data));
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": body.length,
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(body);
}

function sendText(res, status, text) {
  const body = Buffer.from(text);
  res.writeHead(status, {
    "Content-Type": "text/plain; charset=utf-8",
    "Content-Length": body.length,
  });
  res.end(body);
}

function sendHtml(res, status, html) {
  const body = Buffer.from(html);
  res.writeHead(status, {
    "Content-Type": "text/html; charset=utf-8",
    "Content-Length": body.length,
  });
  res.end(body);
}

function isInside(root, file) {
  const relative = path.relative(root, file);
  return !relative.startsWith("..") && !path.isAbsolute(relative);
}

function safeDecode(value) {
  try {
    return decodeURIComponent(value);
  } catch (_) {
    return value;
  }
}

function safeFileName(name) {
  return String(name || "book").replace(/[\\/:*?"<>|]/g, "_").slice(0, 80);
}

module.exports = { createLocalServer };
