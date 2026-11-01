/* Alighieri 本地书架 —— 两个编辑器插件共用的页面逻辑，界面只有一份，省得两边各写各的 */
(() => {
  "use strict";

  const LANG = (navigator.language || "zh").toLowerCase().startsWith("zh") ? "zh" : "en";
  const T = {
    zh: {
      sub: "本地书架 · 只保存在这台设备上",
      heroTitle: "你的本地书架",
      heroBody:
        "导入 TXT、EPUB、Markdown 或 HTML。解析、分章和阅读进度都在这台设备上完成，不产生任何网络操作。",
      importBook: "导入书籍",
      importing: "正在导入",
      all: "全部",
      search: "搜索书名 / 作者",
      books: "本书",
      chapters: "话",
      words: "字",
      emptyTitle: "还没有本地书",
      emptyBody: "把你的 TXT / EPUB / Markdown 拖进来，或点右上角的「导入书籍」。导入后断网也能读。",
      imported: "已导入 {n} 本",
      failed: "导入失败",
      noReadable: "没有找到可读正文",
      readProgress: "读到第 {n} / {total} 话",
      notStarted: "还没开始读",
      toc: "目录",
      exportBook: "导出",
      prev: "上一章",
      next: "下一章",
      rename: "重命名",
      delete: "删除",
      deleteTitle: "删除这本书？",
      deleteBody: "正文与原始文件都会从本地书架移除，无法撤销。",
      title: "书名",
      author: "作者",
      save: "保存",
      cancel: "取消",
      renameTitle: "重命名",
      chapter: "第 {n} 话",
      wordCount: "{n} 字",
      percent: "已读 {n}%",
      storage: "本地书不会上传，也不会占用 Alighieri 的网络书架。",
      networkClient: "网络客户端",
      shelf: "书架",
      exportFail: "导出失败",
      importOk: "导入完成",
      reading: "阅读中",
    },
    en: {
      sub: "Local library · stays on this device",
      heroTitle: "Your local library",
      heroBody:
        "Import TXT, EPUB, Markdown or HTML. Parsing, chapters and reading progress all happen on this device — nothing is sent to the network.",
      importBook: "Import books",
      importing: "Importing",
      all: "All",
      search: "Search title / author",
      books: "books",
      chapters: "chapters",
      words: "words",
      emptyTitle: "No local books yet",
      emptyBody: "Drop your TXT / EPUB / Markdown files here, or use “Import books”. They stay readable offline.",
      imported: "Imported {n} book(s)",
      failed: "Import failed",
      noReadable: "No readable text found",
      readProgress: "Chapter {n} / {total}",
      notStarted: "Not started",
      toc: "Contents",
      exportBook: "Export",
      prev: "Previous",
      next: "Next",
      rename: "Rename",
      delete: "Delete",
      deleteTitle: "Delete this book?",
      deleteBody: "The text and the original file will be removed from this device. This cannot be undone.",
      title: "Title",
      author: "Author",
      save: "Save",
      cancel: "Cancel",
      renameTitle: "Rename",
      chapter: "Chapter {n}",
      wordCount: "{n} words",
      percent: "{n}% read",
      storage: "Local books are never uploaded and never join the Alighieri network shelf.",
      networkClient: "Network client",
      shelf: "Shelf",
      exportFail: "Export failed",
      importOk: "Import complete",
      reading: "Reading",
    },
  };
  const t = (key, params) => {
    let s = T[LANG][key] || T.zh[key] || key;
    if (params) for (const [k, v] of Object.entries(params)) s = s.replaceAll(`{${k}}`, String(v));
    return s;
  };

  const state = {
    books: [],
    filter: "",
    format: "",
    book: null,
    chapter: 0,
    active: false,
    saveTimer: 0,
    importBusy: false,
    font: Number(localStorage.getItem("alighieri.font") || 18),
    height: Number(localStorage.getItem("alighieri.height") || 1.9),
    theme: localStorage.getItem("alighieri.theme") || "auto",
  };

  const $ = (sel) => document.querySelector(sel);
  const el = {
    library: $("#library-view"),
    reader: $("#reader-view"),
    list: $("#book-list"),
    stats: $("#stats"),
    filter: $("#filter"),
    notice: $("#notice"),
    fileInput: $("#file-input"),
    importBtn: $("#import-btn"),
    importLabel: $("#import-label"),
    readerBody: $("#reader-body"),
    readerTitle: $("#reader-title"),
    chapterLabel: $("#chapter-label"),
    readPercent: $("#read-percent"),
    chapterCount: $("#chapter-count"),
    tocPanel: $("#toc-panel"),
    tocList: $("#toc-list"),
    scrim: $("#scrim"),
  };

  /* ------------------------------ 启动 ------------------------------ */

  applyTheme();
  applyReaderLook();
  bind();
  refresh().then(() => {
    const wanted = new URLSearchParams(location.search).get("book");
    if (wanted) openReader(wanted);
  });

  function bind() {
    $("#import-label").textContent = t("importBook");
    $("#brand-sub").textContent = t("sub");
    $("#hero-title").textContent = t("heroTitle");
    $("#hero-body").textContent = t("heroBody");
    $("#open-client").textContent = t("networkClient");
    $("#filter").placeholder = t("search");
    $("#storage-note").textContent = t("storage");
    $("#reader-back").lastChild.textContent = ` ${t("shelf")}`;
    $("#toc-btn").textContent = t("toc");
    $("#export-btn").textContent = t("exportBook");
    $("#prev-chapter").textContent = t("prev");
    $("#next-chapter").textContent = t("next");
    $("#toc-close").textContent = "×";

    el.importBtn.addEventListener("click", () => el.fileInput.click());
    el.fileInput.addEventListener("change", () => {
      const files = [...el.fileInput.files];
      el.fileInput.value = "";
      if (files.length) importFiles(files);
    });
    el.filter.addEventListener("input", () => {
      state.filter = el.filter.value.trim().toLowerCase();
      renderList();
    });
    $("#filters").addEventListener("click", (e) => {
      const chip = e.target.closest(".chip");
      if (!chip) return;
      state.format = chip.dataset.format || "";
      for (const c of $("#filters").children) c.classList.toggle("active", c === chip);
      renderList();
    });
    $("#open-client").addEventListener("click", () => {
      location.href = "/";
    });

    $("#reader-back").addEventListener("click", closeReader);
    $("#prev-chapter").addEventListener("click", () => gotoChapter(state.chapter - 1));
    $("#next-chapter").addEventListener("click", () => gotoChapter(state.chapter + 1));
    $("#toc-btn").addEventListener("click", openToc);
    $("#toc-close").addEventListener("click", closeToc);
    el.scrim.addEventListener("click", closeToc);
    $("#font-up").addEventListener("click", () => changeFont(1));
    $("#font-down").addEventListener("click", () => changeFont(-1));
    $("#theme-btn").addEventListener("click", cycleTheme);

    window.addEventListener("scroll", throttledProgress, { passive: true });
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "hidden") saveProgress();
    });
    window.addEventListener("beforeunload", () => saveProgress(true));

    document.addEventListener("keydown", (e) => {
      if (!state.active) return;
      if (e.key === "Escape") closeToc();
      if (e.key === "ArrowRight" && e.altKey) gotoChapter(state.chapter + 1);
      if (e.key === "ArrowLeft" && e.altKey) gotoChapter(state.chapter - 1);
    });
  }

  /* ------------------------------ 书库 ------------------------------ */

  async function refresh() {
    try {
      const res = await fetch("/api/local/books");
      const data = await res.json();
      state.books = (data.books || []).map(normalizeSummary);
      renderStats();
      renderList();
    } catch (err) {
      showNotice(`${t("failed")}: ${err.message || err}`, true);
    }
  }

  function normalizeSummary(b) {
    return {
      ...b,
      title: b.title || b.sourceName || "Untitled",
      chapterCount: Number(b.chapterCount || 0),
      wordCount: Number(b.wordCount || 0),
      chapterIndex: Number(b.chapterIndex || 0),
      scrollOffset: Number(b.scrollOffset || 0),
      importedAtMs: Number(b.importedAtMs || 0),
    };
  }

  function renderStats() {
    const totalChapters = state.books.reduce((n, b) => n + b.chapterCount, 0);
    const totalWords = state.books.reduce((n, b) => n + b.wordCount, 0);
    el.stats.innerHTML = "";
    for (const [value, label] of [
      [state.books.length, t("books")],
      [totalChapters, t("chapters")],
      [formatNumber(totalWords), t("words")],
    ]) {
      const div = document.createElement("div");
      div.className = "stat";
      div.innerHTML = `<b>${value}</b><span>${label}</span>`;
      el.stats.appendChild(div);
    }
  }

  function renderList() {
    const q = state.filter;
    const shown = state.books.filter((b) => {
      if (state.format && b.format !== state.format) return false;
      if (!q) return true;
      return `${b.title} ${b.author} ${b.sourceName}`.toLowerCase().includes(q);
    });
    el.list.innerHTML = "";
    if (!state.books.length) {
      el.list.innerHTML = `<div class="empty">
        <h3>${escapeHtml(t("emptyTitle"))}</h3>
        <p>${escapeHtml(t("emptyBody"))}</p>
        <button class="btn primary" id="empty-import">${escapeHtml(t("importBook"))}</button>
      </div>`;
      $("#empty-import").addEventListener("click", () => el.fileInput.click());
      return;
    }
    if (!shown.length) {
      el.list.innerHTML = `<div class="empty"><h3>${escapeHtml(t("emptyTitle"))}</h3>
        <p>${escapeHtml(LANG === "zh" ? "没有符合筛选条件的书。" : "No books match this filter.")}</p></div>`;
      return;
    }
    for (const b of shown) el.list.appendChild(bookCard(b));
  }

  function bookCard(b) {
    const total = Math.max(1, b.chapterCount);
    const read = Math.min(total, b.chapterIndex + 1);
    const percent = b.chapterCount ? Math.round((b.chapterIndex / total) * 100) : 0;
    const card = document.createElement("article");
    card.className = "book-card";
    card.innerHTML = `
      <div class="book-cover">${escapeHtml(b.format || "txt")}</div>
      <div class="book-main">
        <h3 class="book-title">${escapeHtml(b.title)}</h3>
        <p class="book-author">${escapeHtml(b.author || b.sourceName || "")}</p>
        <div class="book-meta">
          <span>${b.chapterCount} ${escapeHtml(t("chapters"))}</span>
          <span>${escapeHtml(t("wordCount", { n: formatNumber(b.wordCount) }))}</span>
        </div>
        <div class="book-progress">
          <div class="bar"><i style="width:${percent}%"></i></div>
          <small>${b.chapterIndex > 0 || b.scrollOffset > 0
            ? escapeHtml(t("readProgress", { n: read, total: b.chapterCount }))
            : escapeHtml(t("notStarted"))}</small>
        </div>
      </div>
      <button class="book-menu" title="更多">⋮</button>`;
    card.addEventListener("click", (e) => {
      if (e.target.closest(".book-menu")) return;
      openReader(b.id);
    });
    card.querySelector(".book-menu").addEventListener("click", (e) => {
      e.stopPropagation();
      openMenu(b);
    });
    return card;
  }

  /* ------------------------------ 导入 ------------------------------ */

  async function importFiles(files) {
    if (state.importBusy) return;
    state.importBusy = true;
    el.importBtn.disabled = true;
    let ok = 0;
    const errors = [];
    try {
      for (const file of files) {
        el.importLabel.textContent = `${t("importing")} · ${file.name}`;
        try {
          const data = await readBase64(file);
          const res = await fetch("/api/local/import", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name: file.name, data }),
          });
          const json = await res.json();
          if (!res.ok || !json.ok) throw new Error(json.error || t("noReadable"));
          ok++;
        } catch (err) {
          errors.push(`${file.name}: ${err.message || err}`);
        }
      }
    } finally {
      state.importBusy = false;
      el.importBtn.disabled = false;
      el.importLabel.textContent = t("importBook");
    }
    if (ok) {
      showNotice(t("imported", { n: ok }), false, true);
      await refresh();
    }
    if (errors.length) showNotice(`${t("failed")}\n${errors.slice(0, 4).join("\n")}`, true);
  }

  function readBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const result = String(reader.result || "");
        resolve(result.slice(result.indexOf(",") + 1));
      };
      reader.onerror = () => reject(reader.error || new Error("read failed"));
      reader.readAsDataURL(file);
    });
  }

  /* ------------------------------ 阅读器 ------------------------------ */

  async function openReader(id) {
    try {
      const res = await fetch(`/api/local/book?id=${encodeURIComponent(id)}`);
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "not found");
      const book = data.book;
      if (!book || !Array.isArray(book.chapters) || !book.chapters.length) {
        throw new Error(t("noReadable"));
      }
      state.book = book;
      state.chapter = clamp(Number(book.chapterIndex) || 0, 0, book.chapters.length - 1);
      state.active = true;
      el.library.hidden = true;
      el.reader.hidden = false;
      document.body.style.overflow = "auto";
      $("#export-btn").href = `/api/local/export?id=${encodeURIComponent(id)}`;
      const savedOffset = Number(book.scrollOffset || 0);
      renderChapter();
      window.scrollTo({ top: 0 });
      if (savedOffset > 0) {
        requestAnimationFrame(() => {
          const max = document.documentElement.scrollHeight - window.innerHeight;
          window.scrollTo({ top: Math.round(max * savedOffset) });
        });
      } else {
        await saveProgress();
      }
    } catch (err) {
      showNotice(`${t("failed")}: ${err.message || err}`, true);
    }
  }

  function closeReader() {
    saveProgress(true);
    state.active = false;
    state.book = null;
    el.reader.hidden = true;
    el.library.hidden = false;
    document.body.style.overflow = "";
    refresh();
  }

  function renderChapter() {
    const book = state.book;
    if (!book) return;
    const chapter = book.chapters[state.chapter];
    el.readerTitle.textContent = book.title;
    el.readerBody.innerHTML = "";
    const h = document.createElement("h2");
    h.textContent = chapter.title || t("chapter", { n: state.chapter + 1 });
    el.readerBody.appendChild(h);
    const paragraphs = splitParagraphs(chapter.text);
    for (const p of paragraphs) {
      const node = document.createElement("p");
      node.textContent = p;
      el.readerBody.appendChild(node);
    }
    el.chapterLabel.textContent = chapter.title || t("chapter", { n: state.chapter + 1 });
    el.chapterCount.textContent = `${state.chapter + 1} / ${book.chapters.length}`;
    const percent = book.chapters.length > 1
      ? Math.round((state.chapter / (book.chapters.length - 1)) * 100)
      : 100;
    el.readPercent.textContent = t("percent", { n: percent });
    $("#prev-chapter").disabled = state.chapter <= 0;
    $("#next-chapter").disabled = state.chapter >= book.chapters.length - 1;
    renderToc();
  }

  function splitParagraphs(text) {
    return String(text || "")
      .split(/\n+/)
      .map((s) => s.trim())
      .filter(Boolean);
  }

  function gotoChapter(next) {
    if (!state.book) return;
    const index = clamp(next, 0, state.book.chapters.length - 1);
    if (index === state.chapter) return;
    state.chapter = index;
    saveProgress(true);
    renderChapter();
    window.scrollTo({ top: 0 });
  }

  function throttledProgress() {
    if (!state.active || state.saveTimer) return;
    state.saveTimer = setTimeout(() => {
      state.saveTimer = 0;
      saveProgress();
    }, 800);
  }

  async function saveProgress(immediate) {
    const book = state.book;
    if (!book) return;
    const max = document.documentElement.scrollHeight - window.innerHeight;
    const offset = max > 0 ? clamp(window.scrollY / max, 0, 1) : 0;
    book.chapterIndex = state.chapter;
    book.scrollOffset = offset;
    try {
      await fetch("/api/local/progress", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: book.id, chapterIndex: state.chapter, scrollOffset: offset }),
        keepalive: Boolean(immediate),
      });
    } catch (_) {}
  }

  /* ------------------------------ 目录 / 设置 ------------------------------ */

  function openToc() {
    el.tocPanel.hidden = false;
    el.scrim.hidden = false;
  }

  function closeToc() {
    el.tocPanel.hidden = true;
    el.scrim.hidden = true;
  }

  function renderToc() {
    const book = state.book;
    if (!book) return;
    el.tocList.innerHTML = "";
    book.chapters.forEach((c, i) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = c.title || t("chapter", { n: i + 1 });
      if (i === state.chapter) b.classList.add("active");
      b.addEventListener("click", () => {
        gotoChapter(i);
        closeToc();
      });
      el.tocList.appendChild(b);
    });
  }

  function changeFont(delta) {
    state.font = clamp(state.font + delta, 14, 24);
    localStorage.setItem("alighieri.font", String(state.font));
    applyReaderLook();
  }

  function applyReaderLook() {
    document.documentElement.style.setProperty("--reader-size", `${state.font}px`);
    document.documentElement.style.setProperty("--reader-height", String(state.height));
  }

  function applyTheme() {
    if (state.theme === "auto") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = state.theme;
  }

  function cycleTheme() {
    state.theme = state.theme === "auto" ? "light" : state.theme === "light" ? "dark" : "auto";
    localStorage.setItem("alighieri.theme", state.theme);
    applyTheme();
  }

  /* ------------------------------ 菜单 ------------------------------ */

  function openMenu(book) {
    const modal = document.createElement("div");
    modal.className = "modal";
    modal.innerHTML = `
      <div class="modal-card">
        <h3>${escapeHtml(book.title)}</h3>
        <div class="modal-actions" style="justify-content:flex-start;flex-wrap:wrap">
          <button class="btn ghost" data-act="rename">${escapeHtml(t("rename"))}</button>
          <button class="btn ghost" data-act="export">${escapeHtml(t("exportBook"))}</button>
          <button class="btn ghost danger" data-act="delete">${escapeHtml(t("delete"))}</button>
          <button class="btn ghost" data-act="cancel" style="margin-left:auto">${escapeHtml(t("cancel"))}</button>
        </div>
      </div>`;
    document.body.appendChild(modal);
    const close = () => modal.remove();
    modal.addEventListener("click", (e) => {
      if (e.target === modal) return close();
      const act = e.target.closest("[data-act]")?.dataset.act;
      if (!act || act === "cancel") return close();
      close();
      if (act === "rename") return renameDialog(book);
      if (act === "export") return (location.href = `/api/local/export?id=${encodeURIComponent(book.id)}`);
      if (act === "delete") return deleteDialog(book);
    });
  }

  function renameDialog(book) {
    const modal = document.createElement("div");
    modal.className = "modal";
    modal.innerHTML = `
      <div class="modal-card">
        <h3>${escapeHtml(t("renameTitle"))}</h3>
        <div class="field"><label>${escapeHtml(t("title"))}</label><input id="m-title" value="${escapeAttr(book.title)}"></div>
        <div class="field"><label>${escapeHtml(t("author"))}</label><input id="m-author" value="${escapeAttr(book.author || "")}"></div>
        <div class="modal-actions">
          <button class="btn ghost" data-act="cancel">${escapeHtml(t("cancel"))}</button>
          <button class="btn primary" data-act="save">${escapeHtml(t("save"))}</button>
        </div>
      </div>`;
    document.body.appendChild(modal);
    const close = () => modal.remove();
    modal.addEventListener("click", async (e) => {
      if (e.target === modal) return close();
      const act = e.target.closest("[data-act]")?.dataset.act;
      if (!act || act === "cancel") return close();
      if (act === "save") {
        try {
          await fetch("/api/local/rename", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ id: book.id, title: $("#m-title").value, author: $("#m-author").value }),
          });
          close();
          await refresh();
        } catch (err) {
          showNotice(String(err.message || err), true);
        }
      }
    });
    setTimeout(() => $("#m-title")?.focus(), 50);
  }

  function deleteDialog(book) {
    const modal = document.createElement("div");
    modal.className = "modal";
    modal.innerHTML = `
      <div class="modal-card">
        <h3>${escapeHtml(t("deleteTitle"))}</h3>
        <p style="color:var(--muted);font-size:12.5px;line-height:1.7">${escapeHtml(t("deleteBody"))}</p>
        <div class="modal-actions">
          <button class="btn ghost" data-act="cancel">${escapeHtml(t("cancel"))}</button>
          <button class="btn primary" data-act="delete" style="background:var(--danger);color:#fff">${escapeHtml(t("delete"))}</button>
        </div>
      </div>`;
    document.body.appendChild(modal);
    const close = () => modal.remove();
    modal.addEventListener("click", async (e) => {
      if (e.target === modal) return close();
      const act = e.target.closest("[data-act]")?.dataset.act;
      if (!act || act === "cancel") return close();
      if (act === "delete") {
        try {
          await fetch("/api/local/delete", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ id: book.id }),
          });
          close();
          await refresh();
        } catch (err) {
          showNotice(String(err.message || err), true);
        }
      }
    });
  }

  /* ------------------------------ 小工具 ------------------------------ */

  function showNotice(message, isError, positive) {
    el.notice.hidden = false;
    el.notice.textContent = message;
    el.notice.classList.toggle("ok", Boolean(positive));
    el.notice.classList.toggle("danger", Boolean(isError));
    clearTimeout(showNotice.timer);
    showNotice.timer = setTimeout(() => {
      el.notice.hidden = true;
    }, isError ? 9000 : 4500);
  }

  function toast(message) {
    const node = document.createElement("div");
    node.className = "toast";
    node.textContent = message;
    document.body.appendChild(node);
    setTimeout(() => node.remove(), 2200);
  }

  function clamp(n, min, max) {
    return Math.min(max, Math.max(min, n));
  }

  function formatNumber(n) {
    return Number(n || 0).toLocaleString(LANG === "zh" ? "zh-CN" : "en-US");
  }

  function escapeHtml(s) {
    return String(s || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function escapeAttr(s) {
    return escapeHtml(s).replace(/'/g, "&#39;");
  }
})();
