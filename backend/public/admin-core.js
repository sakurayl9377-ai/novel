// Shared admin state, API client, formatting, and reusable view helpers.
// Loaded as an ordered deferred browser script; shared bindings are declared in admin-core.js.

const config = window.NOVEL_ADMIN_CONFIG || { apiPrefix: "/api" };
const defaultSpeechSettings = {
  asrProductType: "rtasr",
  asrHostUrls: {
    rtasr: "wss://rtasr.xfyun.cn/v1/ws",
    iat: "wss://iat-api.xfyun.cn/v2/iat",
    spark: "wss://iat-api.xfyun.cn/v2/iat",
  },
  ttsHostUrl: "wss://tts-api.xfyun.cn/v2/tts",
};
const nvidiaChatBotDefaults = {
  baseUrl: "https://integrate.api.nvidia.com/v1",
  model: "google/diffusiongemma-26b-a4b-it",
};
const state = {
  token: localStorage.getItem("novelAdminToken") || "",
  user: null,
  view: "dashboard",
  q: "",
  status: "",
  commentKeyword: "",
  danmakuKeyword: "",
  userVersionCode: 0,
  analytics: {
    days: 7,
    fatalOnly: false,
    q: "",
  },
  contentOps: {
    type: "",
    editPlacement: null,
    editFlag: null,
    preview: null,
  },
  videoOps: {
    categoryId: 0,
    kind: "",
    selectedId: "",
  },
  growthOps: {
    days: 7,
    period: "weekly",
    metric: "hot",
  },
  pages: {
    finance: 1,
    race: 1,
    notifications: 1,
    audit: 1,
    videoOps: 1,
  },
  chatSelection: new Set(),
  danmakuEpisodeItems: [],
  bili: {
    q: "",
    results: [],
    selectedSeason: null,
    episodes: [],
    selectedCid: 0,
    sourceSummary: {},
    limit: 800,
    syncFilter: "unsynced",
    selectedTargetVideoIds: new Set(),
    searchError: "",
  },
  selected: {
    comments: {
      target: null,
      group: null,
      page: 1,
    },
    danmaku: {
      anime: null,
      episode: null,
      page: 1,
    },
    chat: null,
    users: null,
    race: null,
  },
};

const viewMeta = {
  growthOps: ["增长运营", "管理规则推荐、内容榜单、活动任务、赛马赛季并查看真实转化漏斗。"],
  analytics: ["质量分析", "查看崩溃、卡顿帧、页面停留、加载耗时和关键功能成功率。"],
  dashboard: ["总览", "查看服务状态、活跃对象和待处理风险。"],
  comments: ["评论", "按作品、章节或集数管理评论与回复。"],
  contentOps: ["内容运营", "统一管理作品目录、首页推荐位、来源健康、缓存修订和功能灰度。"],
  videoOps: ["随便看视频", "管理影视与短剧目录、分类时段、HLS 线路候选和采集源同步。"],
  danmaku: ["弹幕", "按规范视频池管理弹幕，维护多个播放源共享关系。"],
  chat: ["聊天室", "按房间查看实时社区消息并处理违规内容。"],
  users: ["用户", "查看用户身份、活跃度、举报关系并执行封禁。"],
  versions: ["App 版本", "查看 APK 版本分布、升级覆盖率和最近活跃设备。"],
  finance: ["资金流水", "核对积分、樱花币发放与消耗，定位异常账变。"],
  race: ["赛马运营", "查看轮次、下注、赔付、庄家净额和公平性证明。"],
  notifications: ["通知发布", "向活跃用户发送系统通知并查看历史记录。"],
  releases: ["发布管理", "核对线上版本清单、APK 文件和可用备份。"],
  growth: ["成长体系", "管理等级周期、每日积分上限、权限与特效规则。"],
  reports: ["举报", "集中处理用户提交的内容和账号举报。"],
  audit: ["审计日志", "追踪管理员写操作、来源 IP、响应状态与请求编号。"],
  proxy: ["代理管理", "管理 Mihomo 服务、订阅更新、出口检测和策略组。"],
  settings: ["配置", "管理语音转写、长文本合成等服务密钥。"],
  aiNovels: [
    "AI 小说创作",
    "创作者上传小说和连载章节，管理员审核通过后自动发布到 App AI 创作区。",
  ],
};

const statusOptions = {
  comments: [
    ["visible", "可见"],
    ["deleted", "已删除"],
  ],
  danmaku: [
    ["visible", "可见"],
    ["deleted", "已删除"],
  ],
  chat: [
    ["visible", "可见"],
    ["deleted", "已删除"],
  ],
  users: [
    ["active", "正常"],
    ["banned", "封禁"],
  ],
  contentOps: [
    ["pending", "待审核"],
    ["active", "目录正常"],
    ["inactive", "目录停用"],
    ["missing", "来源缺失"],
  ],
  videoOps: [
    ["active", "已展示"],
    ["hidden", "已隐藏"],
  ],
  versions: [
    ["current", "当前版"],
    ["outdated", "旧版本"],
  ],
  race: [
    ["betting", "下注中"],
    ["locked", "已封盘"],
    ["racing", "比赛中"],
    ["settling", "结算中"],
  ],
  audit: [
    ["POST", "POST"],
    ["PATCH", "PATCH"],
    ["DELETE", "DELETE"],
  ],
  reports: [
    ["open", "待处理"],
    ["resolved", "已处理"],
    ["ignored", "已忽略"],
  ],
};

const loginPanel = document.querySelector("#loginPanel");
const appPanel = document.querySelector("#appPanel");
const loginForm = document.querySelector("#loginForm");
const loginMessage = document.querySelector("#loginMessage");
const logoutButton = document.querySelector("#logoutButton");
const currentUser = document.querySelector("#currentUser");
const viewTitle = document.querySelector("#viewTitle");
const viewHint = document.querySelector("#viewHint");
const viewRoot = document.querySelector("#viewRoot");
const toolbar = document.querySelector("#toolbar");
const searchInput = document.querySelector("#searchInput");
const statusFilter = document.querySelector("#statusFilter");
const refreshButton = document.querySelector("#refreshButton");

function configureStatusFilter() {
  const options = statusOptions[state.view];
  statusFilter.classList.toggle("hidden", !options);
  statusFilter.innerHTML = '<option value="">全部状态</option>';
  if (!options) return;
  for (const [value, label] of options) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label;
    statusFilter.append(option);
  }
  statusFilter.value = state.status;
}

