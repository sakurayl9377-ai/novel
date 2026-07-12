// User, comment, danmaku, chat, version, and report operations.
// Loaded as an ordered deferred browser script; shared bindings are declared in admin-core.js.

async function renderComments() {
  const selected = state.selected.comments;
  if (!state.q) {
    selected.target = null;
    selected.group = null;
    selected.page = 1;
    viewRoot.innerHTML = `
      <section class="empty-workbench">
        <h3>搜索后管理评论</h3>
        <p>输入小说、漫画、动漫名称或章节/集数关键词。后台不会默认展开全部评论对象，先定位作品，再查看当前作品下的章节或集数评论。</p>
        <div class="empty-steps">
          <span>1 搜索作品</span>
          <span>2 选择章节/集数</span>
          <span>3 分页处理评论</span>
        </div>
      </section>
    `;
    return;
  }

  if (!selected.target) {
    const data = await api(
      `/admin/comments/target-search${makeQuery({
        q: state.q,
        status: state.status || "visible",
      })}`,
    );
    viewRoot.innerHTML = splitView({
      listTitle: "搜索结果",
      listHint: "按作品聚合，先选择一个作品",
      list: data.items?.length
        ? data.items
            .map((item) =>
              selectableItem({
                active: false,
                action: "select-comment-target",
                attrs: `data-target="${escapeAttr(JSON.stringify(item))}"`,
                title: commentTargetTitle(item),
                meta: `${item.commentCount} 条 · ${item.userCount} 人 · ${formatTime(item.lastCreatedAt)}`,
                body: `${labelTargetType(item.targetType)} · ${item.latestContent || "暂无预览"}`,
              }),
            )
            .join("")
        : empty("没有匹配作品"),
      detail: empty("选择左侧作品后显示它的章节或集数，不会一次展开全部评论对象"),
    });
    return;
  }

  const groupData = await api(
    `/admin/comments/targets/detail${makeQuery({
      targetType: selected.target.targetType,
      targetId: selected.target.targetId,
      q: state.q,
      status: state.status || "visible",
    })}`,
  );
  if (
    selected.group &&
    !groupData.items.some((item) => item.key === selected.group.key)
  ) {
    selected.group = null;
    selected.page = 1;
  }

  let detailHtml = `
    <div class="detail-header">
      <div>
        <h3>${escapeHtml(commentTargetTitle(selected.target))}</h3>
        <p>${escapeHtml(`${labelTargetType(selected.target.targetType)} · ID ${selected.target.targetId} · ${groupData.items.length} 个评论分组`)}</p>
      </div>
      <button class="button muted" data-action="clear-comment-selection">返回搜索结果</button>
    </div>
    ${empty("左侧选择一个章节或集数后分页查看评论")}
  `;

  if (selected.group) {
    const detail = await api(
      `/admin/comments/groups/detail${makeQuery({
        targetType: selected.group.targetType,
        targetId: selected.group.targetId,
        chapterId: selected.group.chapterId,
        episodeId: selected.group.episodeId,
        q: state.commentKeyword,
        status: state.status || "visible",
        page: selected.page,
        pageSize: 30,
      })}`,
    );
    const pagerHtml = pager({
      type: "comment",
      page: detail.page,
      totalPages: detail.totalPages,
      total: detail.total,
      noun: "条评论",
    });
    detailHtml = `
      <div class="detail-header">
        <div>
          <h3>${escapeHtml(commentGroupTitle(detail.group))}</h3>
          <p>${escapeHtml(commentGroupSubtitle(detail.group))}</p>
        </div>
        <div class="stat-row">
          ${miniStat("评论", detail.group.commentCount)}
          ${miniStat("主帖", detail.group.threadCount)}
          ${miniStat("回复", detail.group.replyCount)}
          ${miniStat("评分", detail.group.ratingAvg ?? "-")}
        </div>
      </div>

      <div class="detail-filter">
        <input id="commentKeywordInput" value="${escapeAttr(state.commentKeyword)}" placeholder="在当前章节/集数中搜索评论关键词或用户" />
        <button class="button primary" data-action="apply-comment-keyword">查询</button>
        <button class="button muted" data-action="clear-comment-keyword">清空</button>
      </div>

      ${pagerHtml}
      <div class="timeline-list">
        ${
          detail.items.length
            ? detail.items.map(commentItem).join("")
            : empty("当前筛选下没有评论")
        }
      </div>
      ${pagerHtml.replace('class="pager"', 'class="pager pager-bottom"')}
    `;
  }

  viewRoot.innerHTML = splitView({
    listTitle: commentTargetTitle(selected.target),
    listHint: "左侧只展示当前作品的章节或集数",
    list: groupData.items?.length
      ? groupData.items
          .map((item) =>
            selectableItem({
              active: selected.group?.key === item.key,
              action: "select-comment-group",
              attrs: `data-group="${escapeAttr(JSON.stringify(item))}"`,
              title: commentGroupTitle(item),
              meta: `${item.commentCount} 条 · ${item.userCount} 人 · ${formatTime(item.lastCreatedAt)}`,
              body: item.latestContent,
            }),
          )
          .join("")
      : empty("当前作品没有匹配评论分组"),
    detail: detailHtml,
  });
}

