// 自检用插件:一个影视目录型数据源 + 一个设置面板。
ctx.sources.register("vod", {
  async categories() {
    return [
      { id: "movie", name: "电影", children: [{ id: "movie.action", name: "动作" }] },
      { id: "tv", name: "电视剧" },
    ];
  },
  async catalog(req) {
    const page = req.page || 1;
    const items = [];
    for (let i = 0; i < 12; i++) {
      const n = (page - 1) * 12 + i + 1;
      items.push({
        id: "v" + n, title: "自检片 " + n,
        badge: n % 3 === 0 ? "更新至 17 集" : "HD",
        year: "202" + (n % 6), score: (9.5 - n / 10).toFixed(1),
        isSeries: n % 2 === 0,
      });
    }
    return { items, hasMore: page < 3, total: 36 };
  },
  async mediaDetail(id) {
    return {
      id, title: "自检片详情 " + id, year: "2026", area: "内地", genre: "动作/悬疑",
      score: "9.1", badge: "全 24 集", director: "某导演", actors: "甲, 乙, 丙",
      overview: "这是一段用来验详情页排版的简介。资源站不是文件树,所以角标、年份、评分各占各的位置。",
      lines: [
        { id: "l1", name: "线路一", episodes: [
          { id: "e1", name: "第01集", raw: { url: "http://127.0.0.1:1/e1.mp4" } },
          { id: "e2", name: "第02集", raw: { url: "http://127.0.0.1:1/e2.mp4" } },
        ]},
        { id: "l2", name: "线路二", episodes: [
          { id: "e1b", name: "第01集", raw: { url: "http://127.0.0.1:1/e1b.mp4" } },
        ]},
      ],
    };
  },
  async listDir() { throw ctx.errors.unsupported("这个源是影视目录,不是文件树"); },
  async resolvePlay(entry) {
    const raw = entry.raw || {};
    return { url: raw.url || "", title: entry.name };
  },
});

ctx.extensions.register("panels", {
  id: "cfg", slot: "settings", title: "自检设置",
  async load() { return { hello: await ctx.storage.get("hello") }; },
});

ctx.onEnable(function () { ctx.log.info("自检插件已启用"); });