function collectSettingsPayload() {
  const chatBotProvider = valueOf("#chatBotProvider") || "openai";
  const chatBotApiKey = valueOf("#chatBotApiKey");
  return {
    appAnnouncement: {
      title: valueOf("#appAnnouncementTitle") || "公告",
      content: valueOf("#appAnnouncementContent"),
      enabled: Boolean(document.querySelector("#appAnnouncementEnabled")?.checked),
    },
    iflytekAsr: {
      productType: valueOf("#asrProductType"),
      appId: valueOf("#asrAppId"),
      apiKey: valueOf("#asrApiKey"),
      secretKey: valueOf("#asrSecretKey"),
      hostUrl: valueOf("#asrHostUrl"),
      enabled: Boolean(document.querySelector("#asrEnabled")?.checked),
    },
    iflytekTts: {
      appId: valueOf("#ttsAppId"),
      apiKey: valueOf("#ttsApiKey"),
      apiSecret: valueOf("#ttsApiSecret"),
      hostUrl: valueOf("#ttsHostUrl"),
      enabled: Boolean(document.querySelector("#ttsEnabled")?.checked),
    },
    chatBot: {
      provider: chatBotProvider,
      baseUrl:
        chatBotProvider === "nvidia"
          ? nvidiaChatBotDefaults.baseUrl
          : valueOf("#chatBotBaseUrl"),
      apiKey: chatBotApiKey,
      model:
        chatBotProvider === "nvidia"
          ? nvidiaChatBotDefaults.model
          : valueOf("#chatBotModel"),
      botName: valueOf("#chatBotName") || "小樱",
      avatarUrl: valueOf("#chatBotAvatarUrl"),
      skinId: valueOf("#chatBotSkinId"),
      triggerMode: valueOf("#chatBotTriggerMode") || "mention",
      systemPrompt: valueOf("#chatBotSystemPrompt"),
      enabled: Boolean(document.querySelector("#chatBotEnabled")?.checked),
    },
  };
}

function configureChatBotProviderPresets(presets) {
  const nvidiaPreset = Array.isArray(presets)
    ? presets.find(
        (item) =>
          item?.provider === "nvidia" ||
          item?.id === "nvidia" ||
          item?.key === "nvidia",
      )
    : presets?.nvidia;
  if (!nvidiaPreset) return;

  const baseUrl = nvidiaPreset.baseUrl || nvidiaPreset.endpoint;
  const model = nvidiaPreset.model || nvidiaPreset.defaultModel;
  if (typeof baseUrl === "string" && baseUrl.trim()) {
    nvidiaChatBotDefaults.baseUrl = baseUrl.trim();
  }
  if (typeof model === "string" && model.trim()) {
    nvidiaChatBotDefaults.model = model.trim();
  }
}

function syncChatBotProviderDefaults(provider) {
  const isNvidia = provider === "nvidia";
  const baseUrl = document.querySelector("#chatBotBaseUrl");
  const model = document.querySelector("#chatBotModel");
  const apiKeyLabel = document.querySelector("#chatBotApiKeyLabel");
  const endpointHint = document.querySelector("#chatBotEndpointHint");

  if (baseUrl) {
    if (isNvidia) baseUrl.value = nvidiaChatBotDefaults.baseUrl;
    baseUrl.readOnly = isNvidia;
  }
  if (model) {
    if (isNvidia) model.value = nvidiaChatBotDefaults.model;
    model.readOnly = isNvidia;
  }
  if (apiKeyLabel) {
    apiKeyLabel.textContent = isNvidia ? "NVIDIA API Key" : "API Key";
  }
  if (endpointHint) {
    endpointHint.textContent = isNvidia
      ? "NVIDIA Build 接口和模型已自动配置，只需填写 API Key。"
      : "OpenAI/Claude 兼容模式可自行配置接口地址和模型。";
  }
}

async function testChatBot() {
  const status = document.querySelector("#chatBotTestStatus");
  const resultBox = document.querySelector("#chatBotTestResult");
  if (status) status.textContent = "测试中...";
  if (resultBox) {
    resultBox.classList.add("hidden");
    resultBox.textContent = "";
  }
  try {
    const data = await api("/admin/settings/chat-bot/test", {
      method: "POST",
      body: {
        message:
          valueOf("#chatBotTestInput") || "你好，小樱，连接成功了吗？",
        chatBot: collectSettingsPayload().chatBot,
      },
    });
    if (status) status.textContent = `连接成功 · ${data.provider || "openai"} · ${data.model || ""}`;
    if (resultBox) {
      resultBox.classList.remove("hidden");
      resultBox.textContent = data.reply || "测试成功，但没有返回文本";
    }
  } catch (error) {
    if (status) status.textContent = "连接失败";
    if (resultBox) {
      resultBox.classList.remove("hidden");
      resultBox.textContent = error.message || "机器人测试失败";
    }
  }
}

function collectUserAdminEditPayload() {
  const payload = {
    nickname: valueOf("#adminUserNickname"),
    signature: valueOf("#adminUserSignature"),
    bio: valueOf("#adminUserBio"),
    gender: valueOf("#adminUserGender"),
  };
  const points = valueOf("#adminUserPoints");
  const sakuraCoins = valueOf("#adminUserCoins");
  const sakuraCoinsDelta = valueOf("#adminUserCoinsDelta");
  if (points !== "") payload.points = Number(points);
  if (sakuraCoins !== "") payload.sakuraCoins = Number(sakuraCoins);
  if (sakuraCoinsDelta !== "") payload.sakuraCoinsDelta = Number(sakuraCoinsDelta);
  return payload;
}

function valueOf(selector) {
  return document.querySelector(selector)?.value.trim() || "";
}

function collectPlacementPayload() {
  return {
    placementType: valueOf("#placementType"),
    position: valueOf("#placementPosition"),
    contentKey: valueOf("#placementContentKey"),
    customTitle: valueOf("#placementTitle"),
    customImageUrl: valueOf("#placementImage"),
    sortOrder: Number(valueOf("#placementSort") || 0),
    startsAt: localDateTimeToIso(valueOf("#placementStartsAt")),
    endsAt: localDateTimeToIso(valueOf("#placementEndsAt")),
    status: valueOf("#placementStatus"),
    audience: parseJsonEditor(valueOf("#placementAudience"), "受众 JSON", {}),
    idempotencyKey: operationId("placement"),
  };
}

