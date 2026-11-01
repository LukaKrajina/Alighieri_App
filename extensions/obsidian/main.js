/**
 * Alighieri for Obsidian
 * ----------------------
 * 与 VS Code 插件同一套做法：把随包携带的 Alighieri Web 客户端挂在本机，
 * 用 iframe 打开，所以网络端功能与网站版完全一致。同一份引擎，换一种壳。
 *
 * 本地书架使用 Obsidian 插件目录下的 `library/`，支持 TXT / EPUB / Markdown / HTML，
 * 与网络书架分开保存。Obsidian 桌面端才有 Node 与本地端口，所以 manifest 标记 isDesktopOnly
 * ——移动端没有端口可开，就不凑这个热闹了。
 */
"use strict";

const {
  Plugin,
  ItemView,
  PluginSettingTab,
  Setting,
  Notice,
  addIcon,
} = require("obsidian");
const path = require("path");
const fs = require("fs");
const { LocalLibrary } = require("./shared/local-library");
const { createLocalServer } = require("./shared/server");

const CLIENT_VIEW = "alighieri-client-view";
const LOCAL_VIEW = "alighieri-local-view";
const FEATHER_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <path d="M7 25.5C9 15.2 15.6 7.7 25 4.3 23.1 12.5 16.7 20.2 7 25.5Z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/>
  <path d="M7 25.5 17.6 12.9" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" opacity=".75"/>
  <path d="M10.2 20.1 15.1 20.4M13.6 15.9 18.8 16.2" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" opacity=".65"/>
  <path d="M7 25.5 5.6 27.3" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
