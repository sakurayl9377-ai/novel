<script setup lang="ts">
import { Refresh, Search, UserFilled } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { reactive, ref, watch } from 'vue';

import {
  listChatRoomMembers,
  removeChatRoomMember,
  updateChatRoomMemberRole,
} from '@/services/chat';
import type { ChatMemberRole, ChatRoom, ChatRoomMember } from '@/types/chat';
import { formatDateTime } from '@/utils/format';

const props = defineProps<{
  modelValue: boolean;
  room: ChatRoom | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  changed: [];
}>();

const loading = ref(false);
const updatingUserId = ref<number | null>(null);
const items = ref<ChatRoomMember[]>([]);
const total = ref(0);
const query = reactive({ q: '', role: '' as '' | ChatMemberRole, page: 1, pageSize: 20 });

watch(
  () => [props.modelValue, props.room?.roomId] as const,
  ([open]) => {
    if (!open || !props.room) return;
    Object.assign(query, { q: '', role: '', page: 1, pageSize: 20 });
    void loadMembers();
  },
);

async function loadMembers(): Promise<void> {
  if (!props.room) return;
  loading.value = true;
  try {
    const data = await listChatRoomMembers(props.room.roomId, query);
    items.value = data.items;
    total.value = data.total;
  } catch (error) {
    ElMessage.error(errorMessage(error, '成员列表加载失败'));
  } finally {
    loading.value = false;
  }
}

function search(): void {
  query.page = 1;
  void loadMembers();
}

async function changeRole(item: ChatRoomMember, role: ChatMemberRole): Promise<void> {
  if (!props.room || updatingUserId.value) return;
  updatingUserId.value = item.userId;
  try {
    await updateChatRoomMemberRole(props.room.roomId, item.userId, role);
    ElMessage.success(role === 'manager' ? '已设为房间管理员' : '已调整为普通成员');
    await loadMembers();
  } catch (error) {
    ElMessage.error(errorMessage(error, '成员角色更新失败'));
  } finally {
    updatingUserId.value = null;
  }
}

async function removeMember(item: ChatRoomMember): Promise<void> {
  if (!props.room || updatingUserId.value) return;
  updatingUserId.value = item.userId;
  try {
    await removeChatRoomMember(props.room.roomId, item.userId);
    ElMessage.success('成员已移出房间，在线连接也已断开');
    if (items.value.length === 1 && query.page > 1) query.page -= 1;
    await loadMembers();
    emit('changed');
  } catch (error) {
    ElMessage.error(errorMessage(error, '移出成员失败'));
  } finally {
    updatingUserId.value = null;
  }
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(680px, 96vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="members-heading">
        <span class="heading-icon"><ElIcon><UserFilled /></ElIcon></span>
        <div>
          <h2>房间成员</h2>
          <p>{{ room?.name }} · 共 {{ total }} 人</p>
        </div>
      </div>
    </template>

    <div class="member-filters">
      <ElInput v-model="query.q" clearable placeholder="搜索昵称或邮箱" @keyup.enter="search">
        <template #prefix><ElIcon><Search /></ElIcon></template>
      </ElInput>
      <ElSelect v-model="query.role" clearable placeholder="全部角色" @change="search">
        <ElOption label="普通成员" value="member" />
        <ElOption label="房间管理员" value="manager" />
      </ElSelect>
      <ElButton :icon="Refresh" :loading="loading" @click="loadMembers">刷新</ElButton>
    </div>

    <div v-loading="loading" class="member-list">
      <article v-for="item in items" :key="item.userId" class="member-card">
        <ElAvatar :src="item.user.avatarUrl" :size="46">
          {{ item.user.nickname?.slice(0, 1) || item.userId }}
        </ElAvatar>
        <div class="member-main">
          <div class="member-name">
            <strong>{{ item.user.nickname || `用户 #${item.userId}` }}</strong>
            <ElTag v-if="item.isSystem" type="primary" size="small">系统成员</ElTag>
            <ElTag v-else-if="item.role === 'manager'" type="warning" size="small">房间管理员</ElTag>
          </div>
          <span>{{ item.user.email }} · UID {{ item.userId }}</span>
          <small>加入 {{ formatDateTime(item.joinedAt) }} · 最近活跃 {{ formatDateTime(item.lastSeenAt) }}</small>
        </div>
        <div v-if="!item.isSystem" class="member-actions">
          <ElSelect
            :model-value="item.role"
            size="small"
            :disabled="updatingUserId === item.userId"
            @change="changeRole(item, $event as ChatMemberRole)"
          >
            <ElOption label="普通成员" value="member" />
            <ElOption label="房间管理员" value="manager" />
          </ElSelect>
          <ElPopconfirm
            width="260"
            :title="`确定将 ${item.user.nickname || `用户 #${item.userId}`} 移出房间？`"
            confirm-button-text="确认移出"
            cancel-button-text="取消"
            @confirm="removeMember(item)"
          >
            <template #reference><ElButton text type="danger" size="small">移出</ElButton></template>
          </ElPopconfirm>
        </div>
        <ElTag v-else effect="plain" type="info">跟随机器人开关管理</ElTag>
      </article>

      <ElEmpty v-if="!loading && !items.length" description="没有符合条件的成员" />
    </div>

    <ElPagination
      v-if="total > query.pageSize"
      v-model:current-page="query.page"
      class="member-pagination"
      background
      layout="prev, pager, next"
      :page-size="query.pageSize"
      :total="total"
      @current-change="loadMembers"
    />
  </ElDrawer>
</template>

<style scoped>
.members-heading { display: flex; align-items: center; gap: 12px; }
.heading-icon { display: grid; width: 44px; height: 44px; place-items: center; border-radius: 14px; color: #c95b82; background: #ffe7ef; }
.heading-icon :deep(.el-icon) { font-size: 21px; }
.members-heading h2 { margin: 0; color: #41343a; font-size: 20px; }
.members-heading p { margin: 3px 0 0; color: #96828a; font-size: 12px; }
.member-filters { display: grid; grid-template-columns: minmax(180px, 1fr) 160px auto; gap: 10px; margin-bottom: 16px; }
.member-list { display: grid; min-height: 180px; gap: 9px; }
.member-card { display: flex; align-items: center; gap: 12px; padding: 13px; border: 1px solid #eee3e7; border-radius: 15px; background: #fff; }
.member-main { display: flex; flex: 1; flex-direction: column; gap: 3px; min-width: 0; }
.member-name { display: flex; align-items: center; gap: 7px; }
.member-name strong { overflow: hidden; color: #47383e; text-overflow: ellipsis; white-space: nowrap; }
.member-main > span { overflow: hidden; color: #8f7a82; font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }
.member-main small { color: #aa979e; }
.member-actions { display: flex; align-items: center; gap: 6px; }
.member-actions :deep(.el-select) { width: 128px; }
.member-pagination { justify-content: center; margin-top: 18px; }

@media (max-width: 620px) {
  .member-filters { grid-template-columns: 1fr 1fr; }
  .member-filters .el-input { grid-column: 1 / -1; }
  .member-card { align-items: flex-start; flex-wrap: wrap; }
  .member-main { min-width: calc(100% - 60px); }
  .member-actions { width: 100%; justify-content: flex-end; }
}
</style>