function collectFeatureFlagPayload() {
  return {
    value: parseJsonEditor(valueOf("#featureFlagValue"), "功能开关值", null),
    minVersionCode: Number(valueOf("#featureFlagMinVersion") || 0),
    maxVersionCode: Number(valueOf("#featureFlagMaxVersion") || 0),
    percentageRollout: Number(valueOf("#featureFlagPercentage") || 0),
    enabled: Boolean(document.querySelector("#featureFlagEnabled")?.checked),
    idempotencyKey: operationId("feature-flag"),
  };
}

function parseJsonEditor(text, label, fallback) {
  if (!text) return fallback;
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${label} 格式不正确`);
  }
}

function placementTypeOptions(selected) {
  return [
    ["banner", "Banner"],
    ["recommend", "推荐"],
    ["ranking", "榜单"],
  ]
    .map(([value, label]) => option(value, label, selected))
    .join("");
}

function placementStatusOptions(selected) {
  return [
    ["draft", "草稿"],
    ["active", "生效"],
    ["disabled", "停用"],
  ]
    .map(([value, label]) => option(value, label, selected))
    .join("");
}

function toLocalDateTimeValue(value) {
  if (!value) return "";
  const date = new Date(String(value).replace(" ", "T"));
  if (Number.isNaN(date.getTime())) return "";
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function localDateTimeToIso(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error("推荐位生效时间格式不正确");
  return date.toISOString();
}

function formatPlacementWindow(item) {
  if (!item.startsAt && !item.endsAt) return "长期生效";
  return `${item.startsAt ? formatTime(item.startsAt) : "立即"} - ${item.endsAt ? formatTime(item.endsAt) : "长期"}`;
}

function operationId(prefix) {
  const id = globalThis.crypto?.randomUUID?.() ||
    `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  return `${prefix}-${id}`;
}

function normalizeSpeechDefaults(defaults = {}) {
  return {
    ...defaultSpeechSettings,
    ...defaults,
    asrHostUrls: {
      ...defaultSpeechSettings.asrHostUrls,
      ...(defaults.asrHostUrls || {}),
    },
  };
}

function syncAsrHostDefault(nextProductType) {
  const input = document.querySelector("#asrHostUrl");
  if (!input) return;
  const knownDefaults = Object.values(defaultSpeechSettings.asrHostUrls);
  if (input.value.trim() && !knownDefaults.includes(input.value.trim())) return;
  input.value =
    defaultSpeechSettings.asrHostUrls[nextProductType] ||
    defaultSpeechSettings.asrHostUrls[defaultSpeechSettings.asrProductType];
}

function settingsOption(value, label, selected) {
  return `<option value="${escapeAttr(value)}" ${value === selected ? "selected" : ""}>${escapeHtml(label)}</option>`;
}

function secretPlaceholder(field) {
  return field?.configured ? "已配置，留空不修改" : "未配置";
}

function splitView({ listTitle, listHint, listTools = "", list, detail }) {
  return `
    <section class="split-view">
      <aside class="object-list">
        <div class="list-head">
          <h3>${escapeHtml(listTitle)}</h3>
          <p>${escapeHtml(listHint)}</p>
        </div>
        ${listTools}
        <div class="list-body">${list}</div>
      </aside>
      <section class="detail-pane">${detail}</section>
    </section>
  `;
}

function selectableItem({ active, action, attrs, title, meta, body }) {
  return `
    <button class="object-item ${active ? "active" : ""}"
      data-action="${action}" ${attrs}>
      <span class="object-title">${escapeHtml(title)}</span>
      <span class="object-meta">${escapeHtml(meta)}</span>
      <span class="object-body">${escapeHtml(body || "")}</span>
    </button>
  `;
}

function danmakuTargetSelectionTools() {
  const syncableCount = bilibiliSelectableTargets().length;
  const selectedCount = bilibiliBatchTargets().length;
  const unsyncedCount = (state.danmakuEpisodeItems || []).filter(
    (item) => (item.bilibiliSyncStatus || "unsynced") === "unsynced",
  ).length;
  return `
    <div class="selection-tools">
      <span id="biliTargetSelectionCount" class="mini-meta">${escapeHtml(biliSelectionLabel())}</span>
      <div class="action-row">
        <button class="button small" data-action="select-all-bili-targets" ${syncableCount ? "" : "disabled"}>全选当前筛选</button>
        <button class="button small muted" data-action="select-unsynced-bili-targets" ${unsyncedCount ? "" : "disabled"}>只选未同步</button>
        <button class="button small muted" data-action="clear-bili-targets" ${selectedCount ? "" : "disabled"}>清空选择</button>
      </div>
    </div>
  `;
}

function danmakuEpisodeTargetItem(item, active) {
  const status = item.bilibiliSyncStatus || "unsynced";
  const disabled = status === "synced";
  const key = biliTargetKey(item.videoId);
  const checked = state.bili.selectedTargetVideoIds.has(key);
  return `
    <div class="bili-target-item ${active ? "active" : ""} ${checked ? "selected" : ""} ${disabled ? "synced" : ""}">
      <label class="bili-target-check" title="${disabled ? "已同步，批量同步会跳过" : "加入批量同步"}">
        <input type="checkbox"
          data-bili-target-video-id="${escapeAttr(key)}"
          ${checked ? "checked" : ""}
          ${disabled ? "disabled" : ""} />
      </label>
      <button class="object-item ${active ? "active" : ""}"
        data-action="select-danmaku-episode"
        data-episode="${escapeAttr(JSON.stringify(item))}">
        <span class="object-title">${escapeHtml(item.episodeTitle)}</span>
        <span class="object-meta">${escapeHtml(`${item.danmakuCount} 条 · B站导入 ${item.bilibiliImportedCount || 0} 条 · ${labelBilibiliSyncStatus(status)} · ${formatTime(item.lastCreatedAt)}`)}</span>
        <span class="object-body">${escapeHtml(item.latestContent || "暂无弹幕预览")}</span>
      </button>
    </div>
  `;
}

