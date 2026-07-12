// Admin shell bootstrap and delegated UI event routing.
// Loaded as an ordered deferred browser script; shared bindings are declared in admin-core.js.


loginForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  loginMessage.textContent = "";
  const form = new FormData(loginForm);
  try {
    const data = await api("/auth/login", {
      method: "POST",
      body: {
        email: form.get("email"),
        password: form.get("password"),
      },
      auth: false,
    });
    state.token = data.token;
    state.user = data.user;
    state.view = data.user.role === "admin" ? "dashboard" : "aiNovels";
    localStorage.setItem("novelAdminToken", state.token);
    renderShell();
    await loadView();
  } catch (error) {
    loginMessage.textContent = error.message || "登录失败";
  }
});

logoutButton.addEventListener("click", () => {
  state.token = "";
  state.user = null;
  localStorage.removeItem("novelAdminToken");
  renderShell();
});

const sidebarToggle = document.querySelector("#sidebarToggle");
const sidebarCollapsedKey = "novelAdminSidebarCollapsed";

function setSidebarCollapsed(collapsed) {
  document.querySelector(".shell")?.classList.toggle("sidebar-collapsed", collapsed);
  if (!sidebarToggle) return;
  sidebarToggle.setAttribute("aria-expanded", String(!collapsed));
  sidebarToggle.setAttribute("aria-label", collapsed ? "展开导航" : "收起导航");
  sidebarToggle.title = collapsed ? "展开导航" : "收起导航";
}

if (sidebarToggle) {
  setSidebarCollapsed(localStorage.getItem(sidebarCollapsedKey) === "true");
  sidebarToggle.addEventListener("click", () => {
    const collapsed = !document.querySelector(".shell")?.classList.contains("sidebar-collapsed");
    setSidebarCollapsed(collapsed);
    localStorage.setItem(sidebarCollapsedKey, String(collapsed));
  });
}

document.querySelectorAll(".nav button").forEach((button) => {
  button.addEventListener("click", async () => {
    // The desktop shell has independent navigation and content scrolling.
    // Reset only the content pane so a short view cannot render below the
    // previous view's scroll position.
    document
      .querySelector(".workspace")
      ?.scrollTo({ top: 0, left: 0, behavior: "auto" });
    state.view = button.dataset.view;
    state.q = "";
    state.status = "";
    state.commentKeyword = "";
    state.danmakuKeyword = "";
    state.userVersionCode = 0;
    if (state.pages[state.view]) state.pages[state.view] = 1;
    state.chatSelection.clear();
    state.bili.results = [];
    state.bili.selectedSeason = null;
    state.bili.episodes = [];
    state.bili.selectedCid = 0;
    state.bili.sourceSummary = {};
    state.bili.selectedTargetVideoIds.clear();
    state.bili.searchError = "";
    searchInput.value = "";
    statusFilter.value = "";
    document
      .querySelectorAll(".nav button")
      .forEach((item) => item.classList.toggle("active", item === button));
    await loadView();
  });
});

refreshButton.addEventListener("click", () => loadView());
searchInput.addEventListener(
  "input",
  debounce(() => {
    state.q = searchInput.value.trim();
    if (state.view === "comments") {
      state.selected.comments.target = null;
      state.selected.comments.group = null;
      state.selected.comments.page = 1;
    } else if (state.view === "danmaku") {
      state.selected.danmaku.anime = null;
      state.selected.danmaku.episode = null;
      state.selected.danmaku.page = 1;
      state.bili.results = [];
      state.bili.selectedSeason = null;
      state.bili.episodes = [];
      state.bili.selectedCid = 0;
      state.bili.sourceSummary = {};
      state.bili.selectedTargetVideoIds.clear();
      state.bili.searchError = "";
    } else if (state.view === "chat") {
      state.chatSelection.clear();
    }
    if (state.pages[state.view]) state.pages[state.view] = 1;
    loadView();
  }, 300),
);
statusFilter.addEventListener("change", () => {
  state.status = statusFilter.value;
  if (state.view === "comments") {
    state.selected.comments.group = null;
    state.selected.comments.page = 1;
  } else if (state.view === "danmaku") {
    state.selected.danmaku.episode = null;
    state.selected.danmaku.page = 1;
    state.bili.results = [];
    state.bili.selectedSeason = null;
    state.bili.episodes = [];
    state.bili.selectedCid = 0;
    state.bili.sourceSummary = {};
    state.bili.selectedTargetVideoIds.clear();
    state.bili.searchError = "";
  } else if (state.view === "chat") {
    state.chatSelection.clear();
  }
  if (state.pages[state.view]) state.pages[state.view] = 1;
  loadView();
});

