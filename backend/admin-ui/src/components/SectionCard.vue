<script setup lang="ts">
defineProps<{
  title: string;
  hint?: string;
}>();
</script>

<template>
  <section class="section-card">
    <header class="section-card-header">
      <div><h2>{{ title }}</h2><p v-if="hint">{{ hint }}</p></div>
      <slot name="actions" />
    </header>
    <div class="section-card-body"><slot /></div>
  </section>
</template>