function commentItem(item) {
  const isReply = Boolean(item.parentId);
  return `
    <article class="content-row ${isReply ? "is-reply" : ""}">
      <div class="row-main">
        <div class="row-meta">
          <strong>${escapeHtml(item.user?.nickname || "未知用户")}</strong>
          <span>${isReply ? `回复 #${item.parentId}` : "主评论"}</span>
          <span>${formatTime(item.createdAt)}</span>
          ${badge(labelStatus(item.status), item.status)}
        </div>
        <p>${escapeHtml(item.content)}</p>
        <div class="row-foot">
          <span>评分 ${item.rating || "-"}</span>
          <span>点赞 ${item.likeCount || 0}</span>
          <span>回复 ${item.replyCount || 0}</span>
        </div>
      </div>
      <div class="row-actions">
        <button class="button danger" data-action="delete-comment" data-id="${item.id}">删除</button>
      </div>
    </article>
  `;
}

function danmakuItem(item) {
  return `
    <article class="content-row">
      <div class="timecode">${formatMs(item.timeMs)}</div>
      <div class="row-main">
        <div class="row-meta">
          <strong>${escapeHtml(item.user?.nickname || "未知用户")}</strong>
          <span>${escapeHtml(item.mode || "scroll")}</span>
          <span>${formatTime(item.createdAt)}</span>
          ${badge(labelStatus(item.status), item.status)}
        </div>
        <p>${escapeHtml(item.content)}</p>
        <div class="row-foot">
          <span>${escapeHtml(item.videoId)}</span>
          <span style="color:${escapeAttr(item.color || "#111827")}">${escapeHtml(item.color || "")}</span>
        </div>
      </div>
      <div class="row-actions">
        <button class="button danger" data-action="delete-danmaku" data-id="${item.id}">删除</button>
      </div>
    </article>
  `;
}

function chatItem(item) {
  const checked = state.chatSelection?.has(Number(item.id)) ? "checked" : "";
  return `
    <article class="content-row chat-row">
      <label class="row-check">
        <input type="checkbox" data-action="toggle-chat-selection" data-id="${item.id}" ${checked} />
      </label>
      <div class="row-main">
        <div class="row-meta">
          <strong>${escapeHtml(item.user?.nickname || "未知用户")}</strong>
          <span>${escapeHtml(item.roomId)}</span>
          <span>${formatTime(item.createdAt)}</span>
          ${badge(labelStatus(item.status), item.status)}
        </div>
        <p>${escapeHtml(item.content)}</p>
      </div>
      <div class="row-actions">
        <button class="button danger" data-action="delete-chat" data-id="${item.id}">删除</button>
      </div>
    </article>
  `;
}

function bilibiliDanmakuPanel() {
  const selectedEpisode = state.selected.danmaku.episode;
  const selectedSeason = state.bili.selectedSeason;
  const batchTargets = bilibiliBatchTargets();
  const batchReady = Boolean(selectedSeason && batchTargets.length);
  return `
    <section class="section-block admin-panel bilibili-panel">
      <div class="section-title">
        <span>B站弹幕同步</span>
        <span class="mini-meta">均匀抽样，已同步集默认跳过</span>
      </div>
      ${biliWorkflowSteps(batchTargets)}
      <div class="compact-form">
        <input id="biliSearchInput" value="${escapeAttr(state.bili.q)}" placeholder="按番剧名称搜索 B站弹幕源" />
        <label>
          同步数量
          <input id="biliLimitInput" type="number" min="50" max="5000" step="50" value="${escapeAttr(state.bili.limit || 800)}" />
        </label>
        <label>
          目标状态
          <select id="biliSyncFilter">
            ${settingsOption("unsynced", "未同步", state.bili.syncFilter || "unsynced")}
            ${settingsOption("partial", "部分同步", state.bili.syncFilter || "unsynced")}
            ${settingsOption("synced", "已同步", state.bili.syncFilter || "unsynced")}
            ${settingsOption("all", "全部", state.bili.syncFilter || "unsynced")}
          </select>
        </label>
        <button class="button primary" data-action="search-bilibili">搜索源和本地作品</button>
        <button id="biliBatchButton" class="button" data-action="sync-bilibili-batch" ${batchReady ? "" : "disabled"}>批量同步 ${batchTargets.length || ""}</button>
      </div>
      <p id="biliBatchHint" class="muted-note bili-hint">${escapeHtml(biliBatchHint(batchTargets))}</p>
      <div class="bili-layout">
        <div class="mini-list">
          ${
            state.bili.results.length
              ? state.bili.results.map(bilibiliResultItem).join("")
              : empty("搜索后选择一个 B站番剧源")
          }
        </div>
        <div class="mini-list">
          ${
            selectedSeason
              ? bilibiliSeasonDetail(selectedSeason, selectedEpisode)
              : empty("选择番剧源后会显示集数")
          }
        </div>
      </div>
    </section>
  `;
}

function biliWorkflowSteps(batchTargets) {
  const hasSource = Boolean(state.bili.selectedSeason);
  const hasLocal = Boolean(state.selected.danmaku.anime);
  const hasTargets = Boolean(batchTargets.length);
  return `
    <div class="bili-flow">
      <span class="${hasSource ? "done" : ""}">1 B站源</span>
      <span class="${hasLocal ? "done" : ""}">2 本地作品</span>
      <span class="${hasTargets ? "done" : ""}">3 已选 ${batchTargets.length} 集</span>
    </div>
  `;
}

function bilibiliResultItem(item) {
  return `
    <button class="mini-item mini-button"
      data-action="select-bilibili-season"
      data-season-id="${escapeAttr(item.seasonId)}">
      <div>
        <strong>${escapeHtml(item.title)}</strong>
        <span>${escapeHtml([item.seasonType, item.areas, item.styles].filter(Boolean).join(" · "))}</span>
        <p>${escapeHtml(item.subtitle || "")}</p>
      </div>
      <span class="mini-meta">ss${escapeHtml(item.seasonId)}</span>
    </button>
  `;
}

function bilibiliSeasonDetail(season, selectedEpisode) {
  const selectedCid =
    Number(state.bili.selectedCid || 0) || Number((season.episodes || [])[0]?.cid || 0);
  const sourceSummary = state.bili.sourceSummary?.[selectedCid];
  const options = (season.episodes || [])
    .map(
      (item, index) =>
        `<option value="${escapeAttr(item.cid)}" ${Number(item.cid) === selectedCid ? "selected" : ""}>${escapeHtml(
          `${index + 1}. ${item.displayTitle || item.title}`,
        )}</option>`,
    )
    .join("");
  const sourceText = sourceSummary?.error
    ? `源总量读取失败：${sourceSummary.error}`
    : sourceSummary
      ? `B站源弹幕 ${sourceSummary.total || 0} 条`
      : "正在准备源弹幕总量";
  const targetText = selectedEpisode
    ? `目标：${selectedEpisode.episodeTitle} · 现有 ${selectedEpisode.danmakuCount || 0} 条 · B站导入 ${selectedEpisode.bilibiliImportedCount || 0} 条 · ${labelBilibiliSyncStatus(selectedEpisode.bilibiliSyncStatus)}`
    : "左侧先选择本地集数后可单集同步";
  return `
    <div class="mini-item">
      <div>
        <strong>${escapeHtml(season.title || `ss${season.seasonId}`)}</strong>
        <span>${escapeHtml(`${(season.episodes || []).length} 集可用 · ${sourceText}`)}</span>
        <p>${escapeHtml(targetText)}</p>
      </div>
    </div>
    <div class="compact-form">
      <select id="biliEpisodeSelect">${options}</select>
      <button class="button primary" data-action="sync-bilibili-current" ${selectedEpisode ? "" : "disabled"}>${selectedEpisode?.bilibiliImportedCount ? "重新同步当前集" : "同步到当前集"}</button>
    </div>
  `;
}

function chatModerationPanels({ keywords, violations, blockedIps }) {
  return `
    <section class="admin-panel-grid">
      <div class="section-block admin-panel">
        <div class="section-title"><span>聊天室屏蔽词</span></div>
        <div class="compact-form">
          <input id="chatKeywordInput" placeholder="新增屏蔽词" />
          <input id="chatKeywordNoteInput" placeholder="备注" />
          <button class="button primary" data-action="add-chat-keyword">新增</button>
        </div>
        <div class="mini-list">
          ${
            keywords.length
              ? keywords.map(chatKeywordItem).join("")
              : empty("暂无屏蔽词")
          }
        </div>
      </div>
      <div class="section-block admin-panel">
        <div class="section-title"><span>违规记录</span></div>
        <div class="mini-list">
          ${
            violations.length
              ? violations.map(chatViolationItem).join("")
              : empty("暂无违规记录")
          }
        </div>
      </div>
      <div class="section-block admin-panel">
        <div class="section-title"><span>注册 IP 黑名单</span></div>
        <div class="mini-list">
          ${
            blockedIps.length
              ? blockedIps.map(blockedIpItem).join("")
              : empty("暂无黑名单 IP")
          }
        </div>
      </div>
    </section>
  `;
}

function chatKeywordItem(item) {
  const nextStatus = item.status === "active" ? "inactive" : "active";
  const nextText = item.status === "active" ? "停用" : "启用";
  return `
    <div class="mini-item">
      <div>
        <strong>${escapeHtml(item.keyword)}</strong>
        <span>${escapeHtml(item.note || item.matchType || "")}</span>
      </div>
      <div class="action-row">
        ${badge(item.status === "active" ? "启用" : "停用", item.status)}
        <button class="button muted" data-action="toggle-chat-keyword" data-id="${item.id}" data-value="${nextStatus}">${nextText}</button>
        <button class="button danger" data-action="delete-chat-keyword" data-id="${item.id}">删除</button>
      </div>
    </div>
  `;
}

function chatViolationItem(item) {
  return `
    <div class="mini-item">
      <div>
        <strong>${escapeHtml(item.user?.nickname || item.user?.email || "用户")}</strong>
        <span>${escapeHtml(item.keyword ? `命中：${item.keyword}` : "违规消息")}</span>
        <p>${escapeHtml(item.content)}</p>
      </div>
      <div class="mini-meta">
        <span>${escapeHtml(item.roomId)}</span>
        <span>${escapeHtml(item.ip || "")}</span>
        <span>${formatTime(item.createdAt)}</span>
      </div>
    </div>
  `;
}

function blockedIpItem(item) {
  return `
    <div class="mini-item">
      <div>
        <strong>${escapeHtml(item.ip)}</strong>
        <span>${escapeHtml(item.reason || "blocked")}</span>
      </div>
      <div class="action-row">
        ${
          item.user
            ? `<span class="mini-meta">${escapeHtml(item.user.nickname || item.user.email || "")}</span>`
            : ""
        }
        <button class="button danger" data-action="delete-blocked-ip" data-ip="${escapeAttr(item.ip)}">移除</button>
      </div>
    </div>
  `;
}

function auditCompact(item) {
  return `
    <div class="compact-row">
      <strong>${escapeHtml(item.method || "-")}</strong>
      <span>${escapeHtml(item.path || "-")}</span>
      <small>${formatTime(item.created_at)}</small>
    </div>
  `;
}

function broadcastCompact(item) {
  return `
    <div class="compact-row">
      <strong>${escapeHtml(item.title || "通知")}</strong>
      <span>${escapeHtml(item.content || "")}</span>
      <small>${item.recipient_count || 0} 人 · ${formatTime(item.created_at)}</small>
    </div>
  `;
}

function broadcastItem(item) {
  return `
    <article class="broadcast-item">
      <div class="section-title">
        <span>${escapeHtml(item.title || "通知")}</span>
        ${badge(item.category || "system", "ignored")}
      </div>
      <p>${escapeHtml(item.content || "")}</p>
      <div class="row-foot">
        <span>接收 ${item.recipient_count || 0} 人</span>
        <span>发布人：${escapeHtml(item.nickname || item.email || "管理员")}</span>
        <span>${formatTime(item.created_at)}</span>
      </div>
    </article>
  `;
}

function labelRaceStatus(status) {
  return {
    betting: "下注中",
    locked: "已封盘",
    racing: "比赛中",
    settling: "结算中",
    settled: "已结算",
  }[status] || status || "未知";
}

function methodTone(method) {
  if (method === "DELETE") return "banned";
  if (method === "POST" || method === "PATCH") return "open";
  return "ignored";
}

function formatSigned(value) {
  const number = Number(value || 0);
  return number > 0 ? `+${number}` : String(number);
}

function userDetail(detail) {
  const user = detail.user;
  const nextStatus = user.status === "banned" ? "active" : "banned";
  const nextStatusText = user.status === "banned" ? "解封用户" : "封禁用户";
  const nextRole = user.role === "admin" ? "user" : "admin";
  const nextRoleText = user.role === "admin" ? "取消管理员" : "设为管理员";
  return `
    <div class="detail-header">
      <div>
        <h3>${escapeHtml(user.nickname)} #${user.id}</h3>
        <p>${escapeHtml(user.email)} · Lv${user.growth?.level || 1} ${escapeHtml(user.growth?.levelName || "")}</p>
      </div>
      <div class="action-row">
        <button class="button danger" data-action="user-status" data-id="${user.id}" data-value="${nextStatus}">${nextStatusText}</button>
        <button class="button" data-action="user-role" data-id="${user.id}" data-value="${nextRole}">${nextRoleText}</button>
      </div>
    </div>
    <div class="stat-row">
      ${miniStat("等级", `Lv${user.growth?.level || 1}`)}
      ${miniStat("积分", user.growth?.points || 0)}
      ${miniStat("樱花币", user.growth?.sakuraCoins || 0)}
      ${miniStat("日上限", user.growth?.dailyPointCap || 0)}
      ${miniStat("评论", user.stats.comments)}
      ${miniStat("弹幕", user.stats.danmaku)}
      ${miniStat("聊天", user.stats.chat)}
      ${miniStat("发起举报", user.stats.reports)}
      ${miniStat("被举报", user.stats.reported)}
    </div>
    <section class="section-block">
      <div class="section-title"><span>App 与设备</span></div>
      ${
        user.appInstall
          ? `<div class="app-install-detail">
              <span><small>APK 版本</small><strong>${escapeHtml(user.appInstall.versionName)} (#${user.appInstall.versionCode})</strong></span>
              <span><small>平台</small><strong>${escapeHtml(user.appInstall.platform || "未知")}</strong></span>
              <span><small>设备</small><strong>${escapeHtml(user.appInstall.deviceModel || "未知设备")}</strong></span>
              <span><small>系统</small><strong>${escapeHtml(user.appInstall.osVersion || "未知")}</strong></span>
              <span><small>最近上报</small><strong>${formatTime(user.appInstall.lastSeenAt)}</strong></span>
            </div>`
          : '<p class="muted-note">尚未上报版本；可能仍在使用 4.0.20 或更早版本，也可能尚未重新打开 App。</p>'
      }
    </section>
    <section class="section-block">
      <div class="section-title"><span>当前权益</span></div>
      <div class="permission-list">
        ${(user.growth?.effects || [])
          .filter((item) => item.unlocked)
          .flatMap((item) => item.permissions || [])
          .map((permission) => `<span>${escapeHtml(permission)}</span>`)
          .join("")}
      </div>
    </section>
    <section class="section-block admin-user-editor">
      <div class="section-title"><span>用户运营调整</span></div>
      <div class="compact-form">
        <label>
          昵称
          <input id="adminUserNickname" value="${escapeAttr(user.nickname || "")}" />
        </label>
        <label>
          性别
          <select id="adminUserGender">
            ${settingsOption("private", "隐私", user.gender || "private")}
            ${settingsOption("male", "男", user.gender || "private")}
            ${settingsOption("female", "女", user.gender || "private")}
          </select>
        </label>
        <label>
          成长值
          <input id="adminUserPoints" type="number" min="0" value="${escapeAttr(user.growth?.points || 0)}" />
        </label>
        <label>
          樱花币余额
          <input id="adminUserCoins" type="number" min="0" value="${escapeAttr(user.growth?.sakuraCoins || 0)}" />
        </label>
        <label>
          充值/扣除
          <input id="adminUserCoinsDelta" type="number" placeholder="正数充值，负数扣除" />
        </label>
      </div>
      <div class="compact-form">
        <label>
          签名
          <input id="adminUserSignature" value="${escapeAttr(user.signature || "")}" />
        </label>
        <label>
          简介
          <input id="adminUserBio" value="${escapeAttr(user.bio || "")}" />
        </label>
        <button class="button primary" data-action="save-user-admin-edit" data-id="${user.id}">保存用户调整</button>
      </div>
    </section>
    <section class="activity-grid">
      ${activityPanel("最近评论", detail.comments.map(commentItem).join("") || empty("暂无评论"))}
      ${activityPanel("最近弹幕", detail.danmaku.map(danmakuItem).join("") || empty("暂无弹幕"))}
      ${activityPanel("最近聊天", detail.chat.map(chatItem).join("") || empty("暂无聊天"))}
      ${activityPanel("发起举报", detail.reports.map(reportCompact).join("") || empty("暂无举报"))}
    </section>
  `;
}

function reportItem(item) {
  return `
    <article class="report-row">
      <div class="report-head">
        <div>
          <strong>${escapeHtml(reportTargetLabel(item))}</strong>
          <span>${escapeHtml(item.reason)}</span>
        </div>
        ${badge(labelStatus(item.status), item.status)}
      </div>
      ${reportPreview(item.preview)}
      <div class="row-foot">
        <span>举报人：${escapeHtml(item.reporter?.nickname || "匿名")}</span>
        <span>${formatTime(item.createdAt)}</span>
        ${
          item.handler
            ? `<span>处理人：${escapeHtml(item.handler.nickname)}</span>`
            : ""
        }
      </div>
      <div class="action-row">
        <button class="button primary" data-action="report-status" data-id="${item.id}" data-value="resolved">标记已处理</button>
        <button class="button muted" data-action="report-status" data-id="${item.id}" data-value="ignored">忽略</button>
        <button class="button danger" data-action="report-delete-target" data-id="${item.id}">删除目标并处理</button>
      </div>
    </article>
  `;
}

function reportPreview(preview) {
  if (!preview) return '<div class="preview-box">目标已不存在</div>';
  if (preview.type === "user") {
    return `<div class="preview-box">用户：${escapeHtml(preview.nickname)} · ${escapeHtml(preview.email)} · ${labelStatus(preview.status)}</div>`;
  }
  if (preview.type === "danmaku") {
    return `<div class="preview-box">${formatMs(preview.timeMs)} · ${escapeHtml(preview.content)}<br><small>${escapeHtml(preview.videoId)}</small></div>`;
  }
  if (preview.type === "chat") {
    return `<div class="preview-box">${escapeHtml(preview.content)}<br><small>${escapeHtml(preview.roomId)}</small></div>`;
  }
  return `<div class="preview-box">${escapeHtml(preview.content)}<br><small>${escapeHtml([preview.targetType, preview.targetId, preview.chapterId, preview.episodeId].filter(Boolean).join(" / "))}</small></div>`;
}

function aliasItem(item) {
  return `
    <div class="alias-item">
      <strong>${escapeHtml(item.sourceName || "播放源")}</strong>
      <span>${escapeHtml(item.aliasVideoId)}</span>
    </div>
  `;
}

function bucket(item, buckets) {
  const max = Math.max(...buckets.map((bucketItem) => bucketItem.count), 1);
  const height = Math.max(8, Math.round((item.count / max) * 44));
  return `<span class="bucket" title="${item.minute} 分钟：${item.count} 条" style="height:${height}px"></span>`;
}

function growthEventLabel(value) {
  return {
    exposure: "曝光",
    click: "点击",
    open: "打开详情",
    start: "开始阅读/观看",
    complete: "完读/完播",
    favorite: "收藏/追更",
  }[value] || value;
}

function growthRankingLabel(value) {
  return {
    hot: "热度榜",
    new: "新作榜",
    following: "追更榜",
    completion: "完读/完播榜",
  }[value] || value;
}

function growthActivityEventOptions() {
  return [
    ["exposure", "内容曝光"],
    ["click", "内容点击"],
    ["open", "打开详情"],
    ["start", "开始阅读/观看"],
    ["complete", "完读/完播"],
    ["favorite", "收藏/追更"],
    ["horse_race_bet", "赛马下注金额"],
    ["horse_race_round", "完成赛马轮次"],
    ["horse_race_win", "赛马获胜"],
  ].map(([value, label]) => option(value, label, "start")).join("");
}

function metric(label, value, hint = "", tone = "") {
  return `
    <div class="metric ${tone}">
      <span>${escapeHtml(label)}</span>
      <strong>${Number(value || 0)}</strong>
      ${hint ? `<small>${escapeHtml(hint)}</small>` : ""}
    </div>
  `;
}

function textMetric(label, value, hint = "", tone = "") {
  return `
    <div class="metric ${escapeAttr(tone)}">
      <span>${escapeHtml(label)}</span>
      <strong>${escapeHtml(value || "-")}</strong>
      ${hint ? `<small>${escapeHtml(hint)}</small>` : ""}
    </div>
  `;
}

function miniStat(label, value) {
  return `<span class="mini-stat"><b>${escapeHtml(value)}</b><small>${escapeHtml(label)}</small></span>`;
}

function pager({ type, page, totalPages, total, noun }) {
  const action = `${type}-page`;
  const prev = Math.max(1, page - 1);
  const next = Math.min(totalPages, page + 1);
  return `
    <div class="pager">
      <span>第 ${page} / ${totalPages} 页 · 共 ${total} ${escapeHtml(noun)}</span>
      <div>
        <button class="button" data-action="${action}" data-page="${prev}" ${page <= 1 ? "disabled" : ""}>上一页</button>
        <button class="button" data-action="${action}" data-page="${next}" ${page >= totalPages ? "disabled" : ""}>下一页</button>
      </div>
    </div>
  `;
}

function panel(title, body) {
  return `
    <section class="panel">
      <h3>${escapeHtml(title)}</h3>
      <div class="panel-body">${body}</div>
    </section>
  `;
}

function activityPanel(title, body) {
  return `
    <section class="activity-panel">
      <h4>${escapeHtml(title)}</h4>
      <div>${body}</div>
    </section>
  `;
}

function commentGroupCompact(item) {
  return compactRow(
    targetTitle(item),
    item.latestContent,
    `${item.commentCount} 条`,
  );
}

function danmakuGroupCompact(item) {
  return compactRow(
    item.episodeId || item.videoId,
    item.latestContent,
    `${item.danmakuCount} 条`,
  );
}

function chatRoomCompact(item) {
  return compactRow(item.roomId, item.latestContent, `${item.messageCount} 条`);
}

function reportCompact(item) {
  return compactRow(
    reportTargetLabel(item),
    item.reason,
    labelStatus(item.status),
  );
}

function compactRow(title, body, meta) {
  return `
    <div class="compact-row">
      <strong>${escapeHtml(title)}</strong>
      <span>${escapeHtml(body || "")}</span>
      <small>${escapeHtml(meta || "")}</small>
    </div>
  `;
}

function badge(text, tone = "") {
  return `<span class="badge ${escapeAttr(tone)}">${escapeHtml(text || "")}</span>`;
}

function targetTitle(item) {
  if (item.targetTitle || item.chapterTitle || item.episodeTitle) {
    return commentGroupTitle(item);
  }
  const type = labelTargetType(item.targetType);
  const leaf = item.episodeId || item.chapterId;
  return leaf
    ? `${type} ${item.targetId} / ${leaf}`
    : `${type} ${item.targetId}`;
}

function commentTargetTitle(item) {
  return (
    item.displayTitle ||
    item.targetTitle ||
    `${labelTargetType(item.targetType)} ${item.targetId}`
  );
}

function commentGroupTitle(item) {
  if (item.episodeTitle) return item.episodeTitle;
  if (item.chapterTitle) return item.chapterTitle;
  if (item.episodeId) return item.episodeId;
  if (item.chapterId) return item.chapterId;
  return item.targetTitle || `${labelTargetType(item.targetType)} ${item.targetId}`;
}

function commentGroupSubtitle(item) {
  return [
    item.targetTitle || `${labelTargetType(item.targetType)} ${item.targetId}`,
    item.chapterTitle && item.chapterTitle !== item.targetTitle
      ? item.chapterTitle
      : "",
    item.episodeTitle && item.episodeTitle !== item.targetTitle
      ? item.episodeTitle
      : "",
    item.lastCreatedAt ? `最近 ${formatTime(item.lastCreatedAt)}` : "",
  ]
    .filter(Boolean)
    .join(" · ");
}

function targetSubtitle(item) {
  return [
    labelTargetType(item.targetType),
    `目标 ${item.targetId}`,
    item.chapterId ? `章节 ${item.chapterId}` : "",
    item.episodeId ? `集数 ${item.episodeId}` : "",
    item.lastCreatedAt ? `最近 ${formatTime(item.lastCreatedAt)}` : "",
  ]
    .filter(Boolean)
    .join(" · ");
}

function labelTargetType(value) {
  return (
    {
      novel: "小说",
      manga: "漫画",
      anime: "动漫",
      chapter: "章节",
      episode: "剧集",
    }[value] || value
  );
}

function reportTargetLabel(item) {
  return `${labelReportType(item.targetType)} #${item.targetId}`;
}

