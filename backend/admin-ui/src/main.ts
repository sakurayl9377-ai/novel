import { createApp } from 'vue';

import App from './App.vue';
import { loadRuntimeConfig } from './config/runtime';
import { pinia } from './stores';
import { useSessionStore } from './stores/session';
import { router } from './router';
import './styles/tokens.css';
import './styles/app.css';

const app = createApp(App);
await loadRuntimeConfig();
app.use(pinia);
app.use(router);

const session = useSessionStore(pinia);
router.beforeEach(async (to) => {
  if (!session.ready) await session.restore();

  if (to.name === 'login') {
    if (!session.user) return true;
    return { name: session.defaultRouteName };
  }
  if (to.meta.requiresAuth && !session.user) {
    return { name: 'login', query: { redirect: to.fullPath } };
  }
  if (to.meta.requiresAdmin && !session.isAdmin) {
    return { name: 'ai-novels' };
  }
  return true;
});

window.addEventListener('novel-admin:unauthorized', () => {
  session.clearSession();
  void router.replace({ name: 'login' });
});

app.mount('#app');
