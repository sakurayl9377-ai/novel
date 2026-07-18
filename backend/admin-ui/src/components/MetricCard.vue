<script setup lang="ts">
import type { Component } from 'vue';

withDefaults(defineProps<{
  label: string;
  value: string | number;
  hint?: string;
  tone?: 'default' | 'success' | 'warning' | 'danger';
  icon?: Component;
}>(), {
  hint: '',
  tone: 'default',
  icon: undefined,
});
</script>

<template>
  <article class="metric-card" :class="`tone-${tone}`">
    <div class="metric-topline">
      <span>{{ label }}</span>
      <span v-if="icon" class="metric-icon"><ElIcon><component :is="icon" /></ElIcon></span>
    </div>
    <strong>{{ value }}</strong>
    <small v-if="hint">{{ hint }}</small>
  </article>
</template>