function labelReportType(value) {
  return (
    {
      comment: "评论",
      danmaku: "弹幕",
      chat: "聊天",
      user: "用户",
    }[value] || value
  );
}

function labelRole(value) {
  return value === "admin" ? "管理员" : "用户";
}

function labelStatus(value) {
  return (
    {
      active: "正常",
      banned: "封禁",
      visible: "可见",
      deleted: "已删除",
      open: "待处理",
      resolved: "已处理",
      ignored: "已忽略",
    }[value] ||
    value ||
    ""
  );
}

function labelBilibiliSyncStatus(value) {
  return (
    {
      all: "全部",
      unsynced: "未同步",
      partial: "部分同步",
      synced: "已同步",
    }[value] ||
    value ||
    "未同步"
  );
}

function filterBilibiliSyncEpisodes(items) {
  const filter = state.bili.syncFilter || "unsynced";
  if (filter === "all") return items;
  return items.filter((item) => (item.bilibiliSyncStatus || "unsynced") === filter);
}

function biliTargetKey(videoId) {
  return String(videoId || "");
}

function isBiliSyncable(item) {
  return (item?.bilibiliSyncStatus || "unsynced") !== "synced";
}

function bilibiliSelectableTargets() {
  return (state.danmakuEpisodeItems || []).filter(isBiliSyncable);
}

