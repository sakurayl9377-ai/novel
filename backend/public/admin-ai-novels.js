// AI novel creator submission, serialization and administrator review.

async function renderAiNovels() {
  const isAdmin = state.user?.role === "admin";
  const requests = [api("/creator/ai-novels")];
  if (isAdmin) {
    requests.push(api("/admin/ai-novels?status=pending"));
    requests.push(api("/admin/ai-novel-chapters?status=pending"));
  }
  const [own, reviewNovels = { items: [] }, reviewChapters = { items: [] }] =
    await Promise.all(requests);
  const publishedWorks = (own.items || []).filter(
    (item) => item.status === "published",
  );

  viewRoot.innerHTML = `
    <div class="ai-novel-layout">
      <div class="ai-novel-list">
        <section class="section-block">
          <h3>${isAdmin ? "上架 AI 小说" : "上传小说投稿"}</h3>
          <p class="mini-meta">${isAdmin ? "管理员提交后直接发布。" : "提交后由管理员审核，通过后自动发布到 App AI 创作区。"}</p>
          <div class="ai-novel-form">
            <div class="two-column">
              <label>书名<input id="aiNovelTitle" maxlength="100" placeholder="请输入小说名称" /></label>
              <label>作者笔名<input id="aiNovelPenName" maxlength="50" value="${escapeAttr(state.user?.nickname || "")}" /></label>
            </div>
            <div class="two-column">
              <label>分类<input id="aiNovelCategory" maxlength="40" value="AI原创" /></label>
              <label>封面 URL（可选）<input id="aiNovelCoverUrl" maxlength="1000" placeholder="https://..." /></label>
            </div>
            <label>作品简介<textarea id="aiNovelDescription" maxlength="2000" placeholder="介绍作品题材、世界观和主要剧情"></textarea></label>
            <label>导入 TXT 文件<input id="aiNovelFile" type="file" accept=".txt,text/plain" /></label>
            <label>小说正文<textarea id="aiNovelContent" name="content" placeholder="可粘贴正文或选择 TXT。系统按“第X章 / 第X回 / Chapter X”自动拆章。"></textarea></label>
            <button class="button primary" data-action="submit-ai-novel">${isAdmin ? "直接上架" : "提交审核"}</button>
          </div>
        </section>

        <section class="section-block">
          <h3>上传连载章节</h3>
          <p class="mini-meta">可上传单章或包含多个章节的 TXT；普通作者上传后需要管理员审核。</p>
          <div class="ai-novel-form">
            <label>选择已发布作品
              <select id="aiNovelSerialTarget">
                <option value="">请选择小说</option>
                ${publishedWorks.map((item) => `<option value="${item.numericId}">${escapeHtml(item.title)}</option>`).join("")}
              </select>
            </label>
            <label>导入连载 TXT<input id="aiNovelSerialFile" type="file" accept=".txt,text/plain" /></label>
            <label>章节正文<textarea id="aiNovelSerialContent" name="content" placeholder="粘贴单章或多章正文"></textarea></label>
            <button class="button primary" data-action="submit-ai-novel-chapters" ${publishedWorks.length ? "" : "disabled"}>${isAdmin ? "直接发布章节" : "提交章节审核"}</button>
          </div>
        </section>
      </div>

      <div class="ai-novel-list">
        ${isAdmin ? `
          <section class="section-block">
            <h3>整本投稿审核</h3>
            <div class="ai-novel-list">
              ${(reviewNovels.items || []).map((item) => aiNovelCard(item, true)).join("") || empty("暂无待审核小说")}
            </div>
          </section>
          <section class="section-block">
            <h3>连载章节审核</h3>
            <div class="ai-novel-list">
              ${(reviewChapters.items || []).map(aiNovelChapterCard).join("") || empty("暂无待审核章节")}
            </div>
          </section>` : ""}
        <section class="section-block">
          <h3>${isAdmin ? "我的上架作品" : "我的投稿与连载"}</h3>
          <div class="ai-novel-list">
            ${(own.items || []).map((item) => aiNovelCard(item, false)).join("") || empty("还没有提交作品")}
          </div>
        </section>
      </div>
    </div>`;
}

