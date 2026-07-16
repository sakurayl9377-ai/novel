// Dashboard, finance, racing, notifications, analytics, releases, audit, and settings views.
// Loaded as an ordered deferred browser script; shared bindings are declared in admin-core.js.

async function renderDashboard() {
  const [data, operations] = await Promise.all([
    api("/admin/summary"),
    api("/admin/operations/overview"),
  ]);
  const service = operations.service || {};
  const economy24h = operations.economy24h || {};
  const race = operations.race || {};
  viewRoot.innerHTML = `
    <section class="metrics-grid">
      ${metric("24h 活跃用户", operations.users?.active24h || 0, `总用户 ${operations.users?.total || 0}`)}
      ${metric("24h 新用户", operations.users?.new24h || 0, `${operations.users?.banned || 0} 个封禁`)}
      ${metric("24h 内容", (operations.content?.comments24h || 0) + (operations.content?.danmaku24h || 0) + (operations.content?.chat24h || 0), "评论 / 弹幕 / 聊天")}
      ${metric("待处理举报", operations.content?.openReports || 0, "需要人工确认", operations.content?.openReports ? "danger" : "")}
      ${metric("24h 资金事件", economy24h.event_count || 0, `发放 ${economy24h.coins_issued || 0} / 消耗 ${economy24h.coins_spent || 0}`)}
      ${metric("赛马投注额", race.staked24h || 0, `${race.participants24h || 0} 位参与者`)}
    </section>

    <section class="system-health-grid">
      <article class="health-card">
        <span>服务状态</span>
        <strong class="health-online">${escapeHtml(service.status || "unknown")}</strong>
        <small>运行 ${formatDuration(service.uptimeSeconds || 0)} · ${escapeHtml(service.nodeVersion || "")}</small>
      </article>
      <article class="health-card">
        <span>进程内存</span>
        <strong>${formatBytes(service.processMemoryBytes || 0)}</strong>
        <small>堆已用 ${formatBytes(service.heapUsedBytes || 0)}</small>
      </article>
      <article class="health-card">
        <span>系统可用内存</span>
        <strong>${formatBytes(service.systemFreeMemoryBytes || 0)}</strong>
        <small>总计 ${formatBytes(service.systemMemoryBytes || 0)}</small>
      </article>
      <article class="health-card">
        <span>数据库体积</span>
        <strong>${formatBytes(service.dbBytes || 0)}</strong>
        <small>${escapeHtml(service.platform || "")}</small>
      </article>
    </section>

    <section class="dashboard-grid">
      ${panel(
        "待处理举报",
        data.recentReports?.length
          ? data.recentReports.map(reportCompact).join("")
          : empty("暂无待处理举报"),
      )}
      ${panel(
        "活跃评论对象",
        data.activeCommentTargets?.length
          ? data.activeCommentTargets.map(commentGroupCompact).join("")
          : empty("暂无评论"),
      )}
      ${panel(
        "活跃弹幕视频池",
        data.activeDanmakuGroups?.length
          ? data.activeDanmakuGroups.map(danmakuGroupCompact).join("")
          : empty("暂无弹幕"),
      )}
      ${panel(
        "活跃聊天室",
        data.activeChatRooms?.length
          ? data.activeChatRooms.map(chatRoomCompact).join("")
          : empty("暂无消息"),
      )}
      ${panel(
        "最近管理员操作",
        operations.recentAudit?.length
          ? operations.recentAudit.map(auditCompact).join("")
          : empty("暂无审计记录"),
      )}
      ${panel(
        "最近通知发布",
        operations.recentBroadcasts?.length
          ? operations.recentBroadcasts.map(broadcastCompact).join("")
          : empty("暂无发布记录"),
      )}
    </section>
  `;
}


async function renderFinance() {
  const page = state.pages.finance || 1;
  const data = await api(
    `/admin/finance/events${makeQuery({ q: state.q, page, pageSize: 30 })}`,
  );
  const summary = data.summary || {};
  const totalPages = Math.max(1, Math.ceil((data.total || 0) / (data.pageSize || 30)));
  viewRoot.innerHTML = `
    <section class="metrics-grid finance-metrics">
      ${metric("账变记录", data.total || 0, "当前筛选")}
      ${metric("积分净变动", summary.points_delta || 0, "正数为净发放")}
      ${metric("樱花币净变动", summary.coins_delta || 0, "正数为净流入")}
      ${metric("樱花币发放", summary.coins_issued || 0, "累计正向账变")}
      ${metric("樱花币消耗", summary.coins_spent || 0, "累计负向账变")}
      ${metric("事件类型", data.actions?.length || 0, "业务来源分类")}
    </section>
    <section class="panel operations-panel">
      <h3>资金事件</h3>
      <div class="action-chip-list">
        ${(data.actions || [])
          .map((item) => `<span>${escapeHtml(item.action)} <b>${item.count}</b></span>`)
          .join("") || '<span>暂无事件</span>'}
      </div>
      <div class="data-table finance-table">
        <div class="data-row data-head">
          <span>时间 / 用户</span><span>动作</span><span>积分</span><span>樱花币</span><span>说明 / 关联</span>
        </div>
        ${
          data.items?.length
            ? data.items
                .map(
                  (item) => `
                    <div class="data-row">
                      <span><strong>${formatTime(item.created_at)}</strong><small>${escapeHtml(item.nickname || item.email || `用户 #${item.user_id}`)}</small></span>
                      <span>${badge(item.action || "unknown", "ignored")}</span>
                      <span class="number-delta ${Number(item.points_delta || 0) < 0 ? "negative" : "positive"}">${formatSigned(item.points_delta)}</span>
                      <span class="number-delta ${Number(item.coins_delta || 0) < 0 ? "negative" : "positive"}">${formatSigned(item.coins_delta)}</span>
                      <span><strong>${escapeHtml(item.description || "-")}</strong><small>${escapeHtml([item.related_type, item.related_id].filter(Boolean).join(" / ") || "-")}</small></span>
                    </div>`,
                )
                .join("")
            : empty("当前筛选下没有资金事件")
        }
      </div>
      ${pager({ type: "finance", page: data.page || page, totalPages, total: data.total || 0, noun: "条资金事件" })}
    </section>
  `;
}

