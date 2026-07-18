import { fileURLToPath, URL } from 'node:url';

import vue from '@vitejs/plugin-vue';
import Components from 'unplugin-vue-components/vite';
import { ElementPlusResolver } from 'unplugin-vue-components/resolvers';
import { defineConfig } from 'vite';

const root = fileURLToPath(new URL('.', import.meta.url));

export default defineConfig({
  root,
  base: './',
  plugins: [
    vue(),
    Components({
      dts: fileURLToPath(new URL('./src/components.d.ts', import.meta.url)),
      resolvers: [ElementPlusResolver({ importStyle: 'css' })],
    }),
  ],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    host: '127.0.0.1',
    port: 5174,
    proxy: {
      '/api': 'http://127.0.0.1:3010',
      '/admin/v2/config.json': 'http://127.0.0.1:3010',
    },
  },
  build: {
    outDir: fileURLToPath(new URL('../admin-dist', import.meta.url)),
    emptyOutDir: true,
    sourcemap: false,
  },
});
