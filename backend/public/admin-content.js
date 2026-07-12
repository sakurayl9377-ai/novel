// Content catalog, placements, source health, cache, and feature flag operations.
// Loaded as an ordered deferred browser script; shared bindings are declared in admin-core.js.

async function renderContentOps() {
  const query = makeQuery({
    q: state.q,
    status: state.status,
    type: state.contentOps.type,
    pageSize: 50,
  });
  const [catalog, placements, sourceHealth, invalidations, featureFlags] =
    await Promise.all([
      api(`/admin/content/catalog${query}`),
      api("/admin/content/placements?pageSize=100"),
      api("/admin/content/source-health"),
      api("/admin/content/cache-invalidations?pageSize=12"),
      api("/admin/content/feature-flags"),
    ]);
  const placement = state.contentOps.editPlacement;
  const flag = state.contentOps.editFlag;
  const preview = state.contentOps.preview;
  viewRoot.innerHTML = `
    <section class="content-ops-summary">
      ${metric("目录作品", catalog.total || 0, "当前筛选结果")}
      ${metric("推荐位", placements.total || 0, "草稿与生效配置")}
      ${metric("来源", sourceHealth.items?.length || 0, "已记录健康数据")}
      ${metric("缓存修订", invalidations.revision || 0, "客户端据此刷新")}
      ${metric("功能开关", featureFlags.items?.length || 0, "支持版本与灰度")}
    </section>

    <section class="section-block content-catalog-section">
      <div class="section-title">
        <span>统一内容目录</span>
        <label class="compact-label">类型
          <select id="contentOpsType">
            <option value="">全部</option>
            <option value="novel" ${state.contentOps.type === "novel" ? "selected" : ""}>小说</option>
            <option value="manga" ${state.contentOps.type === "manga" ? "selected" : ""}>漫画</option>
            <option value="anime" ${state.contentOps.type === "anime" ? "selected" : ""}>动漫</option>
          </select>
        </label>
      </div>
      <div class="data-table content-catalog-table">
        <div class="data-row data-head"><span>作品</span><span>来源</span><span>状态</span><span>修订</span><span>别名（逗号分隔）</span></div>
        ${(catalog.items || []).map((item) => `
          <div class="data-row">
            <span><strong>${escapeHtml(item.title)}</strong><small>${escapeHtml(item.contentType)} · ${escapeHtml(item.stableKey)}</small></span>
            <span><strong>${escapeHtml(item.sourceKey)}</strong><small>${escapeHtml(item.sourceItemId)}</small></span>
            <span class="catalog-status-actions">
              ${badge(item.status, item.status === "active" ? "resolved" : "open")}
              ${item.status === "pending" ? `<button class="button muted" data-action="set-content-status" data-key="${escapeAttr(item.stableKey)}" data-status="active" data-revision="${item.revision}">通过</button>` : `<button class="button muted" data-action="set-content-status" data-key="${escapeAttr(item.stableKey)}" data-status="${item.status === "active" ? "inactive" : "active"}" data-revision="${item.revision}">${item.status === "active" ? "停用" : "启用"}</button>`}
            </span>
            <span>r${item.revision}<small>${formatTime(item.lastSeenAt)}</small></span>
            <span class="content-alias-editor">
              <input id="contentAliases-${item.id}" value="${escapeAttr((item.aliases || []).join(", "))}" placeholder="搜索别名" />
              <button class="button muted" data-action="save-content-aliases" data-key="${escapeAttr(item.stableKey)}" data-input-id="${item.id}" data-revision="${item.revision}">保存</button>
            </span>
          </div>`).join("") || empty("当前筛选下没有目录作品")}
      </div>
    </section>

    <section class="content-ops-grid">
      <article id="placementEditor" class="settings-card">
        <div class="section-title"><span>${placement ? "编辑推荐位" : "新增推荐位"}</span>${placement ? badge(`r${placement.revision}`, "open") : ""}</div>
        <div class="compact-form content-placement-form">
          <label>类型<select id="placementType">
            ${placementTypeOptions(placement?.placementType || "recommend")}
          </select></label>
          <label>位置<input id="placementPosition" value="${escapeAttr(placement?.position || "home-main")}" placeholder="home-main" /></label>
          <label>内容 stableKey<input id="placementContentKey" value="${escapeAttr(placement?.contentKey || catalog.items?.[0]?.stableKey || "")}" /></label>
          <label>自定义标题<input id="placementTitle" value="${escapeAttr(placement?.customTitle || "")}" /></label>
          <label>自定义图片<input id="placementImage" value="${escapeAttr(placement?.customImageUrl || "")}" placeholder="https://..." /></label>
          <label>排序<input id="placementSort" type="number" value="${Number(placement?.sortOrder || 0)}" /></label>
          <label>开始时间<input id="placementStartsAt" type="datetime-local" value="${escapeAttr(toLocalDateTimeValue(placement?.startsAt))}" /></label>
          <label>结束时间<input id="placementEndsAt" type="datetime-local" value="${escapeAttr(toLocalDateTimeValue(placement?.endsAt))}" /></label>
          <label>状态<select id="placementStatus">
            ${placementStatusOptions(placement?.status || "draft")}
          </select></label>
          <label class="wide-field">受众 JSON<textarea id="placementAudience" rows="4" placeholder='{"minVersionCode":38,"percentage":50,"platforms":["android"]}'>${escapeHtml(JSON.stringify(placement?.audience || {}, null, 2))}</textarea></label>
        </div>
        <div class="content-action-row">
          <button class="button primary" data-action="save-placement">${placement ? "保存更新" : "创建推荐位"}</button>
          ${placement ? '<button class="button muted" data-action="cancel-placement-edit">取消编辑</button>' : ""}
        </div>
      </article>

      <article class="settings-card">
        <div class="section-title"><span>客户端命中预览</span>${badge("不泄露后台字段", "resolved")}</div>
        <div class="compact-form">
          <label>版本号<input id="contentPreviewVersion" type="number" min="0" value="39" /></label>
          <label>平台<select id="contentPreviewPlatform"><option value="android">Android</option><option value="ios">iOS</option></select></label>
          <button class="button primary" data-action="preview-content-ops">预览命中结果</button>
        </div>
        ${preview ? `
          <div class="preview-box content-bootstrap-preview">
            <strong>缓存修订 ${preview.cacheRevision || 0}</strong>
            <span>命中推荐位 ${preview.preview?.placementCount || 0} 个</span>
            <span>命中开关 ${(preview.preview?.matchedFlagKeys || []).map(escapeHtml).join("、") || "无"}</span>
            <span>最低版本 ${preview.client?.minimumVersionCode || 0}${preview.client?.updateRequired ? "（需要升级）" : ""}</span>
          </div>` : '<p class="muted-note">按版本和平台模拟 bootstrap，核对有效期、受众和灰度命中。</p>'}
      </article>
    </section>

    <section class="section-block">
      <div class="section-title"><span>推荐位列表</span><small>${placements.total || 0} 条</small></div>
      <div class="content-card-list">
        ${(placements.items || []).map((item) => `
          <article class="content-operation-card">
            <div><strong>${escapeHtml(item.customTitle || item.content?.title || item.contentKey)}</strong><small>${escapeHtml(item.placementType)} · ${escapeHtml(item.position)} · 顺序 ${item.sortOrder}</small></div>
            <div><span>${badge(item.status, item.status === "active" ? "resolved" : "open")}</span><small>${formatPlacementWindow(item)}</small></div>
            <div class="content-action-row">
              <button class="button muted" data-action="edit-placement" data-item="${escapeAttr(JSON.stringify(item))}">编辑</button>
              <button class="button danger" data-action="delete-placement" data-id="${item.id}">删除</button>
            </div>
          </article>`).join("") || empty("尚未配置推荐位")}
      </div>
    </section>

    <section class="content-ops-grid">
      <article class="settings-card">
        <div class="section-title"><span>来源健康</span>${badge("人工探测记录", "open")}</div>
        <div class="compact-form">
          <label>内容类型<select id="sourceHealthType"><option value="novel">小说</option><option value="manga">漫画</option><option value="anime">动漫</option></select></label>
          <label>来源 key<input id="sourceHealthKey" placeholder="source-key" /></label>
          <label>结果<select id="sourceHealthSuccess"><option value="true">成功</option><option value="false">失败</option></select></label>
          <label>延迟 ms<input id="sourceHealthLatency" type="number" min="0" value="0" /></label>
          <label class="wide-field">错误说明<input id="sourceHealthError" placeholder="失败时必填" /></label>
          <button class="button primary" data-action="record-source-health">记录结果</button>
        </div>
        <div class="mini-list source-health-list">
          ${(sourceHealth.items || []).map((item) => `
            <div><span><strong>${escapeHtml(item.sourceKey)}</strong><small>${escapeHtml(item.contentType)} · 总成功率 ${item.successRate == null ? "-" : `${Math.round(item.successRate * 100)}%`}</small></span><span>真实流量 ${item.observedTraffic?.requestCount || 0}<small>${item.observedTraffic?.averageLatencyMs || 0} ms · 失败 ${item.observedTraffic?.failureCount || 0}</small><small>人工探测 ${item.manualProbe?.requestCount || 0} · 失败 ${item.manualProbe?.failureCount || 0}</small></span></div>`).join("") || empty("尚无来源健康记录")}
        </div>
      </article>

      <article class="settings-card">
        <div class="section-title"><span>缓存失效</span>${badge(`revision ${invalidations.revision || 0}`, "resolved")}</div>
        <div class="compact-form">
          <label>范围<select id="cacheInvalidationScope"><option value="all">全部</option><option value="content">单内容</option><option value="home">首页</option><option value="feature_flags">功能开关</option><option value="novel">小说</option><option value="manga">漫画</option><option value="anime">动漫</option><option value="source">来源</option></select></label>
          <label>key<input id="cacheInvalidationKey" placeholder="非全部范围时必填" /></label>
          <label class="wide-field">原因<input id="cacheInvalidationReason" placeholder="说明为何需要客户端刷新" /></label>
          <button class="button primary" data-action="create-cache-invalidation">创建失效指令</button>
        </div>
        <div class="mini-list">
          ${(invalidations.items || []).map((item) => `
            <div><span><strong>r${item.revision} · ${escapeHtml(item.scope)}</strong><small>${escapeHtml(item.key || "全部 key")}</small></span><span>${escapeHtml(item.reason)}<small>${escapeHtml(item.createdBy || "管理员")} · ${formatTime(item.createdAt)}</small></span></div>`).join("") || empty("尚无缓存失效历史")}
        </div>
      </article>
    </section>

    <section id="featureFlagEditor" class="section-block">
      <div class="section-title"><span>${flag ? `编辑功能开关 ${escapeHtml(flag.key)}` : "新增功能开关"}</span>${flag ? badge(`r${flag.revision}`, "open") : ""}</div>
      <div class="settings-card">
        <div class="compact-form feature-flag-form">
          <label>key<input id="featureFlagKey" value="${escapeAttr(flag?.key || "")}" ${flag ? "disabled" : ""} placeholder="player.new_controls" /></label>
          <label>最低版本<input id="featureFlagMinVersion" type="number" min="0" value="${Number(flag?.minVersionCode || 0)}" /></label>
          <label>最高版本（0 不限）<input id="featureFlagMaxVersion" type="number" min="0" value="${Number(flag?.maxVersionCode || 0)}" /></label>
          <label>灰度比例 %<input id="featureFlagPercentage" type="number" min="0" max="100" value="${Number(flag?.percentageRollout ?? 100)}" /></label>
          <label class="inline-check"><input id="featureFlagEnabled" type="checkbox" ${flag?.enabled ? "checked" : ""} /><span>启用</span></label>
          <label class="wide-field">值 JSON<textarea id="featureFlagValue" rows="5">${escapeHtml(JSON.stringify(flag?.value ?? {}, null, 2))}</textarea></label>
        </div>
        <div class="content-action-row">
          <button class="button primary" data-action="save-feature-flag">${flag ? "保存更新" : "创建开关"}</button>
          ${flag ? '<button class="button muted" data-action="cancel-feature-edit">取消编辑</button>' : ""}
        </div>
      </div>
      <div class="content-card-list feature-flag-list">
        ${(featureFlags.items || []).map((item) => `
          <article class="content-operation-card">
            <div><strong>${escapeHtml(item.key)}</strong><small>r${item.revision} · 版本 ${item.minVersionCode || 0} - ${item.maxVersionCode || "不限"}</small></div>
            <div><span>${badge(item.enabled ? "已启用" : "已停用", item.enabled ? "resolved" : "open")}</span><small>灰度 ${item.percentageRollout}% · ${escapeHtml(JSON.stringify(item.value))}</small></div>
            <div class="content-action-row">
              <button class="button muted" data-action="edit-feature-flag" data-item="${escapeAttr(JSON.stringify(item))}">编辑</button>
              <button class="button muted" data-action="rollback-feature-flag" data-item="${escapeAttr(JSON.stringify(item))}">回滚</button>
              <button class="button danger" data-action="delete-feature-flag" data-key="${escapeAttr(item.key)}">删除</button>
            </div>
          </article>`).join("") || empty("尚无功能开关")}
      </div>
    </section>
  `;
}