async function renderRace() {
  const page = state.pages.race || 1;
  const data = await api(
    `/admin/horse-race/rounds${makeQuery({ q: state.q, status: state.status, page, pageSize: 30 })}`,
  );
  if (!data.items?.some((item) => item.id === state.selected.race)) {
    state.selected.race = data.items?.[0]?.id || null;
  }
  const selected = state.selected.race;
  let detail = empty("选择一个轮次查看下注、赔率与公平性证明");
  if (selected) {
    const response = await api(`/admin/horse-race/rounds/${selected}`);
    detail = raceRoundDetail(response.item);
  }
  const totalPages = Math.max(1, Math.ceil((data.total || 0) / (data.pageSize || 30)));
  viewRoot.innerHTML = `
    ${splitView({
      listTitle: "赛马轮次",
      listHint: `共 ${data.total || 0} 轮，可按轮次编号或状态筛选`,
      list: data.items?.length
        ? `${data.items
            .map((item) =>
              selectableItem({
                active: selected === item.id,
                action: "select-race-round",
                attrs: `data-id="${item.id}"`,
                title: item.roundCode || `轮次 #${item.id}`,
                meta: `${labelRaceStatus(item.status)} · ${item.participants} 人 · ${item.betCount} 注`,
                body: `投注 ${item.totalStaked} · 赔付 ${item.totalPayout} · 庄家净额 ${item.houseNet}`,
              }),
            )
            .join("")}${pager({ type: "race", page: data.page || page, totalPages, total: data.total || 0, noun: "个轮次" })}`
        : empty("当前筛选下没有赛马轮次"),
      detail,
    })}
  `;
}