async function renderDanmaku() {
  const selected = state.selected.danmaku;
  if (!state.q) {
    selected.anime = null;
    selected.episode = null;
    selected.page = 1;
    state.danmakuEpisodeItems = [];
    state.bili.selectedTargetVideoIds.clear();
    viewRoot.innerHTML = `
      ${bilibiliDanmakuPanel()}
      <section class="empty-workbench">
        <h3>搜索后管理弹幕</h3>
        <p>输入番剧名称、动漫 ID、集数名称、播放源或弹幕关键词。后台不会默认加载全部视频池，避免上千集和上万条弹幕一起挤到页面里。</p>
        <div class="empty-steps">
          <span>1 搜索作品</span>
          <span>2 选择集数</span>
          <span>3 分页筛选弹幕</span>
        </div>
      </section>
    `;
    return;
  }

  if (!selected.anime) {
    state.danmakuEpisodeItems = [];
    state.bili.selectedTargetVideoIds.clear();
    const data = await api(
      `/admin/danmaku/anime-search${makeQuery({
        q: state.q,
        status: state.status || "visible",
      })}`,
    );
    const localItems = data.items || [];
    const selectedBiliTitle = state.bili.selectedSeason?.title || "";
    const localMatchDetail = selectedBiliTitle
      ? `
        <div class="section-block">
          <div class="section-title"><span>已选 B站源</span></div>
          <div class="mini-item">
            <div>
              <strong>${escapeHtml(selectedBiliTitle)}</strong>
              <span>${escapeHtml(`ss${state.bili.selectedSeason?.seasonId || ""}`)}</span>
              <p>请在左侧本地匹配项目里选择正确的作品/季度，然后再勾选集数进入同步。</p>
            </div>
          </div>
        </div>
      `
      : empty("先在上方选择一个 B站弹幕源，再从左侧选择本地匹配项目");
    viewRoot.innerHTML = `${bilibiliDanmakuPanel()}${splitView({
      listTitle: "搜索结果",
      listHint: "按作品聚合，先选择一个作品",
      listTitle: selectedBiliTitle ? "本地匹配项目" : "搜索结果",
      listHint: selectedBiliTitle
        ? "请手动选择正确的本地作品/季度，系统不会自动代选"
        : "按作品聚合，先选择一个作品",
      list: localItems.length
        ? localItems
            .map((item) =>
              selectableItem({
                active: false,
                action: "select-danmaku-anime",
                attrs: `data-anime="${escapeAttr(JSON.stringify(item))}"`,
                title: item.animeTitle,
                meta: `${item.episodeCount} 集 · ${item.danmakuCount} 条弹幕 · ${item.aliasCount} 个源${item.sourceLabel ? ` · ${item.sourceLabel}` : ""}`,
                body: `动漫 ID：${item.animeId} · 最近 ${formatTime(item.lastCreatedAt)}`,
              }),
            )
            .join("")
        : empty("没有匹配作品"),
      detail: empty("选择左侧作品后显示集数，不会一次展开全部条目"),
      detail: localMatchDetail,
    })}`;
    return;
  }

  const episodeData = await api(
    `/admin/danmaku/anime/${encodeURIComponent(selected.anime.animeId)}/episodes${makeQuery(
      {
        status: state.status || "visible",
      },
    )}`,
  );
  const allEpisodeItems = (episodeData.items || []).map((item, index) => ({
    ...item,
    biliEpisodeIndex: index + 1,
  }));
  const episodeItems = filterBilibiliSyncEpisodes(allEpisodeItems);
  state.danmakuEpisodeItems = episodeItems;
  pruneBiliTargetSelection(episodeItems);
  if (
    selected.episode &&
    !episodeItems.some((item) => item.videoId === selected.episode.videoId)
  ) {
    selected.episode = null;
    selected.page = 1;
  }

  let detailHtml = `
      <div class="detail-header">
        <div>
          <h3>${escapeHtml(selected.anime.animeTitle)}</h3>
          <p>${escapeHtml(`${episodeItems.length}/${allEpisodeItems.length} 个当前作品集数`)}</p>
        </div>
      <button class="button muted" data-action="clear-danmaku-selection">返回搜索结果</button>
    </div>
    ${empty("左侧选择一个集数后分页查看弹幕")}
  `;

  if (selected.episode) {
    const detail = await api(
      `/admin/danmaku/episodes/detail${makeQuery({
        videoId: selected.episode.videoId,
        q: state.danmakuKeyword,
        status: state.status || "visible",
        page: selected.page,
        pageSize: 30,
      })}`,
    );
    const pagerHtml = pager({
      type: "danmaku",
      page: detail.page,
      totalPages: detail.totalPages,
      total: detail.total,
      noun: "条弹幕",
    });
    detailHtml = `
      <div class="detail-header">
        <div>
          <h3>${escapeHtml(detail.group.episodeTitle)}</h3>
          <p>${escapeHtml(`${detail.group.animeTitle} · ${detail.aliases.length} 个播放源已绑定`)}</p>
        </div>
        <div class="stat-row">
          ${miniStat("弹幕", detail.group.danmakuCount)}
          ${miniStat("用户", detail.group.userCount)}
          ${miniStat("B站导入", detail.group.bilibiliImportedCount || 0)}
          ${miniStat("播放源", detail.aliases.length)}
          ${miniStat("时长点", formatMs(detail.group.maxTimeMs))}
        </div>
      </div>

      <div class="section-block">
        <div class="section-title">
          <span>播放源绑定</span>
          <button class="button danger"
            data-action="delete-imported-danmaku"
            data-video-id="${escapeAttr(detail.group.videoId)}">清理导入弹幕</button>
        </div>
        <div class="alias-grid">
          ${
            detail.aliases.length
              ? detail.aliases.map(aliasItem).join("")
              : empty("还没有播放源别名")
          }
        </div>
      </div>

      <div class="section-block">
        <div class="section-title"><span>分钟密度</span></div>
        <div class="bucket-row">
          ${
            detail.buckets.length
              ? detail.buckets
                  .map((item) => bucket(item, detail.buckets))
                  .join("")
              : empty("暂无时间分布")
          }
        </div>
      </div>

      <div class="detail-filter">
        <input id="danmakuKeywordInput" value="${escapeAttr(state.danmakuKeyword)}" placeholder="在当前集数中搜索弹幕关键词或用户" />
        <button class="button primary" data-action="apply-danmaku-keyword">查询</button>
        <button class="button muted" data-action="clear-danmaku-keyword">清空</button>
      </div>

      ${pagerHtml}
      <div class="timeline-list">
        ${
          detail.items.length
            ? detail.items.map(danmakuItem).join("")
            : empty("当前筛选下没有弹幕")
        }
      </div>
      ${pagerHtml.replace('class="pager"', 'class="pager pager-bottom"')}
    `;
  }

  viewRoot.innerHTML = `${bilibiliDanmakuPanel()}${splitView({
    listTitle: selected.anime.animeTitle,
    listHint: `左侧只展示当前作品的集数 · ${labelBilibiliSyncStatus(state.bili.syncFilter || "")}`,
    listTools: danmakuTargetSelectionTools(),
    list: episodeItems.length
      ? episodeItems
          .map((item) =>
            danmakuEpisodeTargetItem(
              item,
              selected.episode?.videoId === item.videoId,
            ),
          )
          .join("")
      : empty("当前作品没有匹配集数"),
    detail: detailHtml,
  })}`;
}

