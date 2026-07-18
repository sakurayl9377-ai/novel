<script setup lang="ts">
import { computed, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { ArrowLeft, ArrowRight, Expand, Fold, MoreFilled, Refresh, SwitchButton } from '@element-plus/icons-vue';

import { legacyAdminUrl } from '@/config/runtime';
import { visibleNavigation } from '@/navigation';
import { useSessionStore } from '@/stores/session';

const route = useRoute();
const router = useRouter();
const session = useSessionStore();
const collapsedKey = 'novelAdminV2SidebarCollapsed';
const collapsed = ref(localStorage.getItem(collapsedKey) === 'true');
const mobileOpen = ref(false);

const groups = computed(() => visibleNavigation(session.user?.role));
const activeRoute = computed(() => String(route.name || ''));
const title = computed(() => String(route.meta.title || '运营后台'));
const hint = computed(() => String(route.meta.hint || ''));

function toggleCollapsed(): void {
  collapsed.value = !collapsed.value;
  localStorage.setItem(collapsedKey, String(collapsed.value));
}

function navigate(name: string): void {
  mobileOpen.value = false;
  void router.push({ name });
}

async function handleUserCommand(command: string): Promise<void> {
  if (command === 'legacy') {
    window.location.assign(legacyAdminUrl());
    return;
  }
  if (command === 'logout') {
    await session.logout();
    await router.replace({ name: 'login' });
  }
}
</script>

<template>
  <div class="admin-shell" :class="{ 'is-collapsed': collapsed, 'mobile-open': mobileOpen }">
    <aside class="admin-sidebar">
      <div class="brand-row">
        <div class="brand-mark">N</div>
        <div v-if="!collapsed" class="brand-copy">
          <strong>Novel</strong>
          <span>运营后台 V2</span>
        </div>
        <ElButton
          class="collapse-button"
          circle
          text
          :icon="collapsed ? ArrowRight : ArrowLeft"
          :aria-label="collapsed ? '展开导航' : '收起导航'"
          @click="toggleCollapsed"
        />
      </div>

      <ElScrollbar class="navigation-scroll">
        <ElMenu
          :default-active="activeRoute"
          :collapse="collapsed"
          :collapse-transition="false"
          class="navigation-menu"
        >
          <ElSubMenu v-for="group in groups" :key="group.key" :index="group.key">
            <template #title>
              <ElIcon><MoreFilled /></ElIcon>
              <span>{{ group.label }}</span>
            </template>
            <ElMenuItem
              v-for="item in group.items"
              :key="`${group.key}-${item.route}-${item.label}`"
              :index="item.route"
              @click="navigate(item.route)"
            >
              <ElIcon><component :is="item.icon" /></ElIcon>
              <template #title>
                <span>{{ item.label }}</span>
                <span v-if="item.legacy" class="legacy-dot">迁移中</span>
              </template>
            </ElMenuItem>
          </ElSubMenu>
        </ElMenu>
      </ElScrollbar>

      <button class="legacy-link" type="button" @click="handleUserCommand('legacy')">
        <ElIcon><Refresh /></ElIcon>
        <span v-if="!collapsed">返回旧版后台</span>
      </button>
    </aside>

    <button class="mobile-backdrop" type="button" aria-label="关闭导航" @click="mobileOpen = false" />

    <main class="admin-main">
      <header class="admin-topbar">
        <div class="topbar-title">
          <ElButton class="mobile-menu-button" text :icon="mobileOpen ? Fold : Expand" @click="mobileOpen = !mobileOpen" />
          <div>
            <h1>{{ title }}</h1>
            <p v-if="hint">{{ hint }}</p>
          </div>
        </div>
        <ElDropdown trigger="click" @command="handleUserCommand">
          <button class="session-button" type="button">
            <span class="session-avatar">{{ session.user?.nickname?.slice(0, 1) || '管' }}</span>
            <span class="session-copy">
              <strong>{{ session.user?.nickname }}</strong>
              <small>{{ session.user?.role === 'admin' ? '管理员' : '创作者' }}</small>
            </span>
            <ElIcon><MoreFilled /></ElIcon>
          </button>
          <template #dropdown>
            <ElDropdownMenu>
              <ElDropdownItem command="legacy">打开旧版后台</ElDropdownItem>
              <ElDropdownItem command="logout" divided>
                <ElIcon><SwitchButton /></ElIcon>退出登录
              </ElDropdownItem>
            </ElDropdownMenu>
          </template>
        </ElDropdown>
      </header>

      <section class="admin-content">
        <RouterView v-slot="{ Component }">
          <Transition name="page" mode="out-in">
            <component :is="Component" />
          </Transition>
        </RouterView>
      </section>
    </main>
  </div>
</template>
