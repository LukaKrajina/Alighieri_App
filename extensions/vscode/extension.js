/**
 * Alighieri for VS Code
 * ---------------------
 * 插件不重新实现 Alighieri 的协议：它把随包携带的 Web 客户端挂在 127.0.0.1 上，
 * 用 Webview 打开，因此网络客户端与网站版功能完全一致（P2P、钱包、赛事、协作…）。
 * 换句话说，这不是重写，只是换了个窗口。
 *
 * 本地书架是插件自己的功能：TXT / EPUB / Markdown / HTML 只落在这台设备，
 * 与网络书架互不干扰。完整界面在 `/local`，侧边栏同时提供原生列表。
 */
"use strict";

const vscode = require("vscode");
const path = require("path");
const fs = require("fs");
const { LocalLibrary } = require("./shared/local-library");
const { createLocalServer } = require("./shared/server");

const ctx = {
  context: null,
  server: null,
  library: null,
  tree: null,
  status: null,
  timer: null,
};

function activate(context) {
  ctx.context = context;
  const libraryRoot = path.join(context.globalStorageUri.fsPath, "local_library");
  ctx.library = new LocalLibrary(libraryRoot).load();

  ctx.tree = new LocalBooksTree(ctx.library);
  context.subscriptions.push(
    vscode.window.registerTreeDataProvider("alighieri.localBooks", ctx.tree),
  );

  ctx.status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  ctx.status.text = "$(book) Alighieri";
  ctx.status.tooltip = "打开 Alighieri 网络客户端";
  ctx.status.command = "alighieri.openClient";
  context.subscriptions.push(ctx.status);

  context.subscriptions.push(
    vscode.commands.registerCommand("alighieri.openClient", () => openPanel("Alighieri", "/")),
    vscode.commands.registerCommand("alighieri.openLocalLibrary", () =>
      openPanel("Alighieri · 本地书架", "/local"),
    ),
    vscode.commands.registerCommand("alighieri.openLocalBook", (id) =>
      openPanel("Alighieri · 本地书架", `/local?book=${encodeURIComponent(String(id))}`),
    ),
    vscode.commands.registerCommand("alighieri.importBook", importBooks),
    vscode.commands.registerCommand("alighieri.importCurrentFile", importCurrentFile),
    vscode.commands.registerCommand("alighieri.openInBrowser", openInBrowser),
    vscode.commands.registerCommand("alighieri.restartServer", restartServer),
    vscode.commands.registerCommand("alighieri.deleteLocalBook", deleteBook),
  );

  const config = vscode.workspace.getConfiguration("alighieri");
  if (config.get("autoStartServer", true)) {
    ensureServer().catch((err) => {
      vscode.window.showErrorMessage(`Alighieri 本地服务启动失败：${err.message || err}`);
    });
  }

  // 本地书架页面会直接改文件；侧边栏用低频轮询保持同步，5 秒一次，不打扰人。
  ctx.timer = setInterval(() => ctx.tree && ctx.tree.refresh(), 5000);
  context.subscriptions.push({
    dispose() {
      if (ctx.timer) clearInterval(ctx.timer);
      if (ctx.server) ctx.server.server.close();
    },
  });
}

function deactivate() {
  if (ctx.timer) clearInterval(ctx.timer);
  if (ctx.server) ctx.server.server.close();
  ctx.server = null;
}

async function ensureServer() {
  if (ctx.server) return ctx.server;
  if (ctx.starting) return ctx.starting;
  const context = ctx.context;
  if (!context) throw new Error("插件尚未激活");

  ctx.starting = (async () => {
    const config = vscode.workspace.getConfiguration("alighieri");
    const configured = Number(config.get("port", 47831)) || 47831;
    const remembered = Number(context.globalState.get("alighieri.port", 0)) || 0;
    const preferred = remembered || configured;

    const handle = await createLocalServer({
      webRoot: path.join(context.extensionPath, "web"),
      uiRoot: path.join(context.extensionPath, "ui"),
      library: ctx.library,
      preferredPort: preferred,
      logger: {
        info: (msg) => console.log(msg),
        error: (msg, err) => console.error(msg, err),
      },
      onPort: (port) => {
        context.globalState.update("alighieri.port", port);
      },
    });

    ctx.server = handle;
    if (ctx.status) {
      ctx.status.text = `$(book) Alighieri · ${handle.port}`;
      ctx.status.tooltip = handle.url;
      ctx.status.show();
    }
    return handle;
  })();

  try {
    return await ctx.starting;
  } finally {
    ctx.starting = null;
  }
}

