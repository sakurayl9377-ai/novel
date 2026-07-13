// Suibian Kan video catalog, category availability, playback sources, and sync operations.

async function renderVideoOps() {
  const page = state.pages.videoOps || 1;
  const overview = await api(`/admin/video/overview${makeQuery({
    q: state.q,
    visibility: state.status,
    categoryId: state.videoOps.categoryId || "",
    kind: state.videoOps.kind,
    page,
    pageSize: 30,
  })}`);
  let detail = null;
  if (state.videoOps.selectedId) {
    detail = await api(`/admin/video/items/${encodeURIComponent(state.videoOps.selectedId)}`);
  }
  const source = overview.source || {};
  const scheduler = overview.scheduler || {};
  const totalPages = Math.max(1, Math.ceil((overview.total || 0) / (overview.pageSize || 30)));
  viewRoot.innerHTML = `
    <section class="content-ops-summary">
      ${metric("缓存视频", source.itemCount || 0, `${source.categoryCount || 0} 个分类`)}
      ${metric("当前结果", overview.total || 0, "目录搜索与筛选")}
      ${metric("短剧", overview.counts?.shorts || 0, "抖音式刷剧内容")}
      ${metric("人工隐藏", overview.counts?.hidden || 0, "不改写上游缓存")}
      ${textMetric("采集状态", source.lastError ? "异常" : "正常", source.lastSuccessAt ? `最近 ${formatTime(source.lastSuccessAt)}` : "等待首次同步", source.lastError ? "open" : "resolved")}
    </section>

    <section class="section-block video-source-strip">
      <div>
        <strong>DBZY MacCMS 采集源</strong>
        <span>${source.enabled ? "已启用" : "已停用"} · 缓存到期 ${formatTime(source.expiresAt)}</span>
        <small>自动同步：${scheduler.enabled ? `每 ${Math.round((scheduler.intervalMs || 0) / 60000)} 分钟 · 下次 ${formatTime(scheduler.nextRunAt)}` : "已停用"}${scheduler.running ? " · 正在同步" : ""}</small>
        ${source.lastError ? `<small>最近错误：${escapeHtml(source.lastError.code || "upstream_error")} · ${formatTime(source.lastError.at)}</small>` : ""}
      </div>
      <div class="content-action-row">
        <button class="button primary" data-action="refresh-video-source">手动增量刷新</button>
        <button class="button muted" data-action="open-video-comments">评论管理</button>
        <button class="button muted" data-action="open-video-danmaku">弹幕管理</button>
      </div>
    </section>

    <section class="section-block">
      <div class="section-title"><span>分类展示策略</span><small>服务端按时区判定，跨午夜时段受支持</small></div>
      <div class="video-policy-grid">
        ${(overview.categories || []).map(videoPolicyCard).join("") || empty("缓存中暂无分类")}
      </div>
    </section>

    <section class="video-catalog-toolbar">
      <label>板块<select id="videoKindFilter">
        <option value="">影视与短剧</option>
        <option value="movie" ${state.videoOps.kind === "movie" ? "selected" : ""}>主影视区</option>
        <option value="short" ${state.videoOps.kind === "short" ? "selected" : ""}>短剧刷剧区</option>
      </select></label>
      <label>分类<select id="videoCategoryFilter">
        <option value="0">全部分类</option>
        ${(overview.categories || []).map((item) => `<option value="${item.id}" ${Number(state.videoOps.categoryId) === item.id ? "selected" : ""}>${escapeHtml(item.name)}（${item.itemCount}）</option>`).join("")}
      </select></label>
      <span>${overview.total || 0} 条结果</span>
    </section>

    ${splitView({
      listTitle: "影视 / 短剧目录",
      listHint: "点击作品查看剧集和脱敏后的 HLS 候选线路。",
      list: `
        <div class="video-admin-list">
          ${(overview.items || []).map(videoCatalogItem).join("") || empty("当前筛选没有视频")}
        </div>
        ${pager({ type: "videoOps", page, totalPages, total: overview.total || 0, noun: "条视频" })}`,
      detail: detail ? videoDetail(detail) : empty("选择一条视频查看详情、剧集和线路健康状态"),
    })}
  `;
}

function videoPolicyCard(item) {
  const policy = item.policy || {};
  const availability = item.availability || {};
  return `
    <article class="video-policy-card ${availability.available ? "available" : "closed"}">
      <div class="section-title">
        <span>${escapeHtml(item.name)} <small>#${item.id} · ${item.itemCount} 条</small></span>
        ${badge(availability.available ? "当前展示" : "当前隐藏", availability.available ? "resolved" : "open")}
      </div>
      <div class="compact-form">
        <label>策略<select id="videoPolicyMode-${item.id}">
          <option value="always" ${policy.mode === "always" ? "selected" : ""}>始终展示</option>
          <option value="hidden" ${policy.mode === "hidden" ? "selected" : ""}>始终隐藏</option>
          <option value="scheduled" ${policy.mode === "scheduled" ? "selected" : ""}>每日时段</option>
        </select></label>
        <label>开始<input id="videoPolicyStart-${item.id}" type="time" value="${escapeAttr(policy.dailyStart || "00:00")}" /></label>
        <label>结束<input id="videoPolicyEnd-${item.id}" type="time" value="${escapeAttr(policy.dailyEnd || "23:59")}" /></label>
        <label>时区<input id="videoPolicyTimezone-${item.id}" value="${escapeAttr(policy.timezone || "Asia/Hong_Kong")}" /></label>
        <label class="inline-check"><input id="videoPolicyAge-${item.id}" type="checkbox" ${policy.ageRestricted ? "checked" : ""} /><span>年龄限制</span></label>
      </div>
      <button class="button muted" data-action="save-video-policy" data-category-id="${item.id}">保存策略</button>
    </article>`;
}

