<script setup lang="ts">
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import { Clock, RefreshRight } from '@element-plus/icons-vue';

import { legacyAdminUrl } from '@/config/runtime';

const route = useRoute();
const title = computed(() => String(route.meta.title || '模块'));
const hint = computed(() => String(route.meta.hint || ''));

function openLegacy(): void {
  window.location.assign(legacyAdminUrl());
}
</script>

<template>
  <section class="migration-hero">
    <div class="migration-icon"><ElIcon><Clock /></ElIcon></div>
    <div>
      <span class="eyebrow">MIGRATION IN PROGRESS</span>
      <h2>{{ title }}正在按新交互规范重构</h2>
      <p>{{ hint }}。在该模块完成端到端验收前，旧版入口继续可用。</p>
    </div>
    <ElButton type="primary" :icon="RefreshRight" @click="openLegacy">打开旧版后台</ElButton>
  </section>
</template>