function webviewHtml(url) {
  const origin = new URL(url).origin;
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src ${origin}; style-src 'unsafe-inline';">
<style>
  html, body { height: 100%; margin: 0; padding: 0; background: var(--vscode-editor-background); }
  iframe { display: block; width: 100%; height: 100%; border: 0; background: #fff; }
</style>
</head>
<body><iframe src="${url}" allow="clipboard-read; clipboard-write; fullscreen"></iframe></body>
</html>`;
}

async function openPanel(title, route) {
  const handle = await ensureServer();
  const panel = vscode.window.createWebviewPanel(
    "alighieri.client",
    title,
    vscode.ViewColumn.Active,
    {
      enableScripts: true,
      retainContextWhenHidden: true,
      enableFindWidget: true,
    },
  );
  panel.webview.html = webviewHtml(`${handle.url}${route}`);
  panel.onDidDispose(() => {
    if (ctx.tree) ctx.tree.refresh();
  });
  return panel;
}

async function importBooks() {
  try {
    await ensureServer();
  } catch (err) {
    vscode.window.showErrorMessage(`Alighieri 本地服务启动失败：${err.message || err}`);
    return;
  }
  const picked = await vscode.window.showOpenDialog({
    canSelectMany: true,
    openLabel: "导入到本地书架",
    filters: {
      书籍: ["txt", "epub", "md", "markdown", "mdown", "html", "htm", "xhtml"],
    },
  });
  if (!picked || !picked.length) return;

  let ok = 0;
  const failures = [];
  for (const uri of picked) {
    try {
      ctx.library.importFile(uri.fsPath, path.basename(uri.fsPath));
      ok++;
    } catch (err) {
      failures.push(`${path.basename(uri.fsPath)}: ${err.message || err}`);
    }
  }
  ctx.tree.refresh();
  if (ok) {
    const action = await vscode.window.showInformationMessage(
      `已导入 ${ok} 本到本地书架。`,
      "打开本地书架",
    );
    if (action) vscode.commands.executeCommand("alighieri.openLocalLibrary");
  }
  if (failures.length) {
    vscode.window.showWarningMessage(`有 ${failures.length} 个文件导入失败：${failures.slice(0, 3).join("；")}`);
  }
}

async function importCurrentFile() {
  const editor = vscode.window.activeTextEditor;
  if (!editor) {
    vscode.window.showInformationMessage("请先打开一个 Markdown / TXT 文件。");
    return;
  }
  try {
    await ensureServer();
    const doc = editor.document;
    const filePath = doc.uri.scheme === "file" ? doc.uri.fsPath : "";
    const name = filePath ? path.basename(filePath) : (path.basename(doc.fileName) || "note.md");
    if (filePath && fs.existsSync(filePath)) {
      ctx.library.importFile(filePath, name);
    } else {
      ctx.library.importBytes(Buffer.from(doc.getText(), "utf8"), name);
    }
    ctx.tree.refresh();
    const action = await vscode.window.showInformationMessage(
      `已导入「${name}」到本地书架。`,
      "打开本地书架",
    );
    if (action) vscode.commands.executeCommand("alighieri.openLocalLibrary");
  } catch (err) {
    vscode.window.showErrorMessage(`导入失败：${err.message || err}`);
  }
}

async function deleteBook(id) {
  const book = ctx.library.summaries().find((b) => b.id === id);
  if (!book) return;
  const answer = await vscode.window.showWarningMessage(
    `从本地书架删除「${book.title}」？正文与原始文件都会被移除，无法撤销。`,
    { modal: true },
    "删除",
  );
  if (answer !== "删除") return;
  ctx.library.delete(id);
  ctx.tree.refresh();
  vscode.window.showInformationMessage(`已删除「${book.title}」。`);
}

async function openInBrowser() {
  try {
    const handle = await ensureServer();
    await vscode.env.openExternal(vscode.Uri.parse(handle.url));
  } catch (err) {
    vscode.window.showErrorMessage(`无法打开浏览器：${err.message || err}`);
  }
}

async function restartServer() {
  if (ctx.server) {
    await new Promise((resolve) => ctx.server.server.close(resolve));
    ctx.server = null;
  }
  try {
    const handle = await ensureServer();
    vscode.window.showInformationMessage(`Alighieri 本地服务已重启：${handle.url}`);
  } catch (err) {
    vscode.window.showErrorMessage(`重启失败：${err.message || err}`);
  }
}

class LocalBooksTree {
  constructor(library) {
    this.library = library;
    this.emitter = new vscode.EventEmitter();
    this.onDidChangeTreeData = this.emitter.event;
  }

  refresh() {
    this.emitter.fire();
  }

  getTreeItem(book) {
    const item = new vscode.TreeItem(book.title, vscode.TreeItemCollapsibleState.None);
    const total = Math.max(1, book.chapterCount);
    const progress = book.chapterIndex > 0 ? ` · 读到 ${Math.min(book.chapterIndex + 1, total)}/${total}` : "";
    item.description = `${String(book.format || "txt").toUpperCase()} · ${book.chapterCount} 章${progress}`;
    item.tooltip = `${book.title}${book.author ? ` — ${book.author}` : ""}\n点击打开阅读器`;
    item.iconPath = new vscode.ThemeIcon("book");
    item.contextValue = "alighieri.localBook";
    item.command = {
      command: "alighieri.openLocalBook",
      title: "打开本地书籍",
      arguments: [book.id],
    };
    return item;
  }

  getChildren() {
    return this.library.summaries();
  }
}

module.exports = { activate, deactivate };