function videoCatalogItem(item) {
  return `
    <button class="video-admin-row ${state.videoOps.selectedId === item.id ? "selected" : ""}" data-action="select-video-item" data-id="${escapeAttr(item.id)}">
      ${item.coverUrl ? `<img src="${escapeAttr(item.coverUrl)}" alt="" loading="lazy" />` : '<span class="video-cover-placeholder">影</span>'}
      <span><strong>${escapeHtml(item.title)}</strong><small>${escapeHtml(item.categoryName || item.category)} · ${item.episodeCount || 0} 集 · ${item.sourceCount || 0} 条线路</small><small>${escapeHtml(item.remarks || item.year || "")}</small></span>
      ${badge(item.visibility === "hidden" ? "已隐藏" : "展示中", item.visibility === "hidden" ? "open" : "resolved")}
    </button>`;
}

function videoDetail(item) {
  return `
    <div class="detail-header video-detail-header">
      <div><h3>${escapeHtml(item.title)}</h3><p>${escapeHtml(item.categoryName || "未分类")} · ${item.episodeCount || 0} 集 · 更新 ${formatTime(item.updatedAt)}</p></div>
      ${badge(item.category === "short" ? "短剧" : "影视", item.category === "short" ? "open" : "resolved")}
    </div>
    <p class="video-summary">${escapeHtml(item.summary || "暂无简介")}</p>
    <div class="detail-actions">
      <input id="videoOverrideNote" value="${escapeAttr(item.overrideNote || "")}" placeholder="隐藏/恢复说明（写入审计）" />
      <button class="button ${item.visibility === "hidden" ? "primary" : "danger"}" data-action="toggle-video-visibility" data-id="${escapeAttr(item.id)}" data-visibility="${item.visibility === "hidden" ? "active" : "hidden"}">${item.visibility === "hidden" ? "恢复展示" : "隐藏内容"}</button>
    </div>
    <section class="section-block video-episodes">
      <div class="section-title"><span>剧集与 HLS 候选</span><small>仅展示线路域名，不泄露完整 URL 或查询参数</small></div>
      ${(item.episodes || []).map((episode) => `
        <details>
          <summary><strong>${escapeHtml(episode.title)}</strong><span>${episode.candidates.length} 条候选</span></summary>
          <div class="video-candidate-list">
            ${episode.candidates.map((candidate) => `<div><span><strong>${escapeHtml(candidate.name)}</strong><small>${escapeHtml(candidate.host || "无效域名")}</small></span><span>${badge(candidate.health === "ready" ? "可参与测速" : "无效", candidate.health === "ready" ? "resolved" : "open")}<small>${escapeHtml(candidate.protocol.toUpperCase())} · ${escapeHtml(candidate.format)}</small></span></div>`).join("")}
          </div>
        </details>`).join("") || empty("该内容暂无可用剧集")}
    </section>`;
}

async function handleVideoAction(action, actionElement) {
  if (action === "select-video-item") {
    state.videoOps.selectedId = actionElement.dataset.id;
    await renderVideoOps();
  } else if (action === "toggle-video-visibility") {
    await api(`/admin/video/items/${encodeURIComponent(actionElement.dataset.id)}/visibility`, {
      method: "PATCH",
      body: { visibility: actionElement.dataset.visibility, note: valueOf("#videoOverrideNote") },
    });
    renderNotice(actionElement.dataset.visibility === "hidden" ? "视频已隐藏" : "视频已恢复");
    await renderVideoOps();
  } else if (action === "save-video-policy") {
    const id = actionElement.dataset.categoryId;
    await api(`/admin/video/categories/${id}/policy`, {
      method: "PATCH",
      body: {
        mode: valueOf(`#videoPolicyMode-${id}`),
        dailyStart: valueOf(`#videoPolicyStart-${id}`),
        dailyEnd: valueOf(`#videoPolicyEnd-${id}`),
        timezone: valueOf(`#videoPolicyTimezone-${id}`),
        ageRestricted: Boolean(document.querySelector(`#videoPolicyAge-${id}`)?.checked),
      },
    });
    renderNotice("分类展示策略已保存");
    await renderVideoOps();
  } else if (action === "refresh-video-source") {
    await api("/admin/video/source/refresh", { method: "POST" });
    renderNotice("增量采集已完成");
    await renderVideoOps();
  } else if (action === "videoOps-page") {
    state.pages.videoOps = Number(actionElement.dataset.page || 1);
    state.videoOps.selectedId = "";
    await renderVideoOps();
  } else if (action === "open-video-comments") {
    await navigateAdminView("comments");
  } else if (action === "open-video-danmaku") {
    await navigateAdminView("danmaku");
  }
}

async function navigateAdminView(view) {
  state.view = view;
  state.q = "";
  state.status = "";
  searchInput.value = "";
  document.querySelectorAll(".nav button").forEach((button) => button.classList.toggle("active", button.dataset.view === view));
  await loadView();
}