async function handleContentAction(action, actionElement) {
  if (action === "set-content-status") {
      await api(
        `/admin/content/catalog/${encodeURIComponent(actionElement.dataset.key)}/status`,
        {
          method: "PATCH",
          body: {
            status: actionElement.dataset.status,
            expectedRevision: Number(actionElement.dataset.revision || 0),
          },
        },
      );
      renderNotice("目录状态已更新");
      await renderContentOps();
    } else if (action === "save-content-aliases") {
      const stableKey = actionElement.dataset.key;
      const aliases = valueOf(`#contentAliases-${actionElement.dataset.inputId}`)
        .split(/[，,\n]/)
        .map((item) => item.trim())
        .filter(Boolean);
      await api(
        `/admin/content/catalog/${encodeURIComponent(stableKey)}/aliases`,
        {
          method: "PATCH",
          body: {
            aliases,
            expectedRevision: Number(actionElement.dataset.revision || 0),
          },
        },
      );
      renderNotice("目录别名已保存");
      await renderContentOps();
    } else if (action === "edit-placement") {
      state.contentOps.editPlacement = parseJsonDataset(actionElement, "item");
      await renderContentOps();
      document.querySelector("#placementEditor")?.scrollIntoView({ behavior: "smooth" });
    } else if (action === "cancel-placement-edit") {
      state.contentOps.editPlacement = null;
      await renderContentOps();
    } else if (action === "save-placement") {
      const current = state.contentOps.editPlacement;
      const body = collectPlacementPayload();
      if (current) {
        body.expectedRevision = current.revision;
        await api(`/admin/content/placements/${current.id}`, {
          method: "PATCH",
          body,
        });
      } else {
        await api("/admin/content/placements", { method: "POST", body });
      }
      state.contentOps.editPlacement = null;
      renderNotice(current ? "推荐位已更新" : "推荐位已创建");
      await renderContentOps();
    } else if (action === "delete-placement") {
      if (!confirm("确认删除这个推荐位？")) return;
      await api(`/admin/content/placements/${actionElement.dataset.id}`, {
        method: "DELETE",
      });
      if (state.contentOps.editPlacement?.id === Number(actionElement.dataset.id)) {
        state.contentOps.editPlacement = null;
      }
      await renderContentOps();
    } else if (action === "preview-content-ops") {
      const versionCode = Number(valueOf("#contentPreviewVersion") || 0);
      const platform = valueOf("#contentPreviewPlatform") || "android";
      state.contentOps.preview = await api(
        `/admin/content/placements/preview${makeQuery({
          versionCode,
          platform,
          installId: "admin-preview",
        })}`,
      );
      await renderContentOps();
    } else if (action === "record-source-health") {
      const success = valueOf("#sourceHealthSuccess") === "true";
      await api("/admin/content/source-health/record", {
        method: "POST",
        body: {
          contentType: valueOf("#sourceHealthType"),
          sourceKey: valueOf("#sourceHealthKey"),
          success,
          latencyMs: Number(valueOf("#sourceHealthLatency") || 0),
          error: success ? "" : valueOf("#sourceHealthError"),
          idempotencyKey: operationId("source-probe"),
        },
      });
      renderNotice("来源探测结果已记录");
      await renderContentOps();
    } else if (action === "create-cache-invalidation") {
      const scope = valueOf("#cacheInvalidationScope");
      await api("/admin/content/cache-invalidations", {
        method: "POST",
        body: {
          scope,
          key: scope === "all" ? "" : valueOf("#cacheInvalidationKey"),
          reason: valueOf("#cacheInvalidationReason"),
          idempotencyKey: operationId("cache"),
        },
      });
      renderNotice("缓存失效指令已创建");
      await renderContentOps();
    } else if (action === "edit-feature-flag") {
      state.contentOps.editFlag = parseJsonDataset(actionElement, "item");
      await renderContentOps();
      document.querySelector("#featureFlagEditor")?.scrollIntoView({ behavior: "smooth" });
    } else if (action === "cancel-feature-edit") {
      state.contentOps.editFlag = null;
      await renderContentOps();
    } else if (action === "save-feature-flag") {
      const current = state.contentOps.editFlag;
      const body = collectFeatureFlagPayload();
      if (current) {
        body.expectedRevision = current.revision;
        await api(`/admin/content/feature-flags/${encodeURIComponent(current.key)}`, {
          method: "PATCH",
          body,
        });
      } else {
        body.key = valueOf("#featureFlagKey");
        await api("/admin/content/feature-flags", { method: "POST", body });
      }
      state.contentOps.editFlag = null;
      renderNotice(current ? "功能开关已更新" : "功能开关已创建");
      await renderContentOps();
    } else if (action === "rollback-feature-flag") {
      const item = parseJsonDataset(actionElement, "item");
      const target = Number(prompt(`回滚 ${item.key} 到哪个修订号？`, "1") || 0);
      if (!target) return;
      await api(
        `/admin/content/feature-flags/${encodeURIComponent(item.key)}/rollback`,
        {
          method: "POST",
          body: {
            expectedRevision: item.revision,
            targetRevision: target,
            idempotencyKey: operationId("flag-rollback"),
          },
        },
      );
      renderNotice(`已将 ${item.key} 回滚到修订 ${target}`);
      await renderContentOps();
    } else if (action === "delete-feature-flag") {
      const key = actionElement.dataset.key;
      if (!confirm(`确认删除功能开关 ${key}？`)) return;
      await api(`/admin/content/feature-flags/${encodeURIComponent(key)}`, {
        method: "DELETE",
      });
      if (state.contentOps.editFlag?.key === key) state.contentOps.editFlag = null;
      await renderContentOps();
    }
}