function raceRoundDetail(item) {
  const fairness = item.fairness || {};
  const horseTotals = item.horseTotals || [];
  return `
    <div class="detail-header">
      <div>
        <h3>${escapeHtml(item.roundCode || `轮次 #${item.id}`)}</h3>
        <p>${labelRaceStatus(item.status)} · 规则 v${item.rulesVersion} · ${formatTime(item.createdAt)}</p>
      </div>
      ${badge(labelRaceStatus(item.status), item.status === "settling" ? "open" : "active")}
    </div>
    <div class="stat-row">
      ${miniStat("参与者", item.participants)}
      ${miniStat("下注数", item.betCount)}
      ${miniStat("总投注", item.totalStaked)}
      ${miniStat("总赔付", item.totalPayout)}
      ${miniStat("庄家净额", item.houseNet)}
      ${miniStat("胜者", item.settledAt ? `#${Number(item.winnerIndex) + 1}` : "未开奖")}
    </div>
    <section class="section-block">
      <div class="section-title"><span>公平性证明</span></div>
      <div class="fairness-box">
        <span><small>算法</small><strong>${escapeHtml(fairness.algorithm || "-")}</strong></span>
        <span><small>Seed Commit</small><code>${escapeHtml(fairness.seedCommit || "-")}</code></span>
        <span><small>Seed Reveal</small><code>${escapeHtml(fairness.seedReveal || "尚未结算")}</code></span>
      </div>
    </section>
    <section class="section-block">
      <div class="section-title"><span>赛道汇总</span></div>
      <div class="race-horse-grid">
        ${
          horseTotals.length
            ? horseTotals
                .map(
                  (horse) => `<div>
                    <strong>${Number(horse.horse_index || 0) + 1} 号马</strong>
                    <span>${horse.participants || 0} 人 / ${horse.bet_count || 0} 注</span>
                    <small>投注 ${horse.total_staked || 0} · 赔付 ${horse.total_payout || 0}</small>
                  </div>`,
                )
                .join("")
            : empty("本轮暂无下注")
        }
      </div>
    </section>
    <section class="section-block">
      <div class="section-title"><span>下注明细（最多 200 条）</span></div>
      <div class="data-table race-bet-table">
        <div class="data-row data-head"><span>用户</span><span>马匹</span><span>金额 / 赔率</span><span>赔付</span><span>状态 / 时间</span></div>
        ${(item.bets || [])
          .map(
            (bet) => `<div class="data-row">
              <span><strong>${escapeHtml(bet.nickname || bet.email || `用户 #${bet.user_id}`)}</strong><small>${escapeHtml(bet.email || "")}</small></span>
              <span>${Number(bet.horse_index || 0) + 1} 号马</span>
              <span>${bet.amount || 0} / ${Number(bet.odds || 0).toFixed(2)}</span>
              <span>${bet.payout || 0}</span>
              <span><strong>${escapeHtml(bet.status || "-")}</strong><small>${formatTime(bet.created_at)}</small></span>
            </div>`,
          )
          .join("") || empty("本轮暂无下注")}
      </div>
    </section>
  `;
}

async function renderNotifications() {
  const page = state.pages.notifications || 1;
  const data = await api(
    `/admin/notifications${makeQuery({ page, pageSize: 20 })}`,
  );
  const keyword = state.q.toLowerCase();
  const items = (data.items || []).filter((item) => {
    if (!keyword) return true;
    return [item.title, item.content, item.category, item.nickname, item.email]
      .some((value) => String(value || "").toLowerCase().includes(keyword));
  });
  const totalPages = Math.max(1, Math.ceil((data.total || 0) / (data.pageSize || 20)));
  viewRoot.innerHTML = `
    <section class="notification-layout">
      <article class="settings-card broadcast-composer">
        <div class="section-title"><span>发布全员通知</span>${badge("写操作会记录审计", "open")}</div>
        <div class="settings-form">
          <label>通知类型
            <select id="broadcastCategory">
              <option value="system">系统通知</option>
              <option value="update">版本更新</option>
              <option value="operation">运营活动</option>
              <option value="security">安全提醒</option>
            </select>
          </label>
          <label>标题<input id="broadcastTitle" maxlength="80" placeholder="简洁说明通知主题" /></label>
          <label class="settings-textarea">正文<textarea id="broadcastContent" rows="8" maxlength="2000" placeholder="通知会进入用户的消息中心"></textarea></label>
          <button class="button primary" data-action="send-broadcast">确认发布</button>
          <p class="muted-note">当前接口会向所有状态正常的用户写入一条系统通知。发布前请确认标题、正文和类型。</p>
        </div>
      </article>
      <article class="panel broadcast-history">
        <h3>发布记录</h3>
        <div class="broadcast-list">
          ${items.length ? items.map(broadcastItem).join("") : empty("当前筛选下没有发布记录")}
        </div>
        ${pager({ type: "notifications", page: data.page || page, totalPages, total: data.total || 0, noun: "条发布记录" })}
      </article>
    </section>
  `;
}

async function renderAnalytics() {
  const query = makeQuery({
    days: state.analytics.days,
    fatal: state.analytics.fatalOnly ? 1 : "",
    q: state.analytics.q,
    pageSize: 30,
  });
  const [overview, errors] = await Promise.all([
    api(`/admin/analytics/overview${makeQuery({ days: state.analytics.days })}`),
    api(`/admin/analytics/errors${query}`),
  ]);
  const summary = overview.summary || {};
  const frames = overview.frameMetrics || {};
  const topScreens = overview.topScreens || [];
  const topEvents = overview.topEvents || [];
  const daily = overview.daily || [];
  const errorItems = errors.items || [];
  const crashFreePercent = Number(
    ((summary.crashFreeRate ?? 1) * 100).toFixed(2),
  );
  const slow16Percent = Number(((frames.slow16Rate || 0) * 100).toFixed(2));
  const slow32Percent = Number(((frames.slow32Rate || 0) * 100).toFixed(2));

  viewRoot.innerHTML = `
    <section class="analytics-controls">
      <label>
        统计范围
        <select id="analyticsDays">
          ${[1, 7, 14, 30, 90]
            .map(
              (days) =>
                `<option value="${days}" ${Number(state.analytics.days) === days ? "selected" : ""}>最近 ${days} 天</option>`,
            )
            .join("")}
        </select>
      </label>
      <label>
        错误搜索
        <input id="analyticsErrorQuery" value="${escapeAttr(state.analytics.q)}" placeholder="错误类型、消息、页面或堆栈" />
      </label>
      <label class="analytics-check">
        <input id="analyticsFatalOnly" type="checkbox" ${state.analytics.fatalOnly ? "checked" : ""} />
        只看致命错误
      </label>
      <div class="analytics-actions">
        <button class="button primary" data-action="apply-analytics-filter">筛选</button>
        <button class="button" data-action="clear-analytics-filter">清空</button>
      </div>
    </section>

    <section class="metrics-grid analytics-metrics">
      ${metric("活跃安装", summary.activeInstalls || 0, `${summary.sessions || 0} 个会话`)}
      ${metric("事件量", summary.events || 0, `最近 ${overview.days || state.analytics.days} 天`)}
      ${metric("无崩溃会话", crashFreePercent, "%（按会话计算）", crashFreePercent < 99 ? "danger" : "")}
      ${metric("错误分组", summary.errorGroups || 0, `${summary.errors || 0} 次上报`)}
      ${metric("致命错误", summary.fatalErrors || 0, "未捕获异步异常", summary.fatalErrors ? "danger" : "")}
      ${metric("慢帧率", slow16Percent, `%（>16.7ms），严重 ${slow32Percent}%`, slow16Percent > 8 ? "danger" : "")}
    </section>

    <section class="analytics-performance-grid">
      <article class="panel">
        <h3>渲染性能</h3>
        <div class="analytics-stat-grid">
          ${miniStat("采样帧", frames.frames || 0)}
          ${miniStat(">16.7ms", frames.slow16 || 0)}
          ${miniStat(">32ms", frames.slow32 || 0)}
          ${miniStat(">700ms", frames.frozen700 || 0)}
          ${miniStat("最大构建", `${Number(frames.maxBuildMs || 0).toFixed(1)}ms`)}
          ${miniStat("最大栅格", `${Number(frames.maxRasterMs || 0).toFixed(1)}ms`)}
        </div>
      </article>
      <article class="panel">
        <h3>版本活跃</h3>
        <div class="panel-body analytics-list">
          ${(overview.versions || [])
            .map(
              (item) => compactRow(
                `${item.versionName || "未知"} (#${item.versionCode || 0})`,
                `${item.activeInstalls || 0} 个活跃安装`,
                `${item.events || 0} 个事件`,
              ),
            )
            .join("") || empty("暂无版本数据")}
        </div>
      </article>
    </section>

    <section class="panel analytics-daily-panel">
      <h3>每日趋势</h3>
      <div class="data-table analytics-daily-table">
        <div class="data-row data-head"><span>日期</span><span>活跃安装</span><span>会话</span><span>事件</span><span>错误 / 致命</span></div>
        ${daily
          .map(
            (item) => `
              <div class="data-row">
                <span><strong>${escapeHtml(item.day || "-")}</strong></span>
                <span>${Number(item.activeInstalls || 0)}</span>
                <span>${Number(item.sessions || 0)}</span>
                <span>${Number(item.events || 0)}</span>
                <span class="${item.fatalErrors ? "number-delta negative" : ""}">${Number(item.errors || 0)} / ${Number(item.fatalErrors || 0)}</span>
              </div>`,
          )
          .join("") || empty("暂无每日数据")}
      </div>
    </section>

    <section class="analytics-performance-grid">
      <article class="panel">
        <h3>页面停留</h3>
        <div class="panel-body analytics-list">
          ${topScreens
            .map(
              (item) => compactRow(
                item.screen || "unknown",
                `${item.views || 0} 次 · ${item.uniqueInstalls || 0} 个安装`,
                `平均 ${formatLatency(item.avgDurationMs)} / 最长 ${formatLatency(item.maxDurationMs)}`,
              ),
            )
            .join("") || empty("暂无页面数据")}
        </div>
      </article>
      <article class="panel">
        <h3>关键事件</h3>
        <div class="panel-body analytics-list">
          ${topEvents
            .map(
              (item) => compactRow(
                item.name || "unknown",
                `${item.count || 0} 次 · ${item.uniqueInstalls || 0} 个安装`,
                `${item.failures || 0} 次失败 · 平均 ${formatLatency(item.avgDurationMs)}`,
              ),
            )
            .join("") || empty("暂无事件数据")}
        </div>
      </article>
    </section>

    <section class="panel analytics-errors-panel">
      <h3>错误与崩溃（${Number(errors.total || 0)} 个分组）</h3>
      <div class="analytics-error-list">
        ${errorItems.map(analyticsErrorCard).join("") || empty("当前筛选下没有错误")}
      </div>
    </section>
  `;
}

function analyticsErrorCard(item) {
  const fatal = Number(item.fatalCount || 0) > 0 || item.fatal;
  return `
    <details class="analytics-error-card ${fatal ? "fatal" : ""}">
      <summary>
        <span>
          <strong>${escapeHtml(item.type || "Unknown error")}</strong>
          <small>${escapeHtml(item.message || "无错误消息")}</small>
        </span>
        <span class="analytics-error-meta">
          ${badge(fatal ? "致命" : "非致命", fatal ? "danger" : "")}
          <b>${Number(item.occurrences || 0)} 次</b>
          <small>${Number(item.affectedInstalls || 0)} 个安装</small>
        </span>
      </summary>
      <div class="analytics-error-detail">
        <div class="analytics-error-facts">
          <span><small>页面</small><strong>${escapeHtml(item.screen || "-")}</strong></span>
          <span><small>版本</small><strong>${escapeHtml(item.versionName || "-")} (#${Number(item.versionCode || 0)})</strong></span>
          <span><small>设备</small><strong>${escapeHtml(item.platform || "-")} · ${escapeHtml(item.deviceModel || "-")}</strong></span>
          <span><small>最后出现</small><strong>${formatTime(item.lastSeenAt)}</strong></span>
        </div>
        <pre>${escapeHtml(item.stack || item.message || "无堆栈")}</pre>
        <small class="analytics-fingerprint">${escapeHtml(item.fingerprint || "")}</small>
      </div>
    </details>
  `;
}

async function renderReleases() {
  const data = await api("/admin/releases");
  const current = data.current || {};
  viewRoot.innerHTML = `
    <section class="metrics-grid">
      ${metric("当前版本", current.versionCode || 0, current.versionName || "未配置")}
      ${metric("APK 大小", Math.round(Number(data.apk?.sizeBytes || 0) / 1024 / 1024), "MB")}
      ${metric("历史清单", data.history?.length || 0, "最多显示 50 个")}
      ${metric("服务器备份", data.backups?.length || 0, "最近 30 个")}
      ${metric("强制更新", current.force ? 1 : 0, current.force ? "已开启" : "未开启", current.force ? "danger" : "")}
      ${metric("APK 文件", data.apk?.exists ? 1 : 0, data.apk?.exists ? "存在" : "缺失", data.apk?.exists ? "" : "danger")}
    </section>
    ${
      data.configured
        ? `<section class="release-layout">
            <article class="panel release-current">
              <h3>当前线上版本</h3>
              <div class="release-detail">
                <span><small>版本</small><strong>${escapeHtml(current.versionName || "-")} (#${current.versionCode || 0})</strong></span>
                <span><small>APK URL</small><code>${escapeHtml(current.apkUrl || "-")}</code></span>
                <span><small>SHA-256</small><code>${escapeHtml(current.sha256 || "-")}</code></span>
                <span><small>APK 修改时间</small><strong>${formatTime(data.apk?.modifiedAt)}</strong></span>
              </div>
              <div class="release-notes">
                <strong>更新说明</strong>
                <ul>${(current.notes || []).map((note) => `<li>${escapeHtml(note)}</li>`).join("") || "<li>暂无说明</li>"}</ul>
              </div>
            </article>
            <article class="panel">
              <h3>历史版本清单</h3>
              <div class="release-history">
                ${(data.history || [])
                  .map(
                    (item) => `<div>
                      <strong>${escapeHtml(item.versionName || "-")} (#${item.versionCode || 0})</strong>
                      <span>${item.force ? "强制更新" : "普通更新"}</span>
                      <small>${escapeHtml(item.sha256 || "未记录 SHA-256")}</small>
                    </div>`,
                  )
                  .join("") || empty("暂无历史版本清单")}
              </div>
            </article>
            <article class="panel">
              <h3>可用服务器备份</h3>
              <div class="backup-list">
                ${(data.backups || []).map((name) => `<code>${escapeHtml(name)}</code>`).join("") || empty("暂无备份目录")}
              </div>
              <p class="muted-note release-warning">为避免后台 Web 进程获得文件系统提权，回滚仍由受审计的发布脚本执行；这里负责核对版本和备份是否齐全。</p>
            </article>
          </section>`
        : `<section class="empty-workbench"><h3>尚未配置发布目录</h3><p>请在后端环境变量 APP_RELEASE_DIR 中配置 APK 与 version.json 所在目录。</p></section>`
    }
  `;
}

async function renderAudit() {
  const page = state.pages.audit || 1;
  const data = await api(
    `/admin/audit-logs${makeQuery({ q: state.q, status: state.status, page, pageSize: 30 })}`,
  );
  const totalPages = Math.max(1, Math.ceil((data.total || 0) / (data.pageSize || 30)));
  viewRoot.innerHTML = `
    <section class="panel operations-panel">
      <h3>管理员操作审计</h3>
      <div class="data-table audit-table">
        <div class="data-row data-head"><span>时间 / 管理员</span><span>方法</span><span>路径</span><span>状态</span><span>来源 / 请求</span></div>
        ${
          data.items?.length
            ? data.items
                .map(
                  (item) => `<div class="data-row">
                    <span><strong>${formatTime(item.created_at)}</strong><small>${escapeHtml(item.nickname || item.email || "系统")}</small></span>
                    <span>${badge(item.method || "-", methodTone(item.method))}</span>
                    <span class="path-cell">${escapeHtml(item.path || "-")}</span>
                    <span>${badge(String(item.status_code || 0), Number(item.status_code || 0) >= 400 ? "banned" : "active")}</span>
                    <span><strong>${escapeHtml(item.ip || "-")}</strong><small>${escapeHtml(item.request_id || "-")}</small></span>
                  </div>`,
                )
                .join("")
            : empty("当前筛选下没有审计日志")
        }
      </div>
      ${pager({ type: "audit", page: data.page || page, totalPages, total: data.total || 0, noun: "条日志" })}
    </section>
  `;
}


async function renderSettings() {
  const settings = await api("/admin/settings");
  configureChatBotProviderPresets(settings.chatBotProviderPresets);
  const chatBotProvider = settings.chatBot?.provider || "nvidia";
  const isNvidiaChatBot = chatBotProvider === "nvidia";
  const chatBotBaseUrl = isNvidiaChatBot
    ? nvidiaChatBotDefaults.baseUrl
    : settings.chatBot?.baseUrl || "";
  const chatBotModel = isNvidiaChatBot
    ? nvidiaChatBotDefaults.model
    : settings.chatBot?.model || "";
  viewRoot.innerHTML = `
    <section class="settings-grid">
      <article class="settings-card">
        <div class="section-title">
          <span>语音转写</span>
          ${badge(settings.iflytekAsr?.enabled === "true" ? "启用" : "停用", settings.iflytekAsr?.enabled === "true" ? "active" : "ignored")}
        </div>
        <div class="settings-form">
          <label>
            APPID
            <input id="asrAppId" value="${escapeAttr(settings.iflytekAsr?.appId || "")}" placeholder="讯飞控制台 APPID" />
          </label>
          <label>
            APIKey
            <input id="asrApiKey" type="password" placeholder="${secretPlaceholder(settings.iflytekAsr?.apiKey)}" />
          </label>
          <label>
            SecretKey / APISecret（可选）
            <input id="asrSecretKey" type="password" placeholder="${secretPlaceholder(settings.iflytekAsr?.secretKey) || secretPlaceholder(settings.iflytekAsr?.apiSecret)}" />
          </label>
          <p class="muted-note">产品类型默认使用实时语音转写 RTASR，接口地址由系统自动配置。</p>
          <label class="inline-check">
            <input id="asrEnabled" type="checkbox" ${settings.iflytekAsr?.enabled === "true" ? "checked" : ""} />
            启用语音转写
          </label>
        </div>
      </article>

      <article class="settings-card">
        <div class="section-title">
          <span>长文本合成</span>
          ${badge(settings.iflytekTts?.enabled === "true" ? "启用" : "停用", settings.iflytekTts?.enabled === "true" ? "active" : "ignored")}
        </div>
        <div class="settings-form">
          <label>
            APPID
            <input id="ttsAppId" value="${escapeAttr(settings.iflytekTts?.appId || "")}" placeholder="讯飞控制台 APPID" />
          </label>
          <label>
            APIKey
            <input id="ttsApiKey" type="password" placeholder="${secretPlaceholder(settings.iflytekTts?.apiKey)}" />
          </label>
          <label>
            APISecret
            <input id="ttsApiSecret" type="password" placeholder="${secretPlaceholder(settings.iflytekTts?.apiSecret)}" />
          </label>
          <p class="muted-note">长文本合成接口地址由系统自动配置；发音人由用户在 App 的“设置 - 语音朗读”中自行选择。</p>
          <label class="inline-check">
            <input id="ttsEnabled" type="checkbox" ${settings.iflytekTts?.enabled === "true" ? "checked" : ""} />
            启用长文本合成
          </label>
        </div>
      </article>

      <article class="settings-card settings-card-wide">
        <div class="section-title">
          <span>App 公告</span>
          ${badge(settings.appAnnouncement?.enabled === "true" ? "启用" : "停用", settings.appAnnouncement?.enabled === "true" ? "active" : "ignored")}
        </div>
        <div class="settings-form">
          <label>
            标题
            <input id="appAnnouncementTitle" value="${escapeAttr(settings.appAnnouncement?.title || "公告")}" placeholder="公告标题" />
          </label>
          <label class="settings-textarea">
            公告内容
            <textarea id="appAnnouncementContent" rows="7" placeholder="用户打开 App 后看到的公告内容">${escapeHtml(settings.appAnnouncement?.content || "")}</textarea>
          </label>
          <label class="inline-check">
            <input id="appAnnouncementEnabled" type="checkbox" ${settings.appAnnouncement?.enabled === "true" ? "checked" : ""} />
            启用 App 启动公告
          </label>
          <p class="muted-note">修改标题、内容或启用状态后，App 会按新版本公告重新弹出一次。</p>
        </div>
      </article>

      <article class="settings-card settings-card-wide">
        <div class="section-title">
          <span>小樱机器人</span>
          ${badge(settings.chatBot?.enabled === "true" ? "启用" : "停用", settings.chatBot?.enabled === "true" ? "active" : "ignored")}
        </div>
        <div class="settings-form">
          <label>
            接入类型
            <select id="chatBotProvider">
              ${settingsOption("nvidia", "NVIDIA Build（推荐）", chatBotProvider)}
              ${settingsOption("openai", "GPT / OpenAI 兼容接口", chatBotProvider)}
              ${settingsOption("claude", "Claude Messages 接口", chatBotProvider)}
            </select>
          </label>
          <label>
            接口地址
            <input id="chatBotBaseUrl" value="${escapeAttr(chatBotBaseUrl)}" placeholder="例如 https://api.example.com/v1" ${isNvidiaChatBot ? "readonly" : ""} />
          </label>
          <label>
            <span id="chatBotApiKeyLabel">${isNvidiaChatBot ? "NVIDIA API Key" : "API Key"}</span>
            <input id="chatBotApiKey" type="password" placeholder="${secretPlaceholder(settings.chatBot?.apiKey)}" />
          </label>
          <label>
            模型
            <input id="chatBotModel" value="${escapeAttr(chatBotModel)}" placeholder="例如 gpt-4o-mini / claude-3-5-haiku-latest" ${isNvidiaChatBot ? "readonly" : ""} />
          </label>
          <p id="chatBotEndpointHint" class="muted-note">${isNvidiaChatBot ? "NVIDIA Build 接口和模型已自动配置，只需填写 API Key。" : "OpenAI/Claude 兼容模式可自行配置接口地址和模型。"}</p>
          <label>
            机器人名
            <input id="chatBotName" value="${escapeAttr(settings.chatBot?.botName || "小樱")}" placeholder="小樱" />
          </label>
          <label>
            聊天头像 URL
            <input id="chatBotAvatarUrl" value="${escapeAttr(settings.chatBot?.avatarUrl || "")}" placeholder="留空使用 App 当前皮肤头像" />
          </label>
          <label>
            内置皮肤
            <select id="chatBotSkinId">
              ${(settings.chatBotSkins || [])
                .map((skin) =>
                  settingsOption(
                    skin.id,
                    skin.label || skin.id,
                    settings.chatBot?.skinId || "sakura",
                  ),
                )
                .join("")}
            </select>
          </label>
          <label>
            回复触发
            <select id="chatBotTriggerMode">
              ${settingsOption("mention", "仅 @小樱 时回复", settings.chatBot?.triggerMode || "mention")}
              ${settingsOption("smart", "被 @ 或问题自动回复", settings.chatBot?.triggerMode || "mention")}
            </select>
          </label>
          <label class="settings-textarea">
            系统提示词
            <textarea id="chatBotSystemPrompt" rows="5" placeholder="定义小樱的回答风格">${escapeHtml(settings.chatBot?.systemPrompt || "")}</textarea>
          </label>
          <label class="inline-check">
            <input id="chatBotEnabled" type="checkbox" ${settings.chatBot?.enabled === "true" ? "checked" : ""} />
            启用小樱机器人（新填写 API Key 时会自动开启）
          </label>
          <div class="chatbot-test">
            <label>
              测试消息
              <input id="chatBotTestInput" value="你好，小樱，连接成功了吗？" />
            </label>
            <div class="action-row">
              <button class="button" data-action="test-chat-bot">测试连接</button>
              <span id="chatBotTestStatus" class="muted-note"></span>
            </div>
            <div id="chatBotTestResult" class="bot-test-result hidden"></div>
          </div>
        </div>
      </article>
    </section>
    <div class="settings-actions">
      <button class="button primary" data-action="save-settings">保存配置</button>
    </div>
  `;
  syncChatBotProviderDefaults(chatBotProvider);
}

async function renderProxy() {
  const data = await api("/admin/proxy");
  const service = data.service || {};
  const subscription = data.subscription || {};
  const timer = subscription.timer || {};
  const runtime = data.runtime || {};
  const groups = Array.isArray(data.groups) ? data.groups : [];
  const subscriptions = Array.isArray(data.subscriptions) ? data.subscriptions : [];
  const nodes = Array.isArray(data.nodes) ? data.nodes : [];
  const manualModeEnabled = Boolean(data.manualModeEnabled);
  viewRoot.innerHTML = `
    <section class="metrics-grid">
      ${textMetric("Mihomo 服务", service.active ? "运行中" : "已停止", service.enabled ? "已设为开机启动" : "未启用开机启动", service.active ? "" : "danger")}
      ${textMetric("核心版本", data.version || "-", runtime.mode ? `模式 ${runtime.mode}` : "")}
      ${textMetric("本地代理端口", runtime.mixedPort || "-", "仅监听服务器本机")}
      ${textMetric("订阅与节点", `${subscriptions.length} 个订阅 · ${data.nodeTotal || nodes.length} 个节点`, timer.active ? "每小时自动更新" : "自动更新已停止")}
    </section>

    <section class="settings-grid">
      <article class="settings-card">
        <div class="section-title">
          <span>服务控制</span>
          ${badge(service.active ? "运行中" : "已停止", service.active ? "active" : "ignored")}
        </div>
        <div class="settings-form">
          <div class="settings-actions proxy-actions">
            <button class="button ${service.active ? "danger" : "primary"}" data-action="proxy-toggle-service" data-enabled="${service.active ? "false" : "true"}">${service.active ? "停止代理" : "启动代理"}</button>
            <button class="button" data-action="proxy-test" ${service.active ? "" : "disabled"}>检测出口</button>
          </div>
          <p class="muted-note">${service.active ? `日志级别 ${escapeHtml(runtime.logLevel || "-")} · IPv6 ${runtime.ipv6 ? "启用" : "关闭"}` : "代理服务当前未运行"}</p>
        </div>
      </article>

      <article class="settings-card">
        <div class="section-title">
          <span>添加订阅</span>
          ${badge(subscription.configured ? `${subscriptions.length} 个已配置` : "未配置", subscription.configured ? "active" : "ignored")}
        </div>
        <div class="settings-form">
          <label>
            订阅名称
            <input id="proxySubscriptionName" maxlength="80" placeholder="例如：机场 A" />
          </label>
          <label>
            HTTPS 订阅地址
            <input id="proxySubscriptionUrl" type="password" autocomplete="off" placeholder="保存后不会在后台显示" />
          </label>
          <div class="settings-actions proxy-actions">
            <button class="button primary" data-action="proxy-add-subscription">添加并更新</button>
            <button class="button" data-action="proxy-update-all-subscriptions" ${subscription.configured ? "" : "disabled"}>更新全部</button>
          </div>
          <p class="muted-note">仅接受 HTTPS 公网订阅。新增、删除或更新时会重新生成统一节点池，原始订阅地址不会回传到浏览器。</p>
        </div>
      </article>

      <article class="settings-card">
        <div class="section-title"><span>订阅列表</span>${badge(`${subscriptions.length} 个`, "active")}</div>
        <div class="proxy-subscription-list">
          ${
            subscriptions.length
              ? subscriptions
                  .map(
                    (item) => `<div class="proxy-subscription-item">
                      <div><strong>${escapeHtml(item.name || "未命名订阅")}</strong><small>${Number(item.nodeCount || 0)} 个节点</small></div>
                      <div class="proxy-actions">
                        <button class="button small" data-action="proxy-update-subscription" data-id="${escapeAttr(item.id || "")}">更新</button>
                        <button class="button small danger" data-action="proxy-delete-subscription" data-id="${escapeAttr(item.id || "")}" data-name="${escapeAttr(item.name || "订阅")}">删除</button>
                      </div>
                    </div>`,
                  )
                  .join("")
              : empty("尚未添加订阅")
          }
        </div>
      </article>

      <article class="settings-card">
        <div class="section-title"><span>手动节点切换</span>${badge(manualModeEnabled ? "已启用" : "未启用", manualModeEnabled ? "active" : "ignored")}</div>
        <div class="settings-form">
          <p class="muted-note">启用后可在下方查看所有节点，并把流量切换到任意节点；未手动选择时仍可保持自动优选。</p>
          <button class="button ${manualModeEnabled ? "muted" : "primary"}" data-action="proxy-enable-manual-mode" ${manualModeEnabled ? "disabled" : ""}>启用手动节点切换</button>
        </div>
      </article>

      ${groups
        .map(
          (group, index) => `<article class="settings-card">
            <div class="section-title">
              <span>${escapeHtml(group.name || "策略组")}</span>
              ${badge(group.current || "未选择", "active")}
            </div>
            <div class="settings-form">
              <label>
                当前策略
                <select id="proxyGroupChoice-${index}">
                  ${(group.options || [])
                    .map((choice) => settingsOption(choice, choice, group.current))
                    .join("")}
                </select>
              </label>
              <button class="button primary" data-action="proxy-set-group" data-index="${index}" data-group="${escapeAttr(group.name || "")}">应用策略</button>
            </div>
          </article>`,
        )
        .join("")}
    </section>

    <section class="admin-panel proxy-nodes-panel">
      <div class="section-title">
        <span>全部节点</span>
        <div class="proxy-actions">
          ${badge(`${data.nodeTotal || nodes.length} 个`, "active")}
          <button class="button small" data-action="proxy-test-all-nodes" ${service.active && nodes.length ? "" : "disabled"}>测速全部节点</button>
        </div>
      </div>
      <p class="muted-note">节点名称带有订阅名称前缀；可单独测速或并发测试全部节点，延迟结果由 Mihomo 控制器返回。</p>
      <div class="proxy-node-list">
        ${
          nodes.length
            ? nodes
                .map(
                  (node) => `<article class="proxy-node-item">
                    <div><strong>${escapeHtml(node.name || "未命名节点")}</strong><small>${escapeHtml(node.type || "代理")} · ${node.delay ? `${node.delay} ms` : "待测速"} · ${node.alive ? "可用" : "状态未知"}</small></div>
                    <button class="button small primary" data-action="proxy-set-node" data-node="${escapeAttr(node.name || "")}" ${manualModeEnabled ? "" : "disabled"}>切换到此节点</button>
                  </article>`,
                )
                .join("")
            : empty("更新订阅后会显示节点列表")
        }
      </div>
    </section>
  `;
}


async function handleOperationsAction(action, actionElement) {
  if (action === "apply-analytics-filter") {
      state.analytics.q = valueOf("#analyticsErrorQuery");
      await renderAnalytics();
    } else if (action === "clear-analytics-filter") {
      state.analytics.q = "";
      await renderAnalytics();
    } else if (action === "finance-page") {
      state.pages.finance = Number(actionElement.dataset.page || 1);
      await renderFinance();
    } else if (action === "race-page") {
      state.pages.race = Number(actionElement.dataset.page || 1);
      await renderRace();
    } else if (action === "notifications-page") {
      state.pages.notifications = Number(actionElement.dataset.page || 1);
      await renderNotifications();
    } else if (action === "audit-page") {
      state.pages.audit = Number(actionElement.dataset.page || 1);
      await renderAudit();
    } else if (action === "select-race-round") {
      state.selected.race = Number(actionElement.dataset.id || 0);
      await renderRace();
    } else if (action === "send-broadcast") {
      const title = valueOf("#broadcastTitle");
      const content = valueOf("#broadcastContent");
      const category = valueOf("#broadcastCategory") || "system";
      if (!title || !content) {
        renderNotice("请填写通知标题和正文", "error");
        return;
      }
      if (!confirm("确认向当前全部正常用户发送这条通知？")) return;
      const result = await api("/admin/notifications/broadcast", {
        method: "POST",
        body: { title, content, category },
      });
      renderNotice(`通知已发送给 ${result.recipientCount || 0} 位用户`);
      state.pages.notifications = 1;
      await renderNotifications();
    }

  if (action === "save-settings") {
      await api("/admin/settings", {
        method: "PATCH",
        body: collectSettingsPayload(),
      });
      renderNotice("配置已保存");
      await renderSettings();
    } else if (action === "test-chat-bot") {
      await testChatBot();
    } else if (action === "proxy-test") {
      const result = await api("/admin/proxy/test", { method: "POST" });
      const checks = Array.isArray(result.checks) ? result.checks : [];
      const exitIp = checks.find((item) => item.name === "ip")?.value || "";
      renderNotice(result.ok ? `代理出口正常${exitIp ? ` · ${exitIp}` : ""}` : "部分代理检测未通过", result.ok ? "" : "error");
    } else if (action === "proxy-test-all-nodes") {
      actionElement.disabled = true;
      actionElement.textContent = "测速中...";
      const result = await api("/admin/proxy/nodes/test-all", { method: "POST" });
      await renderProxy();
      renderNotice(`节点测速完成：${result.available || 0}/${result.tested || 0} 个可用${result.failed ? ` · ${result.failed} 个失败` : ""}`, result.failed ? "error" : "");
    } else if (action === "proxy-update-all-subscriptions") {
      if (!confirm("确认立即更新全部代理订阅并重载 Mihomo？")) return;
      await api("/admin/proxy/subscriptions/update-all", { method: "POST" });
      renderNotice("全部代理订阅已更新");
      await renderProxy();
    } else if (action === "proxy-update-subscription") {
      const id = actionElement.dataset.id || "";
      await api(`/admin/proxy/subscriptions/${encodeURIComponent(id)}/update`, { method: "POST" });
      renderNotice("代理订阅已更新");
      await renderProxy();
    } else if (action === "proxy-add-subscription") {
      const name = valueOf("#proxySubscriptionName");
      const url = valueOf("#proxySubscriptionUrl");
      if (!name || !url) {
        renderNotice("请填写订阅名称和 HTTPS 订阅地址", "error");
        return;
      }
      if (!confirm("确认添加订阅并立即下载节点？订阅地址不会显示在后台。")) return;
      await api("/admin/proxy/subscriptions", {
        method: "POST",
        body: { name, url },
      });
      renderNotice("代理订阅已添加并更新");
      await renderProxy();
    } else if (action === "proxy-delete-subscription") {
      const id = actionElement.dataset.id || "";
      const name = actionElement.dataset.name || "订阅";
      if (!confirm(`确认删除“${name}”？对应节点会从代理池移除。`)) return;
      await api(`/admin/proxy/subscriptions/${encodeURIComponent(id)}`, { method: "DELETE" });
      renderNotice("代理订阅已删除");
      await renderProxy();
    } else if (action === "proxy-enable-manual-mode") {
      if (!confirm("确认启用手动节点切换？默认仍保持自动优选，不会立即中断现有代理。")) return;
      await api("/admin/proxy/enable-manual-mode", { method: "POST" });
      renderNotice("手动节点切换已启用");
      await renderProxy();
    } else if (action === "proxy-set-node") {
      const choice = actionElement.dataset.node || "";
      await api("/admin/proxy/group", {
        method: "PATCH",
        body: { group: "NODE-MANUAL", choice },
      });
      await api("/admin/proxy/group", {
        method: "PATCH",
        body: { group: "PROXY-MODE", choice: "NODE-MANUAL" },
      });
      renderNotice(`已切换到节点：${choice}`);
      await renderProxy();
    } else if (action === "proxy-toggle-service") {
      const enabled = actionElement.dataset.enabled === "true";
      if (!confirm(enabled ? "确认启动 Mihomo 代理服务？" : "确认停止 Mihomo？依赖代理的出站请求将不可用。")) return;
      await api("/admin/proxy/service", {
        method: "PATCH",
        body: { enabled },
      });
      renderNotice(enabled ? "代理服务已启动" : "代理服务已停止");
      await renderProxy();
    } else if (action === "proxy-set-group") {
      const index = Number(actionElement.dataset.index || 0);
      const group = actionElement.dataset.group || "";
      const choice = valueOf(`#proxyGroupChoice-${index}`);
      await api("/admin/proxy/group", {
        method: "PATCH",
        body: { group, choice },
      });
      renderNotice("代理策略已切换");
      await renderProxy();
    }
}