function aiNovelCard(item, reviewMode) {
  const statusLabel = {
    pending: "待审核",
    published: "已发布",
    rejected: "需修改",
  }[item.status] || item.status;
  return `
    <article class="ai-novel-card">
      <header>
        <div>
          <strong>${escapeHtml(item.title)}</strong>
          <div class="mini-meta">${escapeHtml(item.author || item.ownerNickname || "")}${reviewMode ? ` · ${escapeHtml(item.ownerEmail || "")}` : ""} · ${item.publishedChapterCount || 0}/${item.chapterCount || 0} 章已发布</div>
        </div>
        <span class="ai-novel-status ${escapeAttr(item.status)}">${escapeHtml(statusLabel)}</span>
      </header>
      <p>${escapeHtml(item.description || "")}</p>
      ${item.pendingChapterCount ? `<p>另有 ${item.pendingChapterCount} 章等待审核。</p>` : ""}
      ${item.reviewNote ? `<p><strong>审核意见：</strong>${escapeHtml(item.reviewNote)}</p>` : ""}
      ${reviewMode ? `
        <div class="ai-novel-actions">
          <button class="button primary small" data-action="approve-ai-novel" data-id="${item.numericId}">审核通过并发布</button>
          <button class="button danger small" data-action="reject-ai-novel" data-id="${item.numericId}">拒绝并填写原因</button>
        </div>` : ""}
    </article>`;
}

function aiNovelChapterCard(item) {
  return `
    <article class="ai-novel-card">
      <header>
        <div>
          <strong>${escapeHtml(item.novelTitle)} · ${escapeHtml(item.title)}</strong>
          <div class="mini-meta">${escapeHtml(item.ownerNickname || item.ownerEmail || "")}</div>
        </div>
        <span class="ai-novel-status pending">待审核</span>
      </header>
      <div class="ai-novel-actions">
        <button class="button primary small" data-action="approve-ai-novel-chapter" data-id="${item.id}">通过并追加目录</button>
        <button class="button danger small" data-action="reject-ai-novel-chapter" data-id="${item.id}">拒绝</button>
      </div>
    </article>`;
}

async function handleAiNovelAction(action, element) {
  if (action === "submit-ai-novel") {
    const content = await aiNovelInputText("#aiNovelFile", "#aiNovelContent");
    await api("/creator/ai-novels", {
      method: "POST",
      body: {
        title: valueOf("#aiNovelTitle"),
        penName: valueOf("#aiNovelPenName"),
        category: valueOf("#aiNovelCategory"),
        coverUrl: valueOf("#aiNovelCoverUrl"),
        description: valueOf("#aiNovelDescription"),
        content,
      },
    });
    renderNotice(state.user?.role === "admin" ? "小说已上架" : "投稿已提交审核");
    await renderAiNovels();
    return;
  }
  if (action === "submit-ai-novel-chapters") {
    const novelId = valueOf("#aiNovelSerialTarget");
    if (!novelId) throw new Error("请选择要更新的小说");
    const content = await aiNovelInputText(
      "#aiNovelSerialFile",
      "#aiNovelSerialContent",
    );
    await api(`/creator/ai-novels/${encodeURIComponent(novelId)}/chapters`, {
      method: "POST",
      body: { content },
    });
    renderNotice(
      state.user?.role === "admin" ? "连载章节已发布" : "连载章节已提交审核",
    );
    await renderAiNovels();
    return;
  }
  if (action === "approve-ai-novel" || action === "reject-ai-novel") {
    const approve = action === "approve-ai-novel";
    const reviewNote = approve ? "" : prompt("请输入拒绝原因和修改建议")?.trim() || "";
    if (!approve && !reviewNote) return;
    await api(`/admin/ai-novels/${encodeURIComponent(element.dataset.id)}/review`, {
      method: "POST",
      body: { decision: approve ? "approve" : "reject", reviewNote },
    });
    renderNotice(approve ? "审核通过，作品已发布" : "已退回作者修改");
    await renderAiNovels();
    return;
  }
  if (
    action === "approve-ai-novel-chapter" ||
    action === "reject-ai-novel-chapter"
  ) {
    const approve = action === "approve-ai-novel-chapter";
    const reviewNote = approve ? "" : prompt("请输入章节拒绝原因")?.trim() || "";
    if (!approve && !reviewNote) return;
    await api(
      `/admin/ai-novel-chapters/${encodeURIComponent(element.dataset.id)}/review`,
      {
        method: "POST",
        body: { decision: approve ? "approve" : "reject", reviewNote },
      },
    );
    renderNotice(approve ? "章节已追加发布" : "章节已退回修改");
    await renderAiNovels();
  }
}

async function aiNovelInputText(fileSelector, textSelector) {
  const file = document.querySelector(fileSelector)?.files?.[0];
  const content = file ? await file.text() : valueOf(textSelector);
  if (!content.trim()) throw new Error("请选择 TXT 文件或粘贴正文");
  return content;
}