function bilibiliBatchTargets() {
  const selectedIds = state.bili.selectedTargetVideoIds;
  return bilibiliSelectableTargets().filter((item) =>
    selectedIds.has(biliTargetKey(item.videoId)),
  );
}

function updateBiliTargetSelection(videoId, selected) {
  const key = biliTargetKey(videoId);
  if (!key) return;
  if (selected) {
    state.bili.selectedTargetVideoIds.add(key);
  } else {
    state.bili.selectedTargetVideoIds.delete(key);
  }
}

function replaceBiliTargetSelection(items) {
  state.bili.selectedTargetVideoIds = new Set(
    (items || []).filter(isBiliSyncable).map((item) => biliTargetKey(item.videoId)),
  );
}

function pruneBiliTargetSelection(items) {
  const validIds = new Set(
    (items || []).filter(isBiliSyncable).map((item) => biliTargetKey(item.videoId)),
  );
  [...state.bili.selectedTargetVideoIds].forEach((id) => {
    if (!validIds.has(id)) state.bili.selectedTargetVideoIds.delete(id);
  });
}

function biliSelectionLabel() {
  if (!state.selected.danmaku.anime) return "未选择本地作品";
  if (!(state.danmakuEpisodeItems || []).length) return "当前筛选无集数";
  const syncableCount = bilibiliSelectableTargets().length;
  if (!syncableCount) return "当前筛选无可同步集";
  return `已选 ${bilibiliBatchTargets().length}/${syncableCount} 集可同步`;
}

