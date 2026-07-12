// Growth recommendations, rankings, campaigns, horse-racing seasons, and level rules.
// Loaded as an ordered deferred browser script; shared bindings are declared in admin-core.js.

async function renderGrowthOps() {
  const { days, period, metric: rankingMetric } = state.growthOps;
  const [overview, rankings, campaigns, seasons] = await Promise.all([
    api(`/admin/growth/overview${makeQuery({ days })}`),
    api(`/admin/growth/rankings${makeQuery({ period, metric: rankingMetric, limit: 50 })}`),
    api("/admin/growth/campaigns?pageSize=50"),
    api("/admin/growth/seasons?pageSize=50"),
  ]);
  const funnel = overview.funnel || { steps: [], content: [], retention: [] };
  const activeSeason = overview.season || {};
  const now = new Date();
  const startsAt = toLocalDateTimeValue(new Date(now.getTime() - 5 * 60_000).toISOString());
  const campaignEndsAt = toLocalDateTimeValue(new Date(now.getTime() + 14 * 86400000).toISOString());
  const seasonEndsAt = toLocalDateTimeValue(new Date(now.getTime() + 90 * 86400000).toISOString());
  const controlMap = new Map(
    (rankings.controls || []).map((item) => [`${item.rankingKey}:${item.contentKey}`, item]),
  );
  const boardKey = `${period}_${rankingMetric}`;

  viewRoot.innerHTML = `
    <section class="growth-ops-toolbar">
      <label>统计周期
        <select id="growthOpsDays">
          ${[1, 7, 14, 30, 90].map((value) => option(value, `${value} 天`, days)).join("")}
        </select>
      </label>
      <label>榜单周期
        <select id="growthOpsPeriod">
          ${option("daily", "日榜", period)}
          ${option("weekly", "周榜", period)}
        </select>
      </label>
      <label>榜单类型
        <select id="growthOpsMetric">
          ${option("hot", "热度", rankingMetric)}
          ${option("new", "新作", rankingMetric)}
          ${option("following", "追更", rankingMetric)}
          ${option("completion", "完读/完播", rankingMetric)}
        </select>
      </label>
    </section>

    <section class="content-ops-summary">
      ${metric("行为事件", overview.totals?.behaviorEvents || 0, "事件 ID 去重后入库")}
      ${metric("生效活动", overview.totals?.campaignsActive || 0, "受起止时间、版本和分群约束")}
      ${metric("奖励领取", overview.totals?.rewardsClaimed || 0, "每用户每任务只可入账一次")}
      ${metric("赛季参与", overview.totals?.seasonParticipants || 0, "按轮次唯一结算")}
    </section>

    <section class="section-block">
      <div class="section-title"><span>内容转化漏斗</span><small>${days} 天 · 去重用户/设备</small></div>
      <div class="growth-funnel">
        ${(funnel.steps || []).map((step) => `
          <article>
            <span>${escapeHtml(growthEventLabel(step.event))}</span>
            <strong>${Number(step.actors || 0)}</strong>
            <small>${step.conversionFromPrevious == null ? "漏斗起点" : `上一步转化 ${(step.conversionFromPrevious * 100).toFixed(1)}%`}</small>
          </article>`).join("")}
      </div>
      <div class="data-table growth-content-funnel">
        <div class="data-row data-head"><span>内容</span><span>曝光 → 打开</span><span>开始 → 完成</span><span>人数</span></div>
        ${(funnel.content || []).slice(0, 12).map((item) => `
          <div class="data-row">
            <span><strong>${escapeHtml(item.title)}</strong><small>${escapeHtml(item.contentType)} · ${escapeHtml(item.contentKey)}</small></span>
            <span>${(Number(item.openRate || 0) * 100).toFixed(1)}%</span>
            <span>${(Number(item.completionRate || 0) * 100).toFixed(1)}%</span>
            <span>${item.exposures || 0} / ${item.opens || 0} / ${item.starts || 0} / ${item.completes || 0}</span>
          </div>`).join("") || empty("暂无内容转化数据")}
      </div>
    </section>

    <section class="section-block">
      <div class="section-title"><span>${period === "daily" ? "日榜" : "周榜"} · ${growthRankingLabel(rankingMetric)}</span><small>刷量计数已按用户/设备每日封顶</small></div>
      <div class="data-table growth-ranking-table">
        <div class="data-row data-head"><span>排名与内容</span><span>得分/解释</span><span>置顶/排除</span><span>人工权重与备注</span><span>操作</span></div>
        ${(rankings.items || []).map((item, index) => {
          const control = controlMap.get(`${boardKey}:${item.content.stableKey}`) || {};
          return `
            <div class="data-row">
              <span><strong>#${item.rank} ${escapeHtml(item.content.title)}</strong><small>${escapeHtml(item.content.contentType)} · ${escapeHtml(item.content.stableKey)}</small></span>
              <span><strong>${Number(item.score || 0).toFixed(2)}</strong><small>${escapeHtml(item.explanation || "")}</small></span>
              <span class="growth-checks">
                <label><input id="growthPinned-${index}" type="checkbox" ${control.pinned ? "checked" : ""}/>置顶</label>
                <label><input id="growthExcluded-${index}" type="checkbox" ${control.excluded ? "checked" : ""}/>排除</label>
              </span>
              <span><input id="growthWeight-${index}" type="number" value="${Number(control.manualWeight || 0)}" placeholder="权重"/><input id="growthNote-${index}" value="${escapeHtml(control.note || "")}" placeholder="运营备注"/></span>
              <span><button class="button" data-action="save-growth-ranking" data-row="${index}" data-key="${escapeHtml(item.content.stableKey)}">保存</button></span>
            </div>`;
        }).join("") || empty("当前榜单没有可用内容")}
      </div>
      <div class="growth-control-list">
        ${(rankings.controls || []).map((item) => `
          <span>
            <strong>${escapeHtml(item.title || item.contentKey)}</strong>
            <small>${escapeHtml(item.rankingKey)} · ${item.pinned ? "置顶 " : ""}${item.excluded ? "排除 " : ""}权重 ${item.manualWeight || 0}</small>
            <button class="button muted" data-action="delete-growth-ranking" data-ranking-key="${escapeHtml(item.rankingKey)}" data-key="${escapeHtml(item.contentKey)}">移除规则</button>
          </span>`).join("")}
      </div>
    </section>

    <section class="growth-ops-columns">
      <section class="section-block">
        <div class="section-title"><span>创建活动与任务</span><small>奖励领取自动幂等</small></div>
        <div class="growth-form-grid">
          <label>活动 Key<input id="growthCampaignKey" placeholder="summer-reading-2026"/></label>
          <label>活动标题<input id="growthCampaignTitle" placeholder="夏日阅读挑战"/></label>
          <label>状态<select id="growthCampaignStatus"><option value="draft">草稿</option><option value="active">立即生效</option></select></label>
          <label>用户分群<select id="growthCampaignAudience"><option value="all">全部用户</option><option value="login">仅登录用户</option></select></label>
          <label>开始时间<input id="growthCampaignStartsAt" type="datetime-local" value="${startsAt}"/></label>
          <label>结束时间<input id="growthCampaignEndsAt" type="datetime-local" value="${campaignEndsAt}"/></label>
          <label>最低版本<input id="growthCampaignMinVersion" type="number" value="0"/></label>
          <label>最高版本<input id="growthCampaignMaxVersion" type="number" value="0"/></label>
          <label class="wide">活动说明<textarea id="growthCampaignDescription" placeholder="面向用户展示的活动说明"></textarea></label>
          <label>任务 Key<input id="growthCampaignTaskKey" placeholder="start-three"/></label>
          <label>任务标题<input id="growthCampaignTaskTitle" placeholder="开始阅读/观看 3 次"/></label>
          <label>行为<select id="growthCampaignTaskEvent">${growthActivityEventOptions()}</select></label>
          <label>目标次数<input id="growthCampaignTaskTarget" type="number" min="1" value="3"/></label>
          <label>奖励积分<input id="growthCampaignTaskPoints" type="number" min="0" value="20"/></label>
          <label>奖励樱花币<input id="growthCampaignTaskCoins" type="number" min="0" value="50"/></label>
        </div>
        <button class="button primary" data-action="create-growth-campaign">创建活动</button>
      </section>

      <section class="section-block">
        <div class="section-title"><span>活动列表</span><small>${campaigns.total || 0} 个</small></div>
        <div class="growth-ops-list">
          ${(campaigns.items || []).map((item) => `
            <article>
              <div><strong>${escapeHtml(item.title)}</strong>${badge(item.status, item.status === "active" ? "active" : "")}</div>
              <p>${escapeHtml(item.campaignKey)} · 修订 ${item.revision} · ${item.taskCount} 个任务 · ${item.claimCount} 次领取</p>
              <small>${formatTime(item.startsAt)} - ${formatTime(item.endsAt)}</small>
              <div class="growth-task-chips">
                ${(item.tasks || []).map((task) => `<span>${escapeHtml(task.title)} ${task.targetCount} 次 ${badge(task.status, task.status === "active" ? "active" : "")}<button data-action="delete-growth-campaign-task" data-campaign-id="${item.id}" data-task-id="${task.id}">×</button></span>`).join("")}
              </div>
              <div class="inline-actions">
                <button class="button" data-action="set-growth-campaign-status" data-id="${item.id}" data-status="active">生效</button>
                <button class="button" data-action="set-growth-campaign-status" data-id="${item.id}" data-status="paused">暂停</button>
                <button class="button" data-action="add-growth-campaign-task" data-id="${item.id}">添加任务</button>
                <button class="button muted" data-action="rollback-growth-campaign" data-id="${item.id}">回滚</button>
              </div>
            </article>`).join("") || empty("还没有活动")}
        </div>
      </section>
    </section>

    <section class="growth-ops-columns">
      <section class="section-block">
        <div class="section-title"><span>创建赛马赛季</span><small>唯一轮次结算、段位与任务</small></div>
        <div class="growth-form-grid">
          <label>赛季 Key<input id="growthSeasonKey" placeholder="season-2026-s1"/></label>
          <label>赛季标题<input id="growthSeasonTitle" placeholder="樱花竞速 S1"/></label>
          <label>状态<select id="growthSeasonStatus"><option value="draft">草稿</option><option value="active">立即生效</option></select></label>
          <label>开始时间<input id="growthSeasonStartsAt" type="datetime-local" value="${startsAt}"/></label>
          <label>结束时间<input id="growthSeasonEndsAt" type="datetime-local" value="${seasonEndsAt}"/></label>
          <label>参与积分<input id="growthSeasonParticipation" type="number" value="10"/></label>
          <label>胜利积分<input id="growthSeasonWinPoints" type="number" value="20"/></label>
          <label>任务轮次<input id="growthSeasonTaskTarget" type="number" value="3"/></label>
          <label>前十奖励<input id="growthSeasonTopReward" type="number" value="500"/></label>
        </div>
        <button class="button primary" data-action="create-growth-season">创建赛季</button>
      </section>

      <section class="section-block">
        <div class="section-title"><span>赛季与排行榜</span><small>${seasons.total || 0} 个赛季</small></div>
        <div class="growth-ops-list">
          ${(seasons.items || []).map((item) => `
            <article>
              <div><strong>${escapeHtml(item.title)}</strong>${badge(item.status, item.status === "active" ? "active" : "")}</div>
              <p>${escapeHtml(item.seasonKey)} · ${item.participants || 0} 位参与者 · 修订 ${item.revision}</p>
              <small>${formatTime(item.startsAt)} - ${formatTime(item.endsAt)}</small>
              <div class="inline-actions">
                <button class="button" data-action="set-growth-season-status" data-id="${item.id}" data-status="active">设为当前赛季</button>
                <button class="button muted" data-action="set-growth-season-status" data-id="${item.id}" data-status="paused">暂停</button>
                <button class="button" data-action="add-growth-season-task" data-id="${item.id}">添加任务</button>
                <button class="button" data-action="add-growth-season-reward" data-id="${item.id}">添加奖励</button>
                <button class="button danger" data-action="finalize-growth-season" data-id="${item.id}">结算赛季</button>
              </div>
            </article>`).join("") || empty("还没有赛季")}
        </div>
        <div class="data-table growth-season-board">
          <div class="data-row data-head"><span>名次</span><span>用户</span><span>积分/段位</span><span>轮次/胜场</span></div>
          ${(activeSeason.leaderboard || []).slice(0, 20).map((item) => `
            <div class="data-row"><span>#${item.rank}</span><span>${escapeHtml(item.nickname || `用户 ${item.userId}`)}</span><span>${item.points} / ${escapeHtml(item.tier)}</span><span>${item.rounds} / ${item.wins}</span></div>`).join("") || empty("当前赛季暂无排行")}
        </div>
      </section>
    </section>
  `;
}

async function renderGrowth() {
  const data = await api("/admin/growth/rules");
  viewRoot.innerHTML = `
    <section class="growth-grid">
      ${data.levels
        .map(
          (item) => `
            <article class="growth-card">
              <div class="growth-head">
                <strong>Lv${item.level} ${escapeHtml(item.name)}</strong>
                <span>${item.points} 积分</span>
              </div>
              <p>${escapeHtml(item.effect)}</p>
              <div class="growth-meta">
                <span>满勤约 ${item.targetDays || 0} 天</span>
                <span>每日积分上限 ${item.dailyPointCap}</span>
              </div>
              <div class="permission-list">
                ${(item.permissions || [])
                  .map((permission) => `<span>${escapeHtml(permission)}</span>`)
                  .join("")}
              </div>
            </article>
          `,
        )
        .join("")}
    </section>
  `;
}


async function handleGrowthAction(action, actionElement) {
    if (action === "save-growth-ranking") {
      const row = actionElement.dataset.row;
      const rankingKey = `${state.growthOps.period}_${state.growthOps.metric}`;
      const contentKey = actionElement.dataset.key;
      await api(
        `/admin/growth/rankings/${encodeURIComponent(rankingKey)}/${encodeURIComponent(contentKey)}`,
        {
          method: "PUT",
          body: {
            pinned: Boolean(document.querySelector(`#growthPinned-${row}`)?.checked),
            excluded: Boolean(document.querySelector(`#growthExcluded-${row}`)?.checked),
            manualWeight: Number(valueOf(`#growthWeight-${row}`) || 0),
            note: valueOf(`#growthNote-${row}`),
          },
        },
      );
      renderNotice("榜单规则已保存");
      await renderGrowthOps();
    } else if (action === "delete-growth-ranking") {
      await api(
        `/admin/growth/rankings/${encodeURIComponent(actionElement.dataset.rankingKey)}/${encodeURIComponent(actionElement.dataset.key)}`,
        { method: "DELETE" },
      );
      renderNotice("榜单人工规则已移除");
      await renderGrowthOps();
    } else if (action === "create-growth-campaign") {
      const taskTitle = valueOf("#growthCampaignTaskTitle");
      const body = {
        campaignKey: valueOf("#growthCampaignKey"),
        title: valueOf("#growthCampaignTitle"),
        description: valueOf("#growthCampaignDescription"),
        status: valueOf("#growthCampaignStatus") || "draft",
        startsAt: valueOf("#growthCampaignStartsAt"),
        endsAt: valueOf("#growthCampaignEndsAt"),
        minVersionCode: Number(valueOf("#growthCampaignMinVersion") || 0),
        maxVersionCode: Number(valueOf("#growthCampaignMaxVersion") || 0),
        audience:
          valueOf("#growthCampaignAudience") === "login"
            ? { loggedIn: true }
            : {},
        tasks: taskTitle
          ? [{
              taskKey: valueOf("#growthCampaignTaskKey"),
              title: taskTitle,
              eventName: valueOf("#growthCampaignTaskEvent"),
              targetCount: Number(valueOf("#growthCampaignTaskTarget") || 1),
              rewardPoints: Number(valueOf("#growthCampaignTaskPoints") || 0),
              rewardCoins: Number(valueOf("#growthCampaignTaskCoins") || 0),
            }]
          : [],
      };
      await api("/admin/growth/campaigns", { method: "POST", body });
      renderNotice("活动和首个任务已创建");
      await renderGrowthOps();
    } else if (action === "set-growth-campaign-status") {
      await api(`/admin/growth/campaigns/${actionElement.dataset.id}`, {
        method: "PATCH",
        body: { status: actionElement.dataset.status },
      });
      renderNotice("活动状态已更新");
      await renderGrowthOps();
    } else if (action === "add-growth-campaign-task") {
      const taskKey = prompt("任务 Key（英文、数字、短横线）", "start-three");
      if (!taskKey) return;
      const title = prompt("任务标题", "开始阅读/观看 3 次");
      if (!title) return;
      const eventName = prompt("事件：exposure/click/open/start/complete/favorite/horse_race_bet/horse_race_round/horse_race_win", "start");
      const targetCount = Number(prompt("目标数量", "3") || 0);
      await api(`/admin/growth/campaigns/${actionElement.dataset.id}/tasks`, {
        method: "POST",
        body: { taskKey, title, eventName, targetCount, rewardPoints: 20, rewardCoins: 50 },
      });
      renderNotice("活动任务已添加");
      await renderGrowthOps();
    } else if (action === "delete-growth-campaign-task") {
      if (!confirm("确认移除这个活动任务？已有领奖记录时会改为停用。")) return;
      await api(
        `/admin/growth/campaigns/${actionElement.dataset.campaignId}/tasks/${actionElement.dataset.taskId}`,
        { method: "DELETE" },
      );
      renderNotice("活动任务已移除或停用");
      await renderGrowthOps();
    } else if (action === "rollback-growth-campaign") {
      const revision = Number(prompt("回滚到哪个修订版本？", "1") || 0);
      if (!revision) return;
      await api(`/admin/growth/campaigns/${actionElement.dataset.id}/rollback`, {
        method: "POST",
        body: { revision },
      });
      renderNotice(`活动已回滚到修订 ${revision}，并自动暂停`);
      await renderGrowthOps();
    } else if (action === "create-growth-season") {
      await api("/admin/growth/seasons", {
        method: "POST",
        body: {
          seasonKey: valueOf("#growthSeasonKey"),
          title: valueOf("#growthSeasonTitle"),
          status: valueOf("#growthSeasonStatus") || "draft",
          startsAt: valueOf("#growthSeasonStartsAt"),
          endsAt: valueOf("#growthSeasonEndsAt"),
          config: {
            participationPoints: Number(valueOf("#growthSeasonParticipation") || 10),
            winPoints: Number(valueOf("#growthSeasonWinPoints") || 20),
          },
          tasks: [{
            taskKey: "rounds-1",
            title: "完成赛马轮次",
            metric: "rounds",
            targetCount: Number(valueOf("#growthSeasonTaskTarget") || 3),
          }],
          rewards: [{
            rewardKey: "top-10",
            title: "赛季前十奖励",
            minRank: 1,
            maxRank: 10,
            rewardCoins: Number(valueOf("#growthSeasonTopReward") || 500),
          }],
        },
      });
      renderNotice("赛马赛季已创建");
      await renderGrowthOps();
    } else if (action === "set-growth-season-status") {
      await api(`/admin/growth/seasons/${actionElement.dataset.id}`, {
        method: "PATCH",
        body: { status: actionElement.dataset.status },
      });
      renderNotice("赛季状态已更新");
      await renderGrowthOps();
    } else if (action === "add-growth-season-task") {
      const metricName = prompt("指标：rounds / wins / bet / profit", "rounds");
      if (!metricName) return;
      const targetCount = Number(prompt("目标数量", "10") || 0);
      await api(`/admin/growth/seasons/${actionElement.dataset.id}/tasks`, {
        method: "POST",
        body: {
          taskKey: `${metricName}-${targetCount}`,
          title: `累计 ${metricName} ${targetCount}`,
          metric: metricName,
          targetCount,
          rewardCoins: 100,
        },
      });
      renderNotice("赛季任务已添加");
      await renderGrowthOps();
    } else if (action === "add-growth-season-reward") {
      const maxRank = Number(prompt("奖励覆盖到第几名？", "10") || 0);
      const rewardCoins = Number(prompt("奖励樱花币", "500") || 0);
      await api(`/admin/growth/seasons/${actionElement.dataset.id}/rewards`, {
        method: "POST",
        body: {
          rewardKey: `top-${maxRank}-${Date.now()}`,
          title: `赛季前 ${maxRank} 奖励`,
          minRank: 1,
          maxRank,
          rewardCoins,
        },
      });
      renderNotice("赛季奖励已添加");
      await renderGrowthOps();
    } else if (action === "finalize-growth-season") {
      if (!confirm("确认结束赛季并按当前排行榜发放奖励？该操作可安全重试，但结束后不应继续计分。")) return;
      const result = await api(`/admin/growth/seasons/${actionElement.dataset.id}/finalize`, {
        method: "POST",
      });
      renderNotice(`赛季已结束，本次发放 ${result.awarded || 0} 份奖励`);
      await renderGrowthOps();
    }
}
