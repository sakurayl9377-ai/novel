<script setup lang="ts">
import { useRouter } from 'vue-router';

const router = useRouter();
</script>

<template>
  <main class="standalone-state">
    <strong>404</strong>
    <h1>没有找到这个后台页面</h1>
    <ElButton type="primary" @click="router.replace('/')">返回工作台</ElButton>
  </main>
</template>