viewRoot.addEventListener("change", async (event) => {
  if (event.target?.id === "growthOpsDays") {
    state.growthOps.days = Number(event.target.value || 7);
    await renderGrowthOps();
    return;
  }
  if (event.target?.id === "growthOpsPeriod") {
    state.growthOps.period = event.target.value || "weekly";
    await renderGrowthOps();
    return;
  }
  if (event.target?.id === "growthOpsMetric") {
    state.growthOps.metric = event.target.value || "hot";
    await renderGrowthOps();
    return;
  }
  if (event.target?.id === "contentOpsType") {
    state.contentOps.type = event.target.value || "";
    await renderContentOps();
    return;
  }
  if (event.target?.id === "analyticsDays") {
    state.analytics.days = Number(event.target.value || 7);
    await renderAnalytics();
    return;
  }
  if (event.target?.id === "analyticsFatalOnly") {
    state.analytics.fatalOnly = Boolean(event.target.checked);
    await renderAnalytics();
    return;
  }
  if (event.target?.id === "asrProductType") {
    syncAsrHostDefault(event.target.value);
    return;
  }
  if (event.target?.id === "chatBotProvider") {
    syncChatBotProviderDefaults(event.target.value);
    return;
  }
  if (event.target?.id === "biliSyncFilter") {
    state.bili.syncFilter = event.target.value || "unsynced";
    state.selected.danmaku.episode = null;
    state.selected.danmaku.page = 1;
    state.bili.selectedTargetVideoIds.clear();
    await renderDanmaku();
    return;
  }
  if (event.target?.id === "biliEpisodeSelect") {
    state.bili.selectedCid = Number(event.target.value || 0);
    await loadBilibiliSourceSummary(state.bili.selectedCid);
    await renderDanmaku();
    return;
  }
  const biliTargetVideoId = event.target?.dataset?.biliTargetVideoId;
  if (biliTargetVideoId) {
    updateBiliTargetSelection(biliTargetVideoId, event.target.checked);
    refreshBiliSelectionUi();
    return;
  }
  const actionElement = event.target.closest("[data-action]");
  if (!actionElement) return;
  const action = actionElement.dataset.action;
  if (action !== "toggle-chat-selection") return;
  const id = Number(actionElement.dataset.id || 0);
  if (!id) return;
  if (actionElement.checked) {
    state.chatSelection.add(id);
  } else {
    state.chatSelection.delete(id);
  }
  await renderChat();
});

viewRoot.addEventListener("input", (event) => {
  if (event.target?.id !== "chatBotApiKey") return;
  const enabled = document.querySelector("#chatBotEnabled");
  if (enabled && event.target.value.trim()) enabled.checked = true;
});

viewRoot.addEventListener("click", async (event) => {
  const actionElement = event.target.closest("[data-action]");
  if (!actionElement) return;
  const action = actionElement.dataset.action;
  try {
    actionElement.disabled = true;
    await handleGrowthAction(action, actionElement);
    await handleContentAction(action, actionElement);
    await handleCommunityAction(action, actionElement);
    await handleOperationsAction(action, actionElement);
    await handleAiNovelAction(action, actionElement);
  } catch (error) {
    renderNotice(error.message || "操作失败", "error");
  } finally {
    actionElement.disabled = false;
  }
});

void init();

async function init() {
  if (state.token) {
    try {
      const data = await api("/auth/me");
      state.user = data.user;
      if (state.user.role !== "admin") state.view = "aiNovels";
    } catch {
      state.token = "";
      localStorage.removeItem("novelAdminToken");
    }
  }
  renderShell();
  if (state.user) await loadView();
}

function renderShell() {
  const authed = Boolean(state.user);
  const creatorOnly = authed && state.user.role !== "admin";
  loginPanel.classList.toggle("hidden", authed);
  appPanel.classList.toggle("hidden", !authed);
  logoutButton.classList.toggle("hidden", !authed);
  currentUser.textContent = authed
    ? `${state.user.nickname} (${state.user.email})`
    : "";
  document
    .querySelectorAll(".sidebar > .nav-section, .sidebar > .nav")
    .forEach((element) => {
      const allowed = element.classList.contains("creator-access");
      element.classList.toggle("hidden", creatorOnly && !allowed);
    });
  document.querySelectorAll(".nav button").forEach((button) => {
    button.classList.toggle("active", button.dataset.view === state.view);
  });
}

async function loadView() {
  const [title, hint] = viewMeta[state.view];
  viewTitle.textContent = title;
  viewHint.textContent = hint;
  toolbar.classList.toggle(
    "hidden",
    state.view === "dashboard" ||
      state.view === "proxy" ||
      state.view === "settings" ||
      state.view === "releases" ||
      state.view === "analytics" ||
      state.view === "growthOps" ||
      state.view === "aiNovels",
  );
  configureStatusFilter();
  renderLoading();

  if (state.view === "dashboard") await renderDashboard();
  if (state.view === "contentOps") await renderContentOps();
  if (state.view === "growthOps") await renderGrowthOps();
  if (state.view === "comments") await renderComments();
  if (state.view === "danmaku") await renderDanmaku();
  if (state.view === "chat") await renderChat();
  if (state.view === "users") await renderUsers();
  if (state.view === "versions") await renderVersions();
  if (state.view === "analytics") await renderAnalytics();
  if (state.view === "finance") await renderFinance();
  if (state.view === "race") await renderRace();
  if (state.view === "notifications") await renderNotifications();
  if (state.view === "releases") await renderReleases();
  if (state.view === "growth") await renderGrowth();
  if (state.view === "reports") await renderReports();
  if (state.view === "audit") await renderAudit();
  if (state.view === "proxy") await renderProxy();
  if (state.view === "settings") await renderSettings();
  if (state.view === "aiNovels") await renderAiNovels();
}