async function renderChat() {
  const query = makeQuery({ q: state.q });
  const data = await api(`/admin/chat/rooms${query}`);
  const [keywords, violations, blockedIps] = await Promise.all([
    api("/admin/chat/keywords"),
    api("/admin/chat/violations"),
    api("/admin/blocked-ips"),
  ]);
  if (!state.selected.chat && data.items?.length) {
    state.selected.chat = data.items[0].roomId;
  }
  const selected = state.selected.chat;
  let detailHtml = empty("左侧选择一个聊天室后查看消息");
  if (selected) {
    const detailQuery = makeQuery({
      roomId: selected,
      q: state.q,
      status: state.status || "visible",
    });
    const detail = await api(`/admin/chat/rooms/detail${detailQuery}`);
    const visibleIds = new Set(detail.items.map((item) => Number(item.id)));
    state.chatSelection = new Set(
      [...state.chatSelection].filter((id) => visibleIds.has(id)),
    );
    const selectedCount = state.chatSelection.size;
    detailHtml = `
      <div class="detail-header">
        <div>
          <h3>${escapeHtml(detail.room.roomId)}</h3>
          <p>${escapeHtml(`最后活跃 ${formatTime(detail.room.lastCreatedAt)}`)}</p>
        </div>
        <div class="detail-actions">
          <div class="stat-row">
            ${miniStat("消息", detail.room.messageCount)}
            ${miniStat("用户", detail.room.userCount)}
          </div>
          <div class="action-row">
            <button class="button danger" data-action="delete-selected-chat" ${selectedCount ? "" : "disabled"}>删除已选 ${selectedCount}</button>
            <button class="button danger" data-action="clear-chat-room">一键清空</button>
          </div>
        </div>
      </div>
      <div class="timeline-list">
        ${
          detail.items.length
            ? detail.items.map(chatItem).join("")
            : empty("当前筛选下没有消息")
        }
      </div>
    `;
  }

  viewRoot.innerHTML = splitView({
    listTitle: "聊天室房间",
    listHint: "按 roomId 聚合消息",
    list: data.items?.length
      ? data.items
          .map((item) =>
            selectableItem({
              active: selected === item.roomId,
              action: "select-chat-room",
              attrs: `data-room-id="${escapeAttr(item.roomId)}"`,
              title: item.roomId,
              meta: `${item.messageCount} 条 · ${item.userCount} 人 · ${formatTime(item.lastCreatedAt)}`,
              body: item.latestContent,
            }),
          )
          .join("")
      : empty("没有聊天室消息"),
    detail: detailHtml,
  });
  viewRoot.insertAdjacentHTML(
    "beforeend",
    chatModerationPanels({
      keywords: keywords.items || [],
      violations: violations.items || [],
      blockedIps: blockedIps.items || [],
    }),
  );
}