function biliBatchHint(targets = bilibiliBatchTargets()) {
  if (!state.bili.selectedSeason) return "先搜索并选择 B 站番剧源。";
  if (!state.selected.danmaku.anime) {
    return "再搜索并选择本地作品，勾选集数后可批量同步。";
  }
  if (!targets.length) return "勾选本地集数后可批量同步；已同步集会自动跳过。";
  return `将按本地集数顺序批量同步 ${targets.length} 集。`;
}

function refreshBiliSelectionUi() {
  const targets = bilibiliBatchTargets();
  const batchButton = document.querySelector("#biliBatchButton");
  if (batchButton) {
    batchButton.disabled = !(state.bili.selectedSeason && targets.length);
    batchButton.textContent = `批量同步 ${targets.length || ""}`.trim();
  }
  const count = document.querySelector("#biliTargetSelectionCount");
  if (count) count.textContent = biliSelectionLabel();
  const hint = document.querySelector("#biliBatchHint");
  if (hint) hint.textContent = biliBatchHint(targets);
  const clearButton = document.querySelector('[data-action="clear-bili-targets"]');
  if (clearButton) clearButton.disabled = !targets.length;
  document.querySelectorAll("[data-bili-target-video-id]").forEach((input) => {
    const checked = state.bili.selectedTargetVideoIds.has(
      biliTargetKey(input.dataset.biliTargetVideoId),
    );
    input.checked = checked;
    input.closest(".bili-target-item")?.classList.toggle("selected", checked);
  });
}

