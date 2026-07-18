<script setup lang="ts">
import { reactive } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { Lock, Message, Reading } from '@element-plus/icons-vue';

import { useSessionStore } from '@/stores/session';

const route = useRoute();
const router = useRouter();
const session = useSessionStore();
const form = reactive({ email: '', password: '' });

async function submit(): Promise<void> {
  if (!form.email.trim() || !form.password) return;
  try {
    await session.login(form.email.trim(), form.password);
    const redirect = typeof route.query.redirect === 'string' && route.query.redirect.startsWith('/')
      ? route.query.redirect
      : null;
    await router.replace(redirect || { name: session.defaultRouteName });
  } catch {
    // The store exposes a localized error next to the form.
  }
}
</script>

<template>
  <main class="login-page">
    <section class="login-story">
      <div class="story-glow story-glow-one" />
      <div class="story-glow story-glow-two" />
      <div class="story-content">
        <span class="story-kicker"><ElIcon><Reading /></ElIcon> NOVEL OPERATIONS</span>
        <h1>让每一次运营操作<br />都清楚、可靠、可追踪</h1>
        <p>统一管理内容、创作者、社区、用户与增长业务。</p>
        <div class="story-points">
          <span>任务化工作台</span>
          <span>完整审核上下文</span>
          <span>敏感操作留痕</span>
        </div>
      </div>
    </section>

    <section class="login-form-pane">
      <form class="login-card" @submit.prevent="submit">
        <div class="login-brand">
          <div class="brand-mark">N</div>
          <div><strong>Novel 运营后台</strong><span>Admin Workbench V2</span></div>
        </div>
        <div class="login-heading">
          <h2>欢迎回来</h2>
          <p>管理员进入运营工作台，普通账号进入创作者中心。</p>
        </div>
        <ElAlert v-if="session.error" :title="session.error" type="error" :closable="false" show-icon />
        <label class="field-label" for="login-email">邮箱</label>
        <ElInput
          id="login-email"
          v-model="form.email"
          size="large"
          autocomplete="username"
          placeholder="请输入登录邮箱"
          :prefix-icon="Message"
        />
        <label class="field-label" for="login-password">密码</label>
        <ElInput
          id="login-password"
          v-model="form.password"
          size="large"
          type="password"
          autocomplete="current-password"
          placeholder="请输入密码"
          show-password
          :prefix-icon="Lock"
          @keyup.enter="submit"
        />
        <ElButton
          class="login-submit"
          type="primary"
          size="large"
          native-type="submit"
          :loading="session.authenticating"
          :disabled="!form.email.trim() || !form.password"
        >
          登录工作台
        </ElButton>
        <p class="login-security">登录信息仅用于当前后台会话，请勿在公共设备保存账号。</p>
      </form>
    </section>
  </main>
</template>