async function renderUsers() {
  const query = makeQuery({
    q: state.q,
    status: state.status,
    appVersionCode: state.userVersionCode || "",
  });
  const data = await api(`/admin/users${query}`);
  if (!data.items?.some((item) => item.id === state.selected.users)) {
    state.selected.users = data.items?.[0]?.id || null;
  }
  const selected = state.selected.users;
  let detailHtml = empty("左侧选择一个用户后查看活动");
  if (selected) {
    const detail = await api(`/admin/users/${selected}/activity`);
    detailHtml = userDetail(detail);
  }

  viewRoot.innerHTML = `
    ${
      state.userVersionCode
        ? `<div class="filter-notice">
            <span>正在查看构建号 #${state.userVersionCode} 的用户</span>
            <button class="button muted" data-action="clear-user-version-filter">清除版本筛选</button>
          </div>`
        : ""
    }
    ${splitView({
    listTitle: "用户列表",
    listHint: "身份、状态、App 版本和互动统计",
    list: data.items?.length
      ? data.items
          .map((item) => {
            const appVersion = item.appInstall
              ? ` · ${item.appInstall.versionName} (#${item.appInstall.versionCode})`
              : " · 未上报版本";
            return selectableItem({
              active: selected === item.id,
              action: "select-user",
              attrs: `data-id="${item.id}"`,
              title: `${item.nickname} #${item.id}`,
              meta: `Lv${item.growth?.level || 1} ${item.growth?.levelName || ""} · ${labelRole(item.role)} · ${labelStatus(item.status)}${appVersion}`,
              body: `${item.email} · 积分 ${item.growth?.points || 0} · 樱花币 ${item.growth?.sakuraCoins || 0}`,
            });
          })
          .join("")
      : empty("没有用户"),
    detail: detailHtml,
  })}`;
}

async function renderVersions() {
  const data = await api("/admin/app-versions");
  const latestCode = Number(data.latestVersionCode || 0);
  const keyword = state.q.toLowerCase();
  const matchesStatus = (item) => {
    if (state.status === "current") return item.versionCode === latestCode;
    if (state.status === "outdated") return item.versionCode < latestCode;
    return true;
  };
  const matchesKeyword = (item) => {
    if (!keyword) return true;
    return [
      item.versionName,
      item.versionCode,
      item.platform,
      item.nickname,
      item.email,
      item.deviceModel,
      item.osVersion,
    ].some((value) => String(value || "").toLowerCase().includes(keyword));
  };
  const versions = (data.versions || []).filter(
    (item) => matchesStatus(item) && matchesKeyword(item),
  );
  const recentInstalls = (data.recentInstalls || []).filter(
    (item) => matchesStatus(item) && matchesKeyword(item),
  );
  const reportingPercent = Math.round(Number(data.reportingCoverage || 0) * 1000) / 10;
  const upgradePercent = Math.round(Number(data.upgradeCoverage || 0) * 1000) / 10;

  viewRoot.innerHTML = `
    <section class="metrics-grid">
      ${metric("注册用户", data.registeredUsers || 0, "后台用户总数")}
      ${metric("已上报版本", data.reportedUsers || 0, `覆盖 ${reportingPercent}%`)}
      ${metric("未上报", data.unreportedUsers || 0, "旧版或尚未重新登录", data.unreportedUsers ? "danger" : "")}
      ${metric("最新版用户", data.currentUsers || 0, latestCode ? `当前构建 #${latestCode}` : "暂无数据")}
      ${metric("旧版用户", data.outdatedUsers || 0, "建议定向提醒升级", data.outdatedUsers ? "danger" : "")}
      ${metric("升级覆盖率", upgradePercent, "%（已上报用户）")}
    </section>
    <section class="version-layout">
      <article class="panel version-panel">
        <h3>版本分布</h3>
        <div class="version-table">
          <div class="version-row version-head">
            <span>版本</span><span>平台</span><span>用户</span><span>最近活跃</span><span></span>
          </div>
          ${
            versions.length
              ? versions
                  .map(
                    (item) => `
                      <div class="version-row">
                        <span><strong>${escapeHtml(item.versionName || "未知")}</strong><small>#${item.versionCode}</small></span>
                        <span>${escapeHtml(item.platform || "未知")}</span>
                        <span>${item.userCount} ${badge(item.versionCode === latestCode ? "当前版" : "旧版本", item.versionCode === latestCode ? "active" : "open")}</span>
                        <span>${formatTime(item.lastSeenAt)}</span>
                        <span><button class="button muted" data-action="view-version-users" data-code="${item.versionCode}">查看用户</button></span>
                      </div>`,
                  )
                  .join("")
              : empty("当前筛选下没有版本数据")
          }
        </div>
      </article>
      <article class="panel version-panel">
        <h3>最近上报设备</h3>
        <div class="recent-install-list">
          ${
            recentInstalls.length
              ? recentInstalls
                  .map(
                    (item) => `
                      <div class="recent-install-item">
                        <div>
                          <strong>${escapeHtml(item.nickname || item.email || `用户 #${item.userId}`)}</strong>
                          <span>${escapeHtml(item.email || "")} · ${escapeHtml(item.versionName || "未知")} (#${item.versionCode})</span>
                        </div>
                        <div>
                          <span>${escapeHtml(item.deviceModel || "未知设备")}</span>
                          <small>${escapeHtml(item.osVersion || item.platform || "")} · ${formatTime(item.lastSeenAt)}</small>
                        </div>
                      </div>`,
                  )
                  .join("")
              : empty("当前筛选下没有设备上报")
          }
        </div>
      </article>
    </section>
    <p class="muted-note version-note">版本统计从 4.0.21（构建 36）开始采集；未上报用户可能仍在使用旧版，也可能尚未重新打开或登录 App。</p>
  `;
}


async function renderReports() {
  const query = makeQuery({ q: state.q, status: state.status || "open" });
  const data = await api(`/admin/reports${query}`);
  viewRoot.innerHTML = `
    <section class="queue-layout">
      <div class="queue-summary">
        ${metric("待处理", data.statusCounts?.open || 0)}
        ${metric("已处理", data.statusCounts?.resolved || 0)}
        ${metric("已忽略", data.statusCounts?.ignored || 0)}
      </div>
      <div class="report-list">
        ${
          data.items.length
            ? data.items.map(reportItem).join("")
            : empty("当前筛选下没有举报")
        }
      </div>
    </section>
  `;
}


async function handleCommunityAction(action, actionElement) {
  if (action === "select-comment-target") {
      state.selected.comments.target = parseJsonDataset(actionElement, "target");
      state.selected.comments.group = null;
      state.selected.comments.page = 1;
      await renderComments();
    } else if (action === "clear-comment-selection") {
      state.selected.comments.target = null;
      state.selected.comments.group = null;
      state.selected.comments.page = 1;
      await renderComments();
    } else if (action === "select-comment-group") {
      state.selected.comments.group = parseJsonDataset(actionElement, "group");
      state.selected.comments.page = 1;
      await renderComments();
    } else if (action === "comment-page") {
      state.selected.comments.page = Number(actionElement.dataset.page || 1);
      await renderComments();
    } else if (action === "apply-comment-keyword") {
      state.commentKeyword = document
        .querySelector("#commentKeywordInput")
        ?.value.trim();
      state.selected.comments.page = 1;
      await renderComments();
    } else if (action === "clear-comment-keyword") {
      state.commentKeyword = "";
      state.selected.comments.page = 1;
      await renderComments();
    } else if (action === "select-danmaku-anime") {
      state.selected.danmaku.anime = parseJsonDataset(actionElement, "anime");
      state.selected.danmaku.episode = null;
      state.selected.danmaku.page = 1;
      state.bili.selectedTargetVideoIds.clear();
      await renderDanmaku();
    } else if (action === "clear-danmaku-selection") {
      state.selected.danmaku.anime = null;
      state.selected.danmaku.episode = null;
      state.selected.danmaku.page = 1;
      state.bili.selectedTargetVideoIds.clear();
      await renderDanmaku();
    } else if (action === "select-danmaku-episode") {
      state.selected.danmaku.episode = parseJsonDataset(
        actionElement,
        "episode",
      );
      state.selected.danmaku.page = 1;
      await renderDanmaku();
    } else if (action === "danmaku-page") {
      state.selected.danmaku.page = Number(actionElement.dataset.page || 1);
      await renderDanmaku();
    } else if (action === "apply-danmaku-keyword") {
      state.danmakuKeyword = document
        .querySelector("#danmakuKeywordInput")
        ?.value.trim();
      state.selected.danmaku.page = 1;
      await renderDanmaku();
    } else if (action === "clear-danmaku-keyword") {
      state.danmakuKeyword = "";
      state.selected.danmaku.page = 1;
      await renderDanmaku();
    } else if (action === "select-all-bili-targets") {
      replaceBiliTargetSelection(state.danmakuEpisodeItems || []);
      await renderDanmaku();
    } else if (action === "select-unsynced-bili-targets") {
      replaceBiliTargetSelection(
        (state.danmakuEpisodeItems || []).filter(
          (item) => (item.bilibiliSyncStatus || "unsynced") === "unsynced",
        ),
      );
      await renderDanmaku();
    } else if (action === "clear-bili-targets") {
      state.bili.selectedTargetVideoIds.clear();
      await renderDanmaku();
    } else if (action === "select-chat-room") {
      state.selected.chat = actionElement.dataset.roomId;
      state.chatSelection.clear();
      await renderChat();
    } else if (action === "delete-selected-chat") {
      const ids = [...state.chatSelection];
      if (!ids.length) return;
      if (!confirm(`确认删除选中的 ${ids.length} 条聊天室消息？`)) return;
      await api("/admin/chat/batch", {
        method: "DELETE",
        body: { ids },
      });
      state.chatSelection.clear();
      await renderChat();
    } else if (action === "clear-chat-room") {
      const roomId = state.selected.chat;
      if (!roomId) return;
      if (!confirm(`确认清空聊天室 ${roomId} 的当前可见消息？`)) return;
      await api("/admin/chat/rooms/clear", {
        method: "DELETE",
        body: { roomId, status: state.status || "visible" },
      });
      state.chatSelection.clear();
      await renderChat();
    } else if (action === "add-chat-keyword") {
      const keyword = document.querySelector("#chatKeywordInput")?.value.trim();
      const note = document.querySelector("#chatKeywordNoteInput")?.value.trim();
      if (!keyword) return;
      await api("/admin/chat/keywords", {
        method: "POST",
        body: { keyword, note },
      });
      await renderChat();
    } else if (action === "toggle-chat-keyword") {
      await api(`/admin/chat/keywords/${actionElement.dataset.id}`, {
        method: "PATCH",
        body: { status: actionElement.dataset.value },
      });
      await renderChat();
    } else if (action === "delete-chat-keyword") {
      if (!confirm("确认删除这个屏蔽词？")) return;
      await api(`/admin/chat/keywords/${actionElement.dataset.id}`, {
        method: "DELETE",
      });
      await renderChat();
    } else if (action === "delete-blocked-ip") {
      if (!confirm("确认从注册黑名单移除此 IP？")) return;
      await api(
        `/admin/blocked-ips/${encodeURIComponent(actionElement.dataset.ip)}`,
        { method: "DELETE" },
      );
      await renderChat();
    } else if (action === "view-version-users") {
      state.view = "users";
      state.userVersionCode = Number(actionElement.dataset.code || 0);
      state.q = "";
      state.status = "";
      state.selected.users = null;
      searchInput.value = "";
      statusFilter.value = "";
      document.querySelectorAll(".nav button").forEach((item) => {
        item.classList.toggle("active", item.dataset.view === "users");
      });
      await loadView();
    } else if (action === "clear-user-version-filter") {
      state.userVersionCode = 0;
      state.selected.users = null;
      await renderUsers();
    }

  if (action === "select-user") {
      state.selected.users = Number(actionElement.dataset.id);
      await renderUsers();
    } else if (action === "delete-comment") {
      await api(`/admin/comments/${actionElement.dataset.id}`, {
        method: "DELETE",
      });
      await loadView();
    } else if (action === "delete-danmaku") {
      await api(`/admin/danmaku/${actionElement.dataset.id}`, {
        method: "DELETE",
      });
      await loadView();
    } else if (action === "delete-imported-danmaku") {
      await api(
        `/admin/danmaku/groups/${encodeURIComponent(actionElement.dataset.videoId)}/imported`,
        { method: "DELETE" },
      );
      await loadView();
    } else if (action === "delete-chat") {
      await api(`/admin/chat/${actionElement.dataset.id}`, {
        method: "DELETE",
      });
      await loadView();
    } else if (action === "search-bilibili") {
      state.bili.q =
        document.querySelector("#biliSearchInput")?.value.trim() || "";
      state.q = state.bili.q;
      searchInput.value = state.q;
      state.selected.danmaku.anime = null;
      state.selected.danmaku.episode = null;
      state.selected.danmaku.page = 1;
      state.bili.selectedTargetVideoIds.clear();
      state.bili.limit = Number(
        document.querySelector("#biliLimitInput")?.value || state.bili.limit,
      );
      state.bili.searchError = "";
      try {
        const data = await api(
          `/admin/danmaku/bilibili/search${makeQuery({ q: state.bili.q })}`,
        );
        state.bili.results = data.items || [];
      } catch (error) {
        state.bili.results = [];
        state.bili.searchError = error.message || "B站搜索失败";
      }
      state.bili.selectedSeason = null;
      state.bili.episodes = [];
      state.bili.selectedCid = 0;
      state.bili.sourceSummary = {};
      await renderDanmaku();
      if (state.bili.searchError) {
        renderNotice(state.bili.searchError, "error");
      }
    } else if (action === "select-bilibili-season") {
      const data = await api(
        `/admin/danmaku/bilibili/season/${encodeURIComponent(
          actionElement.dataset.seasonId,
        )}`,
      );
      state.bili.selectedSeason = data;
      state.bili.episodes = data.episodes || [];
      state.bili.selectedCid = Number(state.bili.episodes[0]?.cid || 0);
      await loadBilibiliSourceSummary(state.bili.selectedCid);
      await renderDanmaku();
    } else if (action === "sync-bilibili-current") {
      const episodeSelect = document.querySelector("#biliEpisodeSelect");
      const cid = Number(episodeSelect?.value || 0);
      const selected = state.selected.danmaku.episode;
      if (!cid || !selected) return;
      state.bili.limit = Number(
        document.querySelector("#biliLimitInput")?.value || state.bili.limit || 800,
      );
      const result = await api("/admin/danmaku/bilibili/sync", {
        method: "POST",
        body: {
          cid,
          limit: state.bili.limit,
          targetVideoId: selected.videoId,
          animeId: selected.animeId,
          animeTitle: selected.animeTitle,
          episodeId: selected.episodeId,
          episodeTitle: selected.episodeTitle,
          targetAliases: selected.targetAliases || [],
          replace: true,
        },
      });
      renderNotice(
        `源 ${result.sourceDanmakuCount || 0} 条，均匀同步 ${result.inserted || 0} 条弹幕`,
      );
      await renderDanmaku();
    } else if (action === "sync-bilibili-batch") {
      const targets = bilibiliBatchTargets();
      if (!state.bili.selectedSeason || !targets.length) {
        renderNotice("请先选择 B 站源，并勾选要同步的本地集数。", "error");
        return;
      }
      if (
        !confirm(
          `确认按集数顺序批量同步 ${targets.length} 集弹幕？已同步集会跳过。`,
        )
      ) {
        return;
      }
      state.bili.limit = Number(
        document.querySelector("#biliLimitInput")?.value || state.bili.limit || 800,
      );
      const data = await api("/admin/danmaku/bilibili/batch-sync", {
        method: "POST",
        body: {
          seasonId: state.bili.selectedSeason.seasonId,
          limit: state.bili.limit,
          skipSynced: true,
          targets: targets.map((item, index) => ({
            targetVideoId: item.videoId,
            animeId: item.animeId,
            animeTitle: item.animeTitle,
            episodeId: item.episodeId,
            episodeTitle: item.episodeTitle,
            targetAliases: item.targetAliases || [],
            biliEpisodeIndex: item.biliEpisodeIndex || index + 1,
          })),
          replace: true,
        },
      });
      const ok = (data.results || []).filter((item) => item.ok).length;
      const skipped = (data.results || []).filter((item) => item.skipped).length;
      renderNotice(
        `批量同步完成：${ok}/${(data.results || []).length} 集成功，跳过已同步 ${skipped} 集`,
      );
      state.bili.selectedTargetVideoIds.clear();
      await renderDanmaku();
    } else if (action === "user-status") {
      await api(`/admin/users/${actionElement.dataset.id}`, {
        method: "PATCH",
        body: { status: actionElement.dataset.value },
      });
      await loadView();
    } else if (action === "user-role") {
      await api(`/admin/users/${actionElement.dataset.id}`, {
        method: "PATCH",
        body: { role: actionElement.dataset.value },
      });
      await loadView();
    } else if (action === "save-user-admin-edit") {
      const id = actionElement.dataset.id;
      await api(`/admin/users/${id}`, {
        method: "PATCH",
        body: collectUserAdminEditPayload(),
      });
      await renderUsers();
    } else if (action === "report-status") {
      await api(`/admin/reports/${actionElement.dataset.id}`, {
        method: "PATCH",
        body: { status: actionElement.dataset.value },
      });
      await loadView();
    } else if (action === "report-delete-target") {
      await api(
        `/admin/reports/${actionElement.dataset.id}/resolve-delete-target`,
        { method: "POST" },
      );
      await loadView();
    }
}