</svg>`;

const DEFAULT_SETTINGS = {
  port: 47832,
  autoStart: true,
};

class AlighieriView extends ItemView {
  constructor(leaf, plugin, route) {
    super(leaf);
    this.plugin = plugin;
    this.route = route;
  }

  getViewType() {
    return this.route === "/local" ? LOCAL_VIEW : CLIENT_VIEW;
  }

  getDisplayText() {
    return this.route === "/local" ? "Alighieri · 本地书架" : "Alighieri";
  }

  getIcon() {
    return "alighieri-feather";
  }

  async onOpen() {
    const root = this.containerEl.children[1] || this.contentEl;
    root.empty();
    root.addClass("alighieri-view");
    try {
      const handle = await this.plugin.ensureServer();
      const frame = root.createEl("iframe", {
        cls: "alighieri-frame",
        attr: {
          src: `${handle.url}${this.route}`,
          allow: "clipboard-read; clipboard-write; fullscreen",
          title: this.getDisplayText(),
        },
      });
      frame.addEventListener("load", () => this.plugin.onViewLoaded());
    } catch (err) {
      root.createEl("div", {
        cls: "alighieri-error",
        text: `Alighieri 本地服务启动失败：${err.message || err}`,
      });
    }
  }

  async onClose() {
    const root = this.containerEl.children[1] || this.contentEl;
    root.empty();
  }
}

class AlighieriSettingTab extends PluginSettingTab {
  constructor(app, plugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display() {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl("h2", { text: "Alighieri" });

    new Setting(containerEl)
      .setName("本地服务端口")
      .setDesc("网络客户端与本地书架都从这里加载。端口被占用时会自动向后寻找空闲端口。")
      .addText((text) =>
        text
          .setPlaceholder("47832")
          .setValue(String(this.plugin.settings.port || 47832))
          .onChange(async (value) => {
            const port = Number(value);
            if (!Number.isFinite(port) || port < 1024 || port > 65535) return;
            this.plugin.settings.port = port;
            await this.plugin.saveSettings();
          }),
      );

    new Setting(containerEl)
      .setName("打开 Obsidian 时启动本地服务")
      .setDesc("关闭后，第一次打开 Alighieri 面板时才会启动。")
      .addToggle((toggle) =>
        toggle.setValue(this.plugin.settings.autoStart !== false).onChange(async (value) => {
          this.plugin.settings.autoStart = value;
          await this.plugin.saveSettings();
        }),
      );

    new Setting(containerEl)
      .setName("打开")
      .setDesc("网络客户端包含投稿、书架、钱包、赛事、出版社、审查、同步状态等全部功能。")
      .addButton((btn) =>
        btn.setButtonText("网络客户端").onClick(() => this.plugin.activateView("/")),
      )
      .addButton((btn) =>
        btn.setButtonText("本地书架").onClick(() => this.plugin.activateView("/local")),
      );

    new Setting(containerEl)
      .setName("在浏览器打开")
      .setDesc("使用系统默认浏览器打开同一个本地客户端（共享同一份身份与数据）。")
      .addButton((btn) =>
        btn.setButtonText("打开浏览器").onClick(() => {
          this.plugin.ensureServer().then((handle) => window.open(handle.url, "_blank"));
        }),
      )
      .addButton((btn) =>
        btn.setButtonText("重启服务").onClick(() => this.plugin.restartServer()),
      );

    containerEl.createEl("p", {
      cls: "alighieri-settings-note",
      text: `本地书架保存在：${this.plugin.libraryRoot}`,
    });
  }
}

module.exports = class AlighieriPlugin extends Plugin {
  async onload() {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
    this.server = null;
    this.libraryRoot = this.resolveLibraryRoot();
    this.library = new LocalLibrary(this.libraryRoot).load();

    addIcon("alighieri-feather", FEATHER_SVG);
    this.registerView(CLIENT_VIEW, (leaf) => new AlighieriView(leaf, this, "/"));
    this.registerView(LOCAL_VIEW, (leaf) => new AlighieriView(leaf, this, "/local"));

    this.addRibbonIcon("alighieri-feather", "Alighieri", () => this.activateView("/"));

    this.addCommand({
      id: "alighieri-open-client",
      name: "打开网络客户端",
      callback: () => this.activateView("/"),
    });
    this.addCommand({
      id: "alighieri-open-local-library",
      name: "打开本地书架",
      callback: () => this.activateView("/local"),
    });
    this.addCommand({
      id: "alighieri-import-current-note",
      name: "导入当前笔记到本地书架",
      checkCallback: (checking) => {
        const file = this.app.workspace.getActiveFile();
        if (!file) return false;
        if (!/\.(md|markdown|mdown|txt|html?|xhtml)$/i.test(file.name)) return false;
        if (!checking) this.importCurrentNote(file);
        return true;
      },
    });
    this.addCommand({
      id: "alighieri-open-in-browser",
      name: "在浏览器中打开",
      callback: async () => {
        const handle = await this.ensureServer();
        window.open(handle.url, "_blank");
      },
    });
    this.addCommand({
      id: "alighieri-restart-server",
      name: "重启本地服务",
      callback: () => this.restartServer(),
    });

    this.addSettingTab(new AlighieriSettingTab(this.app, this));

    if (this.settings.autoStart !== false) {
      this.ensureServer().catch((err) => {
        console.error("[alighieri] 本地服务启动失败", err);
        new Notice(`Alighieri 本地服务启动失败：${err.message || err}`);
      });
    }
  }

  onunload() {
    if (this.server) {
      try {
        this.server.server.close();
      } catch (_) {}
      this.server = null;
    }
  }

  onViewLoaded() {
    // 视图刷新后不需要做额外事情；先占个钩子的位置，以后真要同步侧边栏时不用到处找。
  }

  resolveLibraryRoot() {
    const base = this.app.vault.adapter.getBasePath
      ? this.app.vault.adapter.getBasePath()
      : this.app.vault.adapter.basePath;
    const pluginDir = this.manifest.dir
      ? path.isAbsolute(this.manifest.dir)
        ? this.manifest.dir
        : path.join(base, this.manifest.dir)
      : path.join(base, ".obsidian", "plugins", this.manifest.id);
    return path.join(pluginDir, "library");
  }

  async saveSettings() {
    await this.saveData(this.settings);
  }

  async ensureServer() {
    if (this.server) return this.server;
    // 启动时自动拉起服务与用户立刻打开面板可能同时发生；
    // 共用一个 promise，避免在相邻端口上起两个节点、身份数据被拆到两个 origin
    // ——同一个人，两套身份，谁都不想要。
    if (this.serverPromise) return this.serverPromise;
    this.serverPromise = (async () => {
      const base = this.app.vault.adapter.getBasePath
        ? this.app.vault.adapter.getBasePath()
        : this.app.vault.adapter.basePath;
      const pluginDir = this.manifest.dir
        ? path.isAbsolute(this.manifest.dir)
          ? this.manifest.dir
          : path.join(base, this.manifest.dir)
        : path.join(base, ".obsidian", "plugins", this.manifest.id);

      const preferred = this.lastPort || Number(this.settings.port) || 47832;
      const handle = await createLocalServer({
        webRoot: path.join(pluginDir, "web"),
        uiRoot: path.join(pluginDir, "ui"),
        library: this.library,
        preferredPort: preferred,
        logger: {
          info: (msg) => console.log(msg),
          error: (msg, err) => console.error(msg, err),
        },
        onPort: (port) => {
          this.lastPort = port;
        },
      });
      this.server = handle;
      return handle;
    })();
    try {
      return await this.serverPromise;
    } finally {
      this.serverPromise = null;
    }
  }

  async restartServer() {
    if (this.server) {
      await new Promise((resolve) => this.server.server.close(resolve));
      this.server = null;
    }
    try {
      const handle = await this.ensureServer();
      new Notice(`Alighieri 本地服务已重启：${handle.url}`);
      for (const type of [CLIENT_VIEW, LOCAL_VIEW]) {
        for (const leaf of this.app.workspace.getLeavesOfType(type)) {
          if (leaf.view instanceof AlighieriView) leaf.view.onOpen();
        }
      }
    } catch (err) {
      new Notice(`重启失败：${err.message || err}`);
    }
  }

  async activateView(route) {
    const type = route === "/local" ? LOCAL_VIEW : CLIENT_VIEW;
    let leaf = this.app.workspace.getLeavesOfType(type)[0];
    if (!leaf) {
      leaf = this.app.workspace.getRightLeaf(false);
      if (!leaf) {
        new Notice("没有可用的侧栏，请先打开一个工作区。");
        return;
      }
      await leaf.setViewState({ type, active: true });
    }
    this.app.workspace.revealLeaf(leaf);
  }

  async importCurrentNote(file) {
    try {
      await this.ensureServer();
      const text = await this.app.vault.read(file);
      const book = this.library.importBytes(Buffer.from(text, "utf8"), file.name);
      new Notice(`已导入「${book.title}」到本地书架。`);
      await this.activateView("/local");
    } catch (err) {
      new Notice(`导入失败：${err.message || err}`);
    }
  }
};