async function loadBilibiliSourceSummary(cid) {
  const numericCid = Number(cid || 0);
  if (!numericCid) return null;
  if (state.bili.sourceSummary?.[numericCid]) {
    return state.bili.sourceSummary[numericCid];
  }
  try {
    const summary = await api(
      `/admin/danmaku/bilibili/source/${encodeURIComponent(numericCid)}/summary`,
    );
    state.bili.sourceSummary[numericCid] = summary;
    return summary;
  } catch (error) {
    const summary = {
      cid: numericCid,
      total: 0,
      error: error.message || "读取失败",
    };
    state.bili.sourceSummary[numericCid] = summary;
    return summary;
  }
}

function makeQuery(values) {
  const params = new URLSearchParams();
  Object.entries(values).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== "") {
      params.set(key, value);
    }
  });
  const text = params.toString();
  return text ? `?${text}` : "";
}

async function api(path, options = {}) {
  const response = await fetch(`${config.apiPrefix}${path}`, {
    method: options.method || "GET",
    headers: {
      "Content-Type": "application/json",
      ...(options.auth === false || !state.token
        ? {}
        : { Authorization: `Bearer ${state.token}` }),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

function renderLoading() {
  viewRoot.innerHTML = '<div class="empty">加载中...</div>';
}

function renderNotice(message, tone = "") {
  viewRoot.insertAdjacentHTML(
    "afterbegin",
    `<div class="notice ${tone}">${escapeHtml(message)}</div>`,
  );
  setTimeout(() => {
    viewRoot.querySelector(".notice")?.remove();
  }, 3000);
}

function empty(text) {
  return `<div class="empty">${escapeHtml(text)}</div>`;
}

function parseJsonDataset(element, key) {
  return JSON.parse(element.dataset[key] || "{}");
}

function formatTime(value) {
  if (!value) return "-";
  const date = new Date(String(value).replace(" ", "T"));
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleString("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function formatBytes(value) {
  let bytes = Number(value || 0);
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let index = 0;
  while (bytes >= 1024 && index < units.length - 1) {
    bytes /= 1024;
    index += 1;
  }
  return `${bytes >= 10 || index === 0 ? bytes.toFixed(0) : bytes.toFixed(1)} ${units[index]}`;
}

function formatDuration(value) {
  let seconds = Math.max(0, Number(value || 0));
  const days = Math.floor(seconds / 86400);
  seconds %= 86400;
  const hours = Math.floor(seconds / 3600);
  seconds %= 3600;
  const minutes = Math.floor(seconds / 60);
  if (days) return `${days} 天 ${hours} 小时`;
  if (hours) return `${hours} 小时 ${minutes} 分`;
  return `${minutes} 分钟`;
}

function formatMs(value) {
  const ms = Number(value || 0);
  const seconds = Math.max(0, Math.floor(ms / 1000));
  const minute = Math.floor(seconds / 60);
  const second = seconds % 60;
  return `${minute}:${String(second).padStart(2, "0")}`;
}

function formatLatency(value) {
  const ms = Math.max(0, Number(value || 0));
  if (ms < 1000) return `${Math.round(ms)}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(ms < 10000 ? 1 : 0)}s`;
  const minutes = Math.floor(ms / 60000);
  const seconds = Math.floor((ms % 60000) / 1000);
  return `${minutes}m ${seconds}s`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("`", "&#96;");
}

function debounce(fn, wait) {
  let timer;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), wait);
  };
}
