<script setup lang="ts">
import { UploadFilled } from '@element-plus/icons-vue';

import { legacyAdminUrl } from '@/config/runtime';

function openLegacy(): void {
  window.location.assign(legacyAdminUrl());
}
</script>

<template>
  <div class="page-stack">
    <section class="migration-hero ai-migration-hero">
      <div class="migration-icon"><ElIcon><UploadFilled /></ElIcon></div>
      <div>
        <span class="eyebrow">NEXT MODULE</span>
        <h2>AI 小说创作与审核正在迁入 V2</h2>
        <p>下一阶段将提供封面上传、作品草稿、拆章预览、正文审核和退回重投完整流程。</p>
      </div>
      <ElButton type="primary" @click="openLegacy">暂时使用旧版入口</ElButton>
    </section>
  </div>
</template>
