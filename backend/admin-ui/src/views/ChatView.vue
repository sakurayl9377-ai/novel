<script setup lang="ts">
import {
  ChatDotRound,
  CircleCheck,
  Delete,
  EditPen,
  Flag,
  Lock,
  MoreFilled,
  Plus,
  Refresh,
  RefreshLeft,
  Search,
  Setting,
  UserFilled,
  View,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue';

import ChatKeywordDrawer from '@/components/chat/ChatKeywordDrawer.vue';
import ChatMembersDrawer from '@/components/chat/ChatMembersDrawer.vue';
import ChatMessageDrawer from '@/components/chat/ChatMessageDrawer.vue';
import ChatRoomEditorDrawer from '@/components/chat/ChatRoomEditorDrawer.vue';
import ReportDetailDrawer from '@/components/moderation/ReportDetailDrawer.vue';
import {
  blockIp,
  clearChatRoom,
  createChatKeyword,
  createChatRoom,
  deleteChatKeyword,
  dissolveChatRoom,
  listBlockedIps,
  listChatKeywords,
  listChatRoomMessages,
  listChatRooms,
  listChatViolations,
  testChatKeyword,
  unblockIp,
  updateChatKeyword,
  updateChatMessageStatus,
  updateChatMessagesStatus,
  updateChatRoom,
  uploadChatRoomAvatar,
} from '@/services/chat';
import {
  resolveReportAndDeleteTarget,
  updateReportStatus,
} from '@/services/moderation';
import type {
  BlockedIp,
  ChatKeywordPayload,
  ChatKeywordRule,
  ChatMessage,
  ChatMessageStatus,
  ChatRoom,
  ChatRoomCategory,
  ChatRoomPayload,
  ChatViolation,
  ChatViolationAction,
  ChatWorkbenchStats,
} from '@/types/chat';
import type { ReportItem, ReportStatus } from '@/types/moderation';
import {
  chatBlockReasonLabel,
  chatKeywordMatchLabel,
  chatMessageStatusLabel,
  chatMessageSummary,
  chatMessageTypeLabel,
  chatRoomStatusLabel,
  chatViolationActionLabel,
} from '@/utils/chat';
import { formatDateTime } from '@/utils/format';

type ChatTab = 'rooms' | 'keywords' | 'violations' | 'ips';

const activeTab = ref<ChatTab>('rooms');
const roomsLoading = ref(false);
const messagesLoading = ref(false);
const rooms = ref<ChatRoom[]>([]);
const roomOptions = ref<ChatRoom[]>([]);
const roomTotal = ref(0);
const roomStatusCounts = ref<Record<string, number>>({});
const categories = ref<{ key: ChatRoomCategory; label: string; count: number; hot: boolean }[]>([]);
const stats = ref<ChatWorkbenchStats>({
  activeRooms: 0,
  hiddenRooms: 0,
  visibleMessages: 0,
  messages24h: 0,
  violationsToday: 0,
  activeKeywords: 0,
  blockedIps: 0,
});
const selectedRoomId = ref('');
const selectedRoomDetail = ref<ChatRoom | null>(null);
const messages = ref<ChatMessage[]>([]);
const messageTotal = ref(0);
const messageStatusCounts = ref<Record<string, number>>({});
const selectedMessageIds = ref<number[]>([]);
const autoRefresh = ref(false);
let refreshTimer: number | null = null;

const roomQuery = reactive({
  q: '',
  status: 'active' as 'all' | 'active' | 'hidden' | 'deleted',
  category: '' as '' | ChatRoomCategory,
  page: 1,
  pageSize: 12,
});
const messageQuery = reactive({
  q: '',
  status: 'visible' as ChatMessageStatus,
  type: '' as '' | ChatMessage['type'],
  page: 1,
  pageSize: 20,
});

const roomEditorOpen = ref(false);
const roomSaving = ref(false);
const editingRoom = ref<ChatRoom | null>(null);
const membersOpen = ref(false);
const messageDrawerOpen = ref(false);
const selectedMessageId = ref<number | null>(null);

const keywordsLoading = ref(false);
const keywords = ref<ChatKeywordRule[]>([]);
const keywordTotal = ref(0);
const keywordStatusCounts = ref<Record<string, number>>({});
const keywordQuery = reactive({
  q: '',
  status: '' as '' | 'active' | 'inactive',
  page: 1,
  pageSize: 12,
});
const keywordEditorOpen = ref(false);
const keywordSaving = ref(false);
const editingKeyword = ref<ChatKeywordRule | null>(null);
const keywordTestContent = ref('');
const keywordTesting = ref(false);
const keywordTestResult = ref<{ matched: boolean; item: ChatKeywordRule | null } | null>(null);

const violationsLoading = ref(false);
const violations = ref<ChatViolation[]>([]);
const violationTotal = ref(0);
const violationActionCounts = ref<Record<string, number>>({});
const violationQuery = reactive({
  q: '',
  roomId: '',
  action: '' as '' | ChatViolationAction,
  page: 1,
  pageSize: 20,
});

const ipsLoading = ref(false);
const blockedIps = ref<BlockedIp[]>([]);
const blockedIpTotal = ref(0);
const ipQuery = reactive({ q: '', page: 1, pageSize: 20 });
const ipDialogOpen = ref(false);
const ipSaving = ref(false);
const ipForm = reactive({ ip: '', reason: 'admin_block', note: '' });

const reportOpen = ref(false);
const selectedReport = ref<ReportItem | null>(null);
const reportProcessing = ref(false);

const selectedRoom = computed(() => selectedRoomDetail.value
  || rooms.value.find((item) => item.roomId === selectedRoomId.value)
  || null);
const batchTargetStatus = computed<ChatMessageStatus>(() => (
  messageQuery.status === 'visible' ? 'deleted' : 'visible'
));
const roomAllCount = computed(() => Object.values(roomStatusCounts.value)
  .reduce((sum, value) => sum + Number(value || 0), 0));

onMounted(() => void loadRooms());
onBeforeUnmount(stopAutoRefresh);

watch(activeTab, (tab) => {
  if (tab === 'keywords') void loadKeywords();
  if (tab === 'violations') void Promise.all([loadViolations(), loadRoomOptions()]);
  if (tab === 'ips') void loadBlockedIps();
});

watch(autoRefresh, (enabled) => {
  stopAutoRefresh();
  if (!enabled) return;
  refreshTimer = window.setInterval(() => {
    if (activeTab.value === 'rooms' && selectedRoomId.value && !messagesLoading.value) {
      void loadMessages();
    }
  }, 15_000);
});

async function loadRooms(reloadMessages = true): Promise<void> {
  roomsLoading.value = true;
  try {
    const data = await listChatRooms(roomQuery);
    rooms.value = data.items;
    roomTotal.value = data.total;
    roomStatusCounts.value = data.statusCounts as Record<string, number>;
    categories.value = data.categories;
    stats.value = data.stats;
    const selectedStillVisible = data.items.some((item) => item.roomId === selectedRoomId.value);
    if (!selectedStillVisible) {
      const firstRoom = data.items[0] || null;
      selectedRoomId.value = firstRoom?.roomId || '';
      selectedRoomDetail.value = null;
      messageQuery.page = 1;
      messageQuery.status = firstRoom?.status === 'deleted' ? 'deleted' : 'visible';
    }
    if (reloadMessages) {
      if (selectedRoomId.value) await loadMessages();
      else clearMessageState();
    }
  } catch (error) {
    ElMessage.error(errorMessage(error, '聊天室列表加载失败'));
  } finally {
    roomsLoading.value = false;
  }
}

async function loadRoomOptions(): Promise<void> {
  try {
    const data = await listChatRooms({ status: 'all', page: 1, pageSize: 100 });
    roomOptions.value = data.items;
  } catch {
    roomOptions.value = rooms.value;
  }
}

async function loadMessages(): Promise<void> {
  if (!selectedRoomId.value) return;
  messagesLoading.value = true;
  try {
    const data = await listChatRoomMessages({
      roomId: selectedRoomId.value,
      ...messageQuery,
    });
    messages.value = data.items;
    messageTotal.value = data.total;
    messageStatusCounts.value = data.statusCounts as Record<string, number>;
    selectedRoomDetail.value = data.room;
    const availableIds = new Set(data.items.map((item) => item.id));
    selectedMessageIds.value = selectedMessageIds.value.filter((id) => availableIds.has(id));
  } catch (error) {
    ElMessage.error(errorMessage(error, '房间消息加载失败'));
  } finally {
    messagesLoading.value = false;
  }
}

function searchRooms(): void {
  roomQuery.page = 1;
  void loadRooms();
}

function selectRoom(room: ChatRoom): void {
  if (room.roomId === selectedRoomId.value) return;
  selectedRoomId.value = room.roomId;
  selectedRoomDetail.value = room;
  selectedMessageIds.value = [];
  Object.assign(messageQuery, {
    q: '',
    status: room.status === 'deleted' ? 'deleted' : 'visible',
    type: '',
    page: 1,
  });
  void loadMessages();
}

function searchMessages(): void {
  messageQuery.page = 1;
  selectedMessageIds.value = [];
  void loadMessages();
}

function clearMessageState(): void {
  messages.value = [];
  messageTotal.value = 0;
  messageStatusCounts.value = {};
  selectedMessageIds.value = [];
  selectedRoomDetail.value = null;
}

function openCreateRoom(): void {
  editingRoom.value = null;
  roomEditorOpen.value = true;
}

function openEditRoom(room: ChatRoom): void {
  editingRoom.value = room;
  roomEditorOpen.value = true;
}

async function saveRoom(payload: { data: ChatRoomPayload; avatarFile: File | null }): Promise<void> {
  if (roomSaving.value) return;
  roomSaving.value = true;
  try {
    const data = { ...payload.data };
    if (payload.avatarFile) data.avatarUrl = await uploadChatRoomAvatar(payload.avatarFile);
    const response = editingRoom.value
      ? await updateChatRoom(editingRoom.value.roomId, data)
      : await createChatRoom(data);
    roomEditorOpen.value = false;
    selectedRoomId.value = response.item.roomId;
    ElMessage.success(editingRoom.value ? '聊天室设置已保存' : '聊天室已创建，可立即进入使用');
    await loadRooms();
  } catch (error) {
    ElMessage.error(errorMessage(error, '聊天室保存失败'));
  } finally {
    roomSaving.value = false;
  }
}

async function toggleRoomVisibility(room: ChatRoom): Promise<void> {
  const nextStatus = room.status === 'hidden' ? 'active' : 'hidden';
  try {
    await updateChatRoom(room.roomId, { status: nextStatus });
    ElMessage.success(nextStatus === 'hidden' ? '房间已隐藏，用户暂时不能进入' : '房间已重新开放');
    await loadRooms();
  } catch (error) {
    ElMessage.error(errorMessage(error, '房间状态更新失败'));
  }
}

async function handleRoomCommand(command: string): Promise<void> {
  const room = selectedRoom.value;
  if (!room) return;
  if (command === 'visibility') {
    await toggleRoomVisibility(room);
    return;
  }
  if (command === 'clear') {
    try {
      await ElMessageBox.confirm(
        `将删除“${room.name}”当前全部可见消息。管理员仍可在“已删除”筛选中恢复，是否继续？`,
        '清空房间消息',
        { type: 'warning', confirmButtonText: '确认清空', cancelButtonText: '取消' },
      );
      const result = await clearChatRoom(room.roomId);
      ElMessage.success(`已删除 ${result.deleted} 条消息`);
      await Promise.all([loadMessages(), loadRooms(false)]);
    } catch (error) {
      if (error !== 'cancel' && error !== 'close') ElMessage.error(errorMessage(error, '清空失败'));
    }
    return;
  }
  if (command === 'dissolve') {
    try {
      await ElMessageBox.confirm(
        `解散“${room.name}”会移除全部成员并删除可见消息，成员关系无法恢复。建议临时停用时选择“隐藏房间”。`,
        '确认永久解散房间？',
        {
          type: 'error',
          confirmButtonText: '永久解散',
          cancelButtonText: '取消',
          distinguishCancelAndClose: true,
        },
      );
      await dissolveChatRoom(room.roomId);
      ElMessage.success('聊天室已解散');
      selectedRoomId.value = '';
      await loadRooms();
    } catch (error) {
      if (error !== 'cancel' && error !== 'close') ElMessage.error(errorMessage(error, '房间解散失败'));
    }
  }
}

function toggleMessageSelection(id: number, checked: boolean): void {
  const next = new Set(selectedMessageIds.value);
  if (checked) next.add(id);
  else next.delete(id);
  selectedMessageIds.value = [...next];
}

async function changeMessageStatus(item: ChatMessage, status: ChatMessageStatus): Promise<void> {
  try {
    await updateChatMessageStatus(item.id, status);
    ElMessage.success(status === 'deleted' ? '消息已删除' : '消息已恢复展示');
    if (messages.value.length === 1 && messageQuery.page > 1) messageQuery.page -= 1;
    await Promise.all([loadMessages(), loadRooms(false)]);
  } catch (error) {
    ElMessage.error(errorMessage(error, '消息状态更新失败'));
  }
}

async function batchChangeMessageStatus(): Promise<void> {
  if (!selectedMessageIds.value.length) return;
  const status = batchTargetStatus.value;
  try {
    if (status === 'deleted') {
      await ElMessageBox.confirm(
        `确定删除选中的 ${selectedMessageIds.value.length} 条消息？删除后可从“已删除”筛选恢复。`,
        '批量删除消息',
        { type: 'warning', confirmButtonText: '确认删除', cancelButtonText: '取消' },
      );
    }
    const result = await updateChatMessagesStatus(selectedMessageIds.value, status);
    ElMessage.success(status === 'deleted'
      ? `已删除 ${result.updated} 条消息`
      : `已恢复 ${result.updated} 条消息`);
    selectedMessageIds.value = [];
    await Promise.all([loadMessages(), loadRooms(false)]);
  } catch (error) {
    if (error !== 'cancel' && error !== 'close') ElMessage.error(errorMessage(error, '批量操作失败'));
  }
}

function openMessage(itemOrId: ChatMessage | number): void {
  selectedMessageId.value = typeof itemOrId === 'number' ? itemOrId : itemOrId.id;
  reportOpen.value = false;
  messageDrawerOpen.value = true;
}

async function handleMessageDrawerStatusChanged(): Promise<void> {
  await Promise.all([loadMessages(), loadRooms(false)]);
}

async function loadKeywords(): Promise<void> {
  keywordsLoading.value = true;
  try {
    const data = await listChatKeywords(keywordQuery);
    keywords.value = data.items;
    keywordTotal.value = data.total;
    keywordStatusCounts.value = data.statusCounts as Record<string, number>;
  } catch (error) {
    ElMessage.error(errorMessage(error, '关键词规则加载失败'));
  } finally {
    keywordsLoading.value = false;
  }
}

function searchKeywords(): void {
  keywordQuery.page = 1;
  void loadKeywords();
}

function openCreateKeyword(): void {
  editingKeyword.value = null;
  keywordEditorOpen.value = true;
}

function openEditKeyword(rule: ChatKeywordRule): void {
  editingKeyword.value = rule;
  keywordEditorOpen.value = true;
}

async function saveKeyword(payload: ChatKeywordPayload): Promise<void> {
  if (keywordSaving.value) return;
  keywordSaving.value = true;
  try {
    if (editingKeyword.value) await updateChatKeyword(editingKeyword.value.id, payload);
    else await createChatKeyword(payload);
    keywordEditorOpen.value = false;
    ElMessage.success(editingKeyword.value ? '关键词规则已保存' : '关键词规则已启用');
    await Promise.all([loadKeywords(), loadRooms(false)]);
  } catch (error) {
    ElMessage.error(errorMessage(error, '关键词规则保存失败'));
  } finally {
    keywordSaving.value = false;
  }
}

async function toggleKeyword(rule: ChatKeywordRule): Promise<void> {
  try {
    await updateChatKeyword(rule.id, { status: rule.status === 'active' ? 'inactive' : 'active' });
    ElMessage.success(rule.status === 'active' ? '规则已停用' : '规则已启用');
    await loadKeywords();
  } catch (error) {
    ElMessage.error(errorMessage(error, '规则状态更新失败'));
  }
}

async function removeKeyword(rule: ChatKeywordRule): Promise<void> {
  try {
    await deleteChatKeyword(rule.id);
    ElMessage.success('规则已删除，历史违规记录仍会保留');
    await loadKeywords();
  } catch (error) {
    ElMessage.error(errorMessage(error, '规则删除失败'));
  }
}

async function runKeywordTest(): Promise<void> {
  const content = keywordTestContent.value.trim();
  if (!content) {
    ElMessage.warning('请输入要测试的聊天消息');
    return;
  }
  keywordTesting.value = true;
  try {
    keywordTestResult.value = await testChatKeyword(content);
  } catch (error) {
    ElMessage.error(errorMessage(error, '规则测试失败'));
  } finally {
    keywordTesting.value = false;
  }
}

async function loadViolations(): Promise<void> {
  violationsLoading.value = true;
  try {
    const data = await listChatViolations(violationQuery);
    violations.value = data.items;
    violationTotal.value = data.total;
    violationActionCounts.value = data.actionCounts as Record<string, number>;
  } catch (error) {
    ElMessage.error(errorMessage(error, '违规记录加载失败'));
  } finally {
    violationsLoading.value = false;
  }
}

function searchViolations(): void {
  violationQuery.page = 1;
  void loadViolations();
}

async function blockViolationIp(item: ChatViolation): Promise<void> {
  if (!item.ip) return;
  try {
    await ElMessageBox.confirm(
      `将 ${item.ip} 加入注册 IP 黑名单，后续使用该 IP 的新账号将无法注册。`,
      '封禁来源 IP',
      { type: 'warning', confirmButtonText: '加入黑名单', cancelButtonText: '取消' },
    );
    await blockIp({ ip: item.ip, userId: item.user.id, reason: 'chat_keyword_manual_review' });
    ElMessage.success('来源 IP 已加入注册黑名单');
    await loadRooms(false);
  } catch (error) {
    if (error !== 'cancel' && error !== 'close') ElMessage.error(errorMessage(error, 'IP 封禁失败'));
  }
}

async function loadBlockedIps(): Promise<void> {
  ipsLoading.value = true;
  try {
    const data = await listBlockedIps(ipQuery);
    blockedIps.value = data.items;
    blockedIpTotal.value = data.total;
  } catch (error) {
    ElMessage.error(errorMessage(error, 'IP 黑名单加载失败'));
  } finally {
    ipsLoading.value = false;
  }
}

function searchIps(): void {
  ipQuery.page = 1;
  void loadBlockedIps();
}

function openIpDialog(): void {
  Object.assign(ipForm, { ip: '', reason: 'admin_block', note: '' });
  ipDialogOpen.value = true;
}

async function saveBlockedIp(): Promise<void> {
  const ip = ipForm.ip.trim();
  if (!ip) {
    ElMessage.warning('请填写 IPv4 或 IPv6 地址');
    return;
  }
  ipSaving.value = true;
  try {
    const reason = ipForm.note.trim()
      ? `${ipForm.reason}:${ipForm.note.trim()}`
      : ipForm.reason;
    await blockIp({ ip, reason });
    ipDialogOpen.value = false;
    ElMessage.success('IP 已加入注册黑名单');
    await Promise.all([loadBlockedIps(), loadRooms(false)]);
  } catch (error) {
    ElMessage.error(errorMessage(error, 'IP 黑名单保存失败'));
  } finally {
    ipSaving.value = false;
  }
}

async function removeBlockedIp(item: BlockedIp): Promise<void> {
  try {
    await unblockIp(item.ip);
    ElMessage.success('IP 已移出注册黑名单');
    if (blockedIps.value.length === 1 && ipQuery.page > 1) ipQuery.page -= 1;
    await Promise.all([loadBlockedIps(), loadRooms(false)]);
  } catch (error) {
    ElMessage.error(errorMessage(error, '移出黑名单失败'));
  }
}

function openReport(item: ReportItem): void {
  selectedReport.value = item;
  messageDrawerOpen.value = false;
  reportOpen.value = true;
}

async function changeReportStatus(status: ReportStatus): Promise<void> {
  if (!selectedReport.value || reportProcessing.value) return;
  reportProcessing.value = true;
  try {
    await updateReportStatus(selectedReport.value.id, status);
    ElMessage.success(status === 'open' ? '举报已重新打开' : status === 'resolved' ? '举报已处理' : '举报已忽略');
    reportOpen.value = false;
  } catch (error) {
    ElMessage.error(errorMessage(error, '举报状态更新失败'));
  } finally {
    reportProcessing.value = false;
  }
}

async function deleteReportedTarget(): Promise<void> {
  if (!selectedReport.value || reportProcessing.value) return;
  reportProcessing.value = true;
  try {
    await resolveReportAndDeleteTarget(selectedReport.value.id);
    ElMessage.success('举报消息已删除，举报已完成');
    reportOpen.value = false;
    await Promise.all([loadMessages(), loadRooms(false)]);
  } catch (error) {
    ElMessage.error(errorMessage(error, '举报消息处置失败'));
  } finally {
    reportProcessing.value = false;
  }
}

function openViolationRoom(item: ChatViolation): void {
  activeTab.value = 'rooms';
  roomQuery.status = 'all';
  roomQuery.category = '';
  roomQuery.q = item.roomId;
  roomQuery.page = 1;
  selectedRoomId.value = item.roomId;
  messageQuery.q = '';
  messageQuery.page = 1;
  void loadRooms();
}

function stopAutoRefresh(): void {
  if (refreshTimer !== null) window.clearInterval(refreshTimer);
  refreshTimer = null;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <div class="chat-page">
    <section class="chat-hero">
      <div class="hero-copy">
        <span class="eyebrow">COMMUNITY OPERATIONS</span>
        <h1>聊天室运营与风控</h1>
        <p>房间配置、消息审核、关键词策略和封禁证据分区处理；每个危险操作都保留确认与恢复路径。</p>
      </div>
      <div class="hero-orbit" aria-hidden="true">
        <span class="orbit-main"><ElIcon><ChatDotRound /></ElIcon></span>
        <i class="orbit-dot dot-one" /><i class="orbit-dot dot-two" /><i class="orbit-dot dot-three" />
      </div>
    </section>

    <section class="metric-grid">
      <button type="button" class="metric-card cherry" @click="activeTab = 'rooms'">
        <span><ElIcon><ChatDotRound /></ElIcon>开放房间</span><strong>{{ stats.activeRooms }}</strong><small>{{ stats.hiddenRooms }} 个已隐藏</small>
      </button>
      <button type="button" class="metric-card gold" @click="activeTab = 'rooms'">
        <span><ElIcon><CircleCheck /></ElIcon>正常消息</span><strong>{{ stats.visibleMessages }}</strong><small>近 24h 新增 {{ stats.messages24h }}</small>
      </button>
      <button type="button" class="metric-card rose" @click="activeTab = 'violations'">
        <span><ElIcon><WarningFilled /></ElIcon>今日违规</span><strong>{{ stats.violationsToday }}</strong><small>命中后自动拦截</small>
      </button>
      <button type="button" class="metric-card violet" @click="activeTab = 'keywords'">
        <span><ElIcon><Lock /></ElIcon>启用规则</span><strong>{{ stats.activeKeywords }}</strong><small>可在线试跑</small>
      </button>
      <button type="button" class="metric-card blue" @click="activeTab = 'ips'">
        <span><ElIcon><Flag /></ElIcon>封禁 IP</span><strong>{{ stats.blockedIps }}</strong><small>阻止恶意重复注册</small>
      </button>
    </section>

    <section class="workspace-card">
      <ElTabs v-model="activeTab" class="workspace-tabs">
        <ElTabPane name="rooms">
          <template #label><span class="tab-label"><ElIcon><ChatDotRound /></ElIcon>房间与消息</span></template>

          <div class="room-toolbar">
            <ElInput v-model="roomQuery.q" clearable placeholder="搜索房间名、ID 或消息内容" @keyup.enter="searchRooms">
              <template #prefix><ElIcon><Search /></ElIcon></template>
            </ElInput>
            <ElSelect v-model="roomQuery.category" clearable placeholder="全部分类" @change="searchRooms">
              <ElOption v-for="item in categories" :key="item.key" :label="`${item.label}（${item.count}）`" :value="item.key" />
            </ElSelect>
            <ElSelect v-model="roomQuery.status" @change="searchRooms">
              <ElOption :label="`全部状态（${roomAllCount}）`" value="all" />
              <ElOption :label="`开放中（${roomStatusCounts.active || 0}）`" value="active" />
              <ElOption :label="`已隐藏（${roomStatusCounts.hidden || 0}）`" value="hidden" />
              <ElOption :label="`已解散（${roomStatusCounts.deleted || 0}）`" value="deleted" />
            </ElSelect>
            <ElButton :icon="Refresh" :loading="roomsLoading" @click="loadRooms()">刷新</ElButton>
            <ElButton type="primary" :icon="Plus" @click="openCreateRoom">新建房间</ElButton>
          </div>

          <div class="room-workspace">
            <aside class="room-list-panel">
              <div class="panel-heading"><strong>聊天室</strong><span>{{ roomTotal }} 个结果</span></div>
              <div v-loading="roomsLoading" class="room-list">
                <button
                  v-for="room in rooms"
                  :key="room.roomId"
                  type="button"
                  class="room-card"
                  :class="{ active: room.roomId === selectedRoomId, dissolved: room.status === 'deleted' }"
                  @click="selectRoom(room)"
                >
                  <span class="room-card-avatar">
                    <img v-if="room.avatarUrl" :src="room.avatarUrl" alt="" />
                    <b v-else>{{ room.name.slice(0, 1) }}</b>
                  </span>
                  <span class="room-card-main">
                    <span class="room-card-title">
                      <strong>{{ room.name }}</strong>
                      <i v-if="room.isOfficial">官方</i>
                    </span>
                    <small>{{ room.categoryLabel }} · {{ chatRoomStatusLabel(room.status) }} · Lv.{{ room.minLevel }}</small>
                    <em>{{ room.latestContent || '暂无消息' }}</em>
                    <span class="room-card-stats">
                      <span>{{ room.messageCount }} 消息</span><span>{{ room.memberCount }} 成员</span><span>24h {{ room.recentMessageCount }}</span>
                    </span>
                  </span>
                </button>
                <ElEmpty v-if="!roomsLoading && !rooms.length" :image-size="72" description="没有符合条件的聊天室" />
              </div>
              <ElPagination
                v-if="roomTotal > roomQuery.pageSize"
                v-model:current-page="roomQuery.page"
                small
                background
                layout="prev, pager, next"
                :page-size="roomQuery.pageSize"
                :total="roomTotal"
                @current-change="loadRooms()"
              />
            </aside>

            <main class="message-panel">
              <template v-if="selectedRoom">
                <header class="selected-room-header">
                  <div class="selected-room-identity">
                    <span class="selected-room-avatar">
                      <img v-if="selectedRoom.avatarUrl" :src="selectedRoom.avatarUrl" alt="" />
                      <b v-else>{{ selectedRoom.name.slice(0, 1) }}</b>
                    </span>
                    <div>
                      <span class="room-title-line">
                        <h2>{{ selectedRoom.name }}</h2>
                        <ElTag v-if="selectedRoom.isOfficial" type="danger" effect="light">官方</ElTag>
                        <ElTag :type="selectedRoom.status === 'active' ? 'success' : 'info'">{{ chatRoomStatusLabel(selectedRoom.status) }}</ElTag>
                      </span>
                      <p>{{ selectedRoom.roomId }} · {{ selectedRoom.categoryLabel }} · Lv.{{ selectedRoom.minLevel }} 准入</p>
                    </div>
                  </div>
                  <div v-if="selectedRoom.status !== 'deleted'" class="selected-room-actions">
                    <ElButton :icon="UserFilled" @click="membersOpen = true">成员 {{ selectedRoom.memberCount }}</ElButton>
                    <ElButton :icon="EditPen" @click="openEditRoom(selectedRoom)">设置</ElButton>
                    <ElDropdown trigger="click" @command="handleRoomCommand">
                      <ElButton :icon="MoreFilled">更多</ElButton>
                      <template #dropdown>
                        <ElDropdownMenu>
                          <ElDropdownItem command="visibility">{{ selectedRoom.status === 'hidden' ? '重新开放房间' : '隐藏房间' }}</ElDropdownItem>
                          <ElDropdownItem command="clear" divided>清空可见消息</ElDropdownItem>
                          <ElDropdownItem command="dissolve" divided class="danger-dropdown">永久解散房间</ElDropdownItem>
                        </ElDropdownMenu>
                      </template>
                    </ElDropdown>
                  </div>
                </header>

                <div class="room-facts">
                  <span><b>{{ selectedRoom.messageCount }}</b> 正常消息</span>
                  <span><b>{{ selectedRoom.deletedMessageCount }}</b> 已删除</span>
                  <span><b>{{ selectedRoom.recentMessageCount }}</b> 近 24 小时</span>
                  <span><b>{{ selectedRoom.activeUserCount || 0 }}</b> 近 10 分钟发言用户</span>
                </div>

                <div class="message-toolbar">
                  <ElInput v-model="messageQuery.q" clearable placeholder="在当前房间搜索消息或用户" @keyup.enter="searchMessages">
                    <template #prefix><ElIcon><Search /></ElIcon></template>
                  </ElInput>
                  <ElSelect v-model="messageQuery.status" @change="searchMessages">
                    <ElOption :label="`展示中（${messageStatusCounts.visible || 0}）`" value="visible" />
                    <ElOption :label="`已删除（${messageStatusCounts.deleted || 0}）`" value="deleted" />
                  </ElSelect>
                  <ElSelect v-model="messageQuery.type" clearable placeholder="全部类型" @change="searchMessages">
                    <ElOption label="文字" value="text" /><ElOption label="图片" value="image" />
                    <ElOption label="语音" value="audio" /><ElOption label="文件" value="file" />
                    <ElOption label="贴纸" value="sticker" /><ElOption label="内容分享" value="share" />
                  </ElSelect>
                  <label class="auto-refresh"><ElSwitch v-model="autoRefresh" size="small" /><span>15 秒刷新</span></label>
                  <ElButton :icon="Refresh" :loading="messagesLoading" @click="loadMessages">刷新</ElButton>
                </div>

                <div v-if="selectedMessageIds.length" class="batch-bar">
                  <span>已选择 <b>{{ selectedMessageIds.length }}</b> 条消息</span>
                  <ElButton
                    :type="batchTargetStatus === 'deleted' ? 'danger' : 'primary'"
                    plain
                    :icon="batchTargetStatus === 'deleted' ? Delete : RefreshLeft"
                    @click="batchChangeMessageStatus"
                  >{{ batchTargetStatus === 'deleted' ? '批量删除' : '批量恢复' }}</ElButton>
                  <ElButton text @click="selectedMessageIds = []">取消选择</ElButton>
                </div>

                <div v-loading="messagesLoading" class="message-list">
                  <article
                    v-for="item in messages"
                    :key="item.id"
                    class="message-card"
                    :class="{ deleted: item.status === 'deleted', selected: selectedMessageIds.includes(item.id) }"
                    @click="openMessage(item)"
                  >
                    <ElCheckbox
                      :model-value="selectedMessageIds.includes(item.id)"
                      @click.stop
                      @change="toggleMessageSelection(item.id, Boolean($event))"
                    />
                    <ElAvatar :src="item.user.avatarUrl" :size="42">{{ item.user.nickname?.slice(0, 1) }}</ElAvatar>
                    <div class="message-main">
                      <div class="message-meta">
                        <strong>{{ item.user.nickname || `用户 #${item.user.id}` }}</strong>
                        <ElTag size="small" effect="plain">{{ chatMessageTypeLabel(item.type) }}</ElTag>
                        <ElTag v-if="item.status === 'deleted'" size="small" type="info">已删除</ElTag>
                        <span>UID {{ item.user.id }} · {{ formatDateTime(item.createdAt) }}</span>
                      </div>
                      <p>{{ chatMessageSummary(item.type, item.content) }}</p>
                      <a v-if="item.mediaUrl" :href="item.mediaUrl" target="_blank" rel="noreferrer" @click.stop>查看消息媒体</a>
                    </div>
                    <div class="message-actions" @click.stop>
                      <ElButton text :icon="View" @click="openMessage(item)">上下文</ElButton>
                      <ElPopconfirm
                        v-if="item.status === 'visible'"
                        title="确定删除这条消息？"
                        confirm-button-text="删除"
                        cancel-button-text="取消"
                        @confirm="changeMessageStatus(item, 'deleted')"
                      >
                        <template #reference><ElButton text type="danger" :icon="Delete">删除</ElButton></template>
                      </ElPopconfirm>
                      <ElButton v-else text type="primary" :icon="RefreshLeft" @click="changeMessageStatus(item, 'visible')">恢复</ElButton>
                    </div>
                  </article>
                  <ElEmpty v-if="!messagesLoading && !messages.length" :image-size="78" description="当前筛选下没有消息" />
                </div>

                <ElPagination
                  v-if="messageTotal > messageQuery.pageSize"
                  v-model:current-page="messageQuery.page"
                  v-model:page-size="messageQuery.pageSize"
                  class="message-pagination"
                  background
                  layout="total, sizes, prev, pager, next"
                  :page-sizes="[10, 20, 50, 100]"
                  :total="messageTotal"
                  @current-change="loadMessages"
                  @size-change="searchMessages"
                />
              </template>
              <ElEmpty v-else description="从左侧选择一个聊天室查看消息" />
            </main>
          </div>
        </ElTabPane>

        <ElTabPane name="keywords">
          <template #label><span class="tab-label"><ElIcon><Lock /></ElIcon>关键词规则</span></template>
          <div class="risk-intro">
            <span class="risk-icon"><ElIcon><Setting /></ElIcon></span>
            <div><strong>规则在消息写入前执行</strong><p>命中消息不会进入数据库或广播给其他用户，但会留下违规证据，并按累计次数升级封禁。</p></div>
          </div>

          <section class="keyword-tester">
            <div><span>ACTIVE RULE TEST</span><h3>在线试跑当前启用规则</h3><p>输入示例消息，只返回命中结果，不会生成违规记录。</p></div>
            <div class="tester-control">
              <ElInput v-model="keywordTestContent" clearable placeholder="输入一条聊天消息" @keyup.enter="runKeywordTest" />
              <ElButton type="primary" :loading="keywordTesting" @click="runKeywordTest">测试规则</ElButton>
            </div>
            <div v-if="keywordTestResult" class="tester-result" :class="{ matched: keywordTestResult.matched }">
              <ElIcon><WarningFilled v-if="keywordTestResult.matched" /><CircleCheck v-else /></ElIcon>
              <span v-if="keywordTestResult.matched">命中“{{ keywordTestResult.item?.keyword }}” · {{ chatKeywordMatchLabel(keywordTestResult.item?.matchType || 'contains') }}</span>
              <span v-else>未命中任何启用规则，可以正常发送</span>
            </div>
          </section>

          <div class="risk-toolbar">
            <ElInput v-model="keywordQuery.q" clearable placeholder="搜索关键词或运营备注" @keyup.enter="searchKeywords">
              <template #prefix><ElIcon><Search /></ElIcon></template>
            </ElInput>
            <ElSelect v-model="keywordQuery.status" clearable placeholder="全部状态" @change="searchKeywords">
              <ElOption :label="`启用（${keywordStatusCounts.active || 0}）`" value="active" />
              <ElOption :label="`停用（${keywordStatusCounts.inactive || 0}）`" value="inactive" />
            </ElSelect>
            <ElButton :icon="Refresh" :loading="keywordsLoading" @click="loadKeywords">刷新</ElButton>
            <ElButton type="primary" :icon="Plus" @click="openCreateKeyword">新增规则</ElButton>
          </div>

          <div v-loading="keywordsLoading" class="keyword-grid">
            <article v-for="rule in keywords" :key="rule.id" class="keyword-card" :class="{ inactive: rule.status === 'inactive' }">
              <div class="keyword-card-head">
                <span class="keyword-symbol">{{ rule.keyword.slice(0, 1) }}</span>
                <div><h3>{{ rule.keyword }}</h3><p>{{ rule.note || '暂无运营备注' }}</p></div>
                <ElTag :type="rule.status === 'active' ? 'success' : 'info'">{{ rule.status === 'active' ? '启用' : '停用' }}</ElTag>
              </div>
              <dl>
                <div><dt>匹配方式</dt><dd>{{ chatKeywordMatchLabel(rule.matchType) }}</dd></div>
                <div><dt>累计命中</dt><dd>{{ rule.hitCount }} 次</dd></div>
                <div><dt>最近命中</dt><dd>{{ rule.lastHitAt ? formatDateTime(rule.lastHitAt) : '尚未命中' }}</dd></div>
              </dl>
              <div class="keyword-actions">
                <ElButton text :icon="EditPen" @click="openEditKeyword(rule)">编辑</ElButton>
                <ElButton text :type="rule.status === 'active' ? 'warning' : 'primary'" @click="toggleKeyword(rule)">{{ rule.status === 'active' ? '停用' : '启用' }}</ElButton>
                <ElPopconfirm title="删除后历史违规记录仍会保留，确定继续？" width="260" @confirm="removeKeyword(rule)">
                  <template #reference><ElButton text type="danger" :icon="Delete">删除</ElButton></template>
                </ElPopconfirm>
              </div>
            </article>
            <ElEmpty v-if="!keywordsLoading && !keywords.length" description="没有符合条件的关键词规则" />
          </div>
          <ElPagination
            v-if="keywordTotal > keywordQuery.pageSize"
            v-model:current-page="keywordQuery.page"
            class="risk-pagination"
            background
            layout="total, prev, pager, next"
            :page-size="keywordQuery.pageSize"
            :total="keywordTotal"
            @current-change="loadKeywords"
          />
        </ElTabPane>

        <ElTabPane name="violations">
          <template #label><span class="tab-label"><ElIcon><WarningFilled /></ElIcon>违规记录</span></template>
          <div class="risk-intro warning">
            <span class="risk-icon"><ElIcon><WarningFilled /></ElIcon></span>
            <div><strong>这里展示真实的拦截证据与最终处置</strong><p>“临时封禁 / 永久封禁”记录的是该次命中实际触发的升级结果，不再全部笼统显示为“已拦截”。</p></div>
          </div>
          <div class="violation-summary">
            <button @click="violationQuery.action = ''; searchViolations()"><b>{{ Object.values(violationActionCounts).reduce((sum, value) => sum + Number(value || 0), 0) }}</b><span>全部记录</span></button>
            <button @click="violationQuery.action = 'blocked'; searchViolations()"><b>{{ violationActionCounts.blocked || 0 }}</b><span>仅拦截</span></button>
            <button @click="violationQuery.action = 'temp_ban'; searchViolations()"><b>{{ violationActionCounts.temp_ban || 0 }}</b><span>临时封禁</span></button>
            <button @click="violationQuery.action = 'permanent_ban'; searchViolations()"><b>{{ violationActionCounts.permanent_ban || 0 }}</b><span>永久封禁</span></button>
          </div>
          <div class="risk-toolbar violation-toolbar">
            <ElInput v-model="violationQuery.q" clearable placeholder="搜索消息、命中词或用户" @keyup.enter="searchViolations"><template #prefix><ElIcon><Search /></ElIcon></template></ElInput>
            <ElSelect v-model="violationQuery.roomId" clearable filterable placeholder="全部房间" @change="searchViolations">
              <ElOption v-for="room in roomOptions" :key="room.roomId" :label="room.name" :value="room.roomId" />
            </ElSelect>
            <ElSelect v-model="violationQuery.action" clearable placeholder="全部处置" @change="searchViolations">
              <ElOption label="仅拦截消息" value="blocked" /><ElOption label="临时封禁" value="temp_ban" /><ElOption label="永久封禁" value="permanent_ban" />
            </ElSelect>
            <ElButton :icon="Refresh" :loading="violationsLoading" @click="loadViolations">刷新</ElButton>
          </div>
          <div v-loading="violationsLoading" class="violation-list">
            <article v-for="item in violations" :key="item.id" class="violation-card" :class="item.action">
              <div class="violation-user">
                <ElAvatar :size="42">{{ item.user.nickname?.slice(0, 1) }}</ElAvatar>
                <div><strong>{{ item.user.nickname || `用户 #${item.user.id}` }}</strong><span>{{ item.user.email }} · UID {{ item.user.id }}</span></div>
              </div>
              <div class="violation-content"><blockquote>{{ item.content }}</blockquote><span>命中：<b>{{ item.keyword || '已删除规则' }}</b> · 房间 {{ item.roomId }}</span></div>
              <div class="violation-result">
                <ElTag :type="item.action === 'blocked' ? 'warning' : 'danger'">{{ chatViolationActionLabel(item.action) }}</ElTag>
                <span>{{ item.ip || '未记录 IP' }}</span><small>{{ formatDateTime(item.createdAt) }}</small>
              </div>
              <div class="violation-actions">
                <ElButton text :icon="ChatDotRound" @click="openViolationRoom(item)">查看房间</ElButton>
                <ElButton v-if="item.ip" text type="danger" :icon="Lock" @click="blockViolationIp(item)">封禁来源 IP</ElButton>
              </div>
            </article>
            <ElEmpty v-if="!violationsLoading && !violations.length" description="没有符合条件的违规记录" />
          </div>
          <ElPagination
            v-if="violationTotal > violationQuery.pageSize"
            v-model:current-page="violationQuery.page"
            class="risk-pagination"
            background layout="total, prev, pager, next"
            :page-size="violationQuery.pageSize" :total="violationTotal"
            @current-change="loadViolations"
          />
        </ElTabPane>

        <ElTabPane name="ips">
          <template #label><span class="tab-label"><ElIcon><Flag /></ElIcon>IP 黑名单</span></template>
          <div class="risk-intro blue">
            <span class="risk-icon"><ElIcon><Flag /></ElIcon></span>
            <div><strong>这是注册 IP 黑名单，不是全站防火墙</strong><p>它阻止同一 IP 创建新账号；当前在线连接和已有账号状态应在违规记录或用户管理中单独处置。</p></div>
          </div>
          <div class="risk-toolbar ip-toolbar">
            <ElInput v-model="ipQuery.q" clearable placeholder="搜索 IP、原因或关联用户" @keyup.enter="searchIps"><template #prefix><ElIcon><Search /></ElIcon></template></ElInput>
            <ElButton :icon="Refresh" :loading="ipsLoading" @click="loadBlockedIps">刷新</ElButton>
            <ElButton type="primary" :icon="Plus" @click="openIpDialog">添加 IP</ElButton>
          </div>
          <div v-loading="ipsLoading" class="ip-grid">
            <article v-for="item in blockedIps" :key="item.ip" class="ip-card">
              <span class="ip-lock"><ElIcon><Lock /></ElIcon></span>
              <div class="ip-main"><h3>{{ item.ip }}</h3><p>{{ chatBlockReasonLabel(item.reason) }}</p><span v-if="item.user">关联 {{ item.user.nickname || item.user.email }} · UID {{ item.user.id }}</span><small>加入于 {{ formatDateTime(item.createdAt) }}</small></div>
              <ElPopconfirm :title="`确定将 ${item.ip} 移出注册黑名单？`" width="250" @confirm="removeBlockedIp(item)">
                <template #reference><ElButton text type="danger" :icon="Delete">移出</ElButton></template>
              </ElPopconfirm>
            </article>
            <ElEmpty v-if="!ipsLoading && !blockedIps.length" description="注册 IP 黑名单为空" />
          </div>
          <ElPagination
            v-if="blockedIpTotal > ipQuery.pageSize"
            v-model:current-page="ipQuery.page"
            class="risk-pagination" background layout="total, prev, pager, next"
            :page-size="ipQuery.pageSize" :total="blockedIpTotal"
            @current-change="loadBlockedIps"
          />
        </ElTabPane>
      </ElTabs>
    </section>

    <ChatRoomEditorDrawer v-model="roomEditorOpen" :room="editingRoom" :saving="roomSaving" @submit="saveRoom" />
    <ChatMembersDrawer v-model="membersOpen" :room="selectedRoom" @changed="loadRooms(false)" />
    <ChatMessageDrawer
      v-model="messageDrawerOpen"
      :message-id="selectedMessageId"
      @status-changed="handleMessageDrawerStatusChanged"
      @open-message="openMessage"
      @open-report="openReport"
    />
    <ChatKeywordDrawer v-model="keywordEditorOpen" :rule="editingKeyword" :saving="keywordSaving" @submit="saveKeyword" />
    <ReportDetailDrawer
      v-model="reportOpen"
      :report="selectedReport"
      :processing="reportProcessing"
      @change-status="changeReportStatus"
      @delete-target="deleteReportedTarget"
    />

    <ElDialog v-model="ipDialogOpen" title="添加注册 IP 黑名单" width="min(480px, 92vw)">
      <div class="ip-dialog-note"><ElIcon><Flag /></ElIcon><span>请只添加有明确证据的 IP；误封会影响同网络下其他用户注册。</span></div>
      <ElForm label-position="top">
        <ElFormItem label="IPv4 / IPv6 地址" required><ElInput v-model="ipForm.ip" placeholder="例如 203.0.113.10" /></ElFormItem>
        <ElFormItem label="封禁原因" required>
          <ElSelect v-model="ipForm.reason" class="full-width">
            <ElOption label="管理员手动封禁" value="admin_block" /><ElOption label="恶意重复注册" value="malicious_registration" /><ElOption label="聊天违规复核" value="chat_keyword_manual_review" />
          </ElSelect>
        </ElFormItem>
        <ElFormItem label="补充说明"><ElInput v-model="ipForm.note" maxlength="80" show-word-limit placeholder="可选，记录证据或工单编号" /></ElFormItem>
      </ElForm>
      <template #footer><ElButton @click="ipDialogOpen = false">取消</ElButton><ElButton type="primary" :loading="ipSaving" @click="saveBlockedIp">加入黑名单</ElButton></template>
    </ElDialog>
  </div>
</template>

<style scoped>
.chat-page { display: grid; gap: 18px; }
.chat-hero { position: relative; display: flex; min-height: 176px; align-items: center; justify-content: space-between; gap: 30px; padding: 30px 34px; overflow: hidden; border: 1px solid #f4d9e3; border-radius: 24px; background: radial-gradient(circle at 82% 20%, rgb(255 255 255 / 80%), transparent 32%), linear-gradient(135deg, #fff6fa 0%, #fff8ef 58%, #f6f2ff 100%); box-shadow: 0 16px 42px rgb(101 67 82 / 8%); }
.chat-hero::before { position: absolute; right: -55px; bottom: -85px; width: 250px; height: 250px; border-radius: 50%; background: rgb(239 132 172 / 9%); content: ''; }
.hero-copy { position: relative; z-index: 1; max-width: 720px; }
.eyebrow { color: #c45f83; font-size: 10px; font-weight: 850; letter-spacing: .16em; }
.hero-copy h1 { margin: 8px 0 10px; color: #392e33; font-size: clamp(26px, 3vw, 38px); letter-spacing: -.03em; }
.hero-copy p { max-width: 680px; margin: 0; color: #826f77; font-size: 14px; line-height: 1.75; }
.hero-orbit { position: relative; flex: 0 0 120px; width: 120px; height: 120px; }
.orbit-main { position: absolute; inset: 21px; display: grid; place-items: center; border-radius: 28px; color: #d35d88; background: rgb(255 255 255 / 78%); box-shadow: 0 14px 34px rgb(196 82 125 / 18%); transform: rotate(-7deg); }
.orbit-main :deep(.el-icon) { font-size: 38px; transform: rotate(7deg); }
.orbit-dot { position: absolute; display: block; border-radius: 50%; background: #f2a2bd; box-shadow: 0 0 0 7px rgb(255 255 255 / 55%); }
.dot-one { top: 7px; right: 18px; width: 13px; height: 13px; }.dot-two { bottom: 10px; left: 4px; width: 9px; height: 9px; background: #e8bc74; }.dot-three { right: 0; bottom: 28px; width: 7px; height: 7px; background: #a99bdf; }
.metric-grid { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 12px; }
.metric-card { display: grid; gap: 5px; padding: 17px 18px; border: 1px solid #eee3e7; border-radius: 18px; text-align: left; background: #fff; cursor: pointer; transition: transform .18s ease, box-shadow .18s ease; }
.metric-card:hover { box-shadow: 0 12px 28px rgb(87 57 70 / 9%); transform: translateY(-2px); }
.metric-card > span { display: flex; align-items: center; gap: 7px; color: #7f6d74; font-size: 12px; font-weight: 650; }.metric-card strong { color: #372c31; font-size: 27px; }.metric-card small { color: #a18e95; }
.metric-card :deep(.el-icon) { padding: 6px; border-radius: 9px; font-size: 17px; }.metric-card.cherry :deep(.el-icon) { color: #ca587f; background: #ffe7ef; }.metric-card.gold :deep(.el-icon) { color: #b67b23; background: #fff1d8; }.metric-card.rose :deep(.el-icon) { color: #d84f6e; background: #ffe5e9; }.metric-card.violet :deep(.el-icon) { color: #7b68bb; background: #eeeaff; }.metric-card.blue :deep(.el-icon) { color: #4c80ae; background: #e7f3ff; }
.workspace-card { padding: 0 20px 22px; border: 1px solid #eee3e7; border-radius: 22px; background: #fff; box-shadow: 0 14px 36px rgb(89 59 71 / 6%); }
.workspace-tabs :deep(.el-tabs__header) { margin: 0 0 18px; }.workspace-tabs :deep(.el-tabs__nav-wrap::after) { background: #f0e5e9; }.workspace-tabs :deep(.el-tabs__item) { height: 58px; color: #85727a; font-weight: 650; }.workspace-tabs :deep(.el-tabs__item.is-active) { color: #c3547b; }.workspace-tabs :deep(.el-tabs__active-bar) { height: 3px; border-radius: 3px; background: #d96890; }
.tab-label { display: inline-flex; align-items: center; gap: 7px; }
.room-toolbar, .risk-toolbar, .message-toolbar { display: grid; align-items: center; gap: 10px; }.room-toolbar { grid-template-columns: minmax(220px, 1fr) 160px 160px auto auto; margin-bottom: 15px; }.risk-toolbar { grid-template-columns: minmax(240px, 1fr) 170px auto auto; margin: 18px 0 14px; }.violation-toolbar { grid-template-columns: minmax(220px, 1fr) 190px 170px auto; }.ip-toolbar { grid-template-columns: minmax(220px, 1fr) auto auto; }
.room-workspace { display: grid; grid-template-columns: 330px minmax(0, 1fr); min-height: 620px; overflow: hidden; border: 1px solid #eee3e7; border-radius: 18px; background: #fbf9fa; }
.room-list-panel { display: flex; min-width: 0; flex-direction: column; padding: 14px; border-right: 1px solid #eee3e7; }.panel-heading { display: flex; align-items: center; justify-content: space-between; padding: 2px 3px 12px; }.panel-heading strong { color: #4a3a41; }.panel-heading span { color: #9c8990; font-size: 12px; }
.room-list { display: grid; min-height: 260px; align-content: start; gap: 8px; }.room-list-panel :deep(.el-pagination) { justify-content: center; margin-top: 14px; }
.room-card { display: flex; width: 100%; gap: 11px; padding: 12px; border: 1px solid transparent; border-radius: 15px; color: inherit; text-align: left; background: transparent; cursor: pointer; }.room-card:hover { background: #fff; }.room-card.active { border-color: #efbfd0; background: #fff; box-shadow: 0 8px 22px rgb(111 71 87 / 8%); }.room-card.dissolved { opacity: .62; }
.room-card-avatar, .selected-room-avatar { display: grid; flex: 0 0 auto; overflow: hidden; place-items: center; color: #be5f82; background: linear-gradient(135deg, #ffe2ed, #fff0d9); font-weight: 800; }.room-card-avatar { width: 46px; height: 46px; border-radius: 14px; }.selected-room-avatar { width: 54px; height: 54px; border-radius: 17px; }.room-card-avatar img, .selected-room-avatar img { width: 100%; height: 100%; object-fit: cover; }
.room-card-main { display: flex; min-width: 0; flex: 1; flex-direction: column; gap: 3px; }.room-card-title { display: flex; align-items: center; gap: 6px; }.room-card-title strong { overflow: hidden; color: #48383e; text-overflow: ellipsis; white-space: nowrap; }.room-card-title i { padding: 2px 5px; border-radius: 6px; color: #c55376; background: #ffe6ee; font-size: 9px; font-style: normal; }.room-card-main small { color: #98848c; }.room-card-main em { overflow: hidden; color: #7e6a73; font-size: 12px; font-style: normal; text-overflow: ellipsis; white-space: nowrap; }.room-card-stats { display: flex; gap: 9px; margin-top: 3px; color: #aa969d; font-size: 10px; }
.message-panel { min-width: 0; padding: 18px; background: #fff; }.selected-room-header { display: flex; align-items: center; justify-content: space-between; gap: 16px; }.selected-room-identity { display: flex; min-width: 0; align-items: center; gap: 12px; }.selected-room-identity > div { min-width: 0; }.room-title-line { display: flex; align-items: center; flex-wrap: wrap; gap: 7px; }.room-title-line h2 { margin: 0; color: #3d3036; font-size: 21px; }.selected-room-identity p { margin: 5px 0 0; overflow: hidden; color: #927f87; font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }.selected-room-actions { display: flex; flex: 0 0 auto; gap: 7px; }
.room-facts { display: flex; flex-wrap: wrap; gap: 8px; margin: 17px 0; }.room-facts span { padding: 7px 10px; border-radius: 10px; color: #8a767e; background: #faf5f7; font-size: 11px; }.room-facts b { color: #c05278; font-size: 13px; }
.message-toolbar { grid-template-columns: minmax(180px, 1fr) 145px 135px auto auto; padding: 12px; border-radius: 14px; background: #faf7f8; }.auto-refresh { display: flex; align-items: center; gap: 6px; color: #89757d; font-size: 11px; white-space: nowrap; }
.batch-bar { display: flex; align-items: center; gap: 8px; padding: 10px 13px; margin-top: 10px; border: 1px solid #f0cbd8; border-radius: 13px; background: #fff7fa; }.batch-bar span { flex: 1; color: #7d6871; font-size: 12px; }.batch-bar b { color: #c25279; }
.message-list { display: grid; min-height: 220px; align-content: start; gap: 8px; margin-top: 12px; }.message-card { display: flex; align-items: flex-start; gap: 10px; padding: 13px; border: 1px solid #eee4e7; border-radius: 15px; background: #fff; cursor: pointer; transition: border-color .16s ease, background .16s ease; }.message-card:hover { border-color: #eabecf; background: #fffafb; }.message-card.selected { border-color: #dc91ad; background: #fff5f9; }.message-card.deleted { opacity: .67; background: #f8f6f7; }.message-card > :deep(.el-checkbox) { margin-top: 10px; }.message-main { display: flex; min-width: 0; flex: 1; flex-direction: column; gap: 5px; }.message-meta { display: flex; min-width: 0; align-items: center; flex-wrap: wrap; gap: 6px; }.message-meta strong { color: #48383e; }.message-meta > span { margin-left: auto; color: #9d8991; font-size: 11px; }.message-main p { margin: 0; overflow-wrap: anywhere; color: #56454c; line-height: 1.6; white-space: pre-wrap; }.message-main a { color: #c2547b; font-size: 11px; }.message-actions { display: flex; flex: 0 0 auto; align-items: center; }.message-pagination { justify-content: center; margin-top: 18px; }
.risk-intro { display: flex; gap: 12px; padding: 15px 17px; border: 1px solid #eadff4; border-radius: 16px; background: #faf7ff; }.risk-intro.warning { border-color: #f3d9dc; background: #fff7f8; }.risk-intro.blue { border-color: #dceaf5; background: #f6fbff; }.risk-icon { display: grid; flex: 0 0 40px; width: 40px; height: 40px; place-items: center; border-radius: 13px; color: #866fbd; background: #eee8ff; }.risk-intro.warning .risk-icon { color: #cc5a73; background: #ffe7eb; }.risk-intro.blue .risk-icon { color: #4e84ae; background: #e4f2ff; }.risk-intro strong { color: #483a40; }.risk-intro p { margin: 4px 0 0; color: #89757d; font-size: 12px; line-height: 1.6; }
.keyword-tester { display: grid; grid-template-columns: minmax(200px, .8fr) minmax(280px, 1fr); align-items: center; gap: 18px; padding: 20px; margin-top: 14px; border: 1px solid #f0e2e7; border-radius: 18px; background: linear-gradient(135deg, #fffafd, #fffdf8); }.keyword-tester > div:first-child > span { color: #bf6282; font-size: 9px; font-weight: 800; letter-spacing: .14em; }.keyword-tester h3 { margin: 5px 0; color: #43363c; }.keyword-tester p { margin: 0; color: #95818a; font-size: 12px; }.tester-control { display: flex; gap: 8px; }.tester-result { display: flex; grid-column: 1 / -1; align-items: center; gap: 8px; padding: 10px 12px; border-radius: 11px; color: #4e8b68; background: #edf9f1; font-size: 12px; }.tester-result.matched { color: #c84d6d; background: #fff0f3; }
.keyword-grid { display: grid; min-height: 180px; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 11px; }.keyword-grid > :deep(.el-empty) { grid-column: 1 / -1; }.keyword-card { padding: 16px; border: 1px solid #eee2e6; border-radius: 17px; background: #fff; }.keyword-card.inactive { opacity: .65; background: #f9f7f8; }.keyword-card-head { display: flex; align-items: flex-start; gap: 11px; }.keyword-symbol { display: grid; flex: 0 0 40px; width: 40px; height: 40px; place-items: center; border-radius: 13px; color: #c0567b; background: #ffe5ee; font-size: 17px; font-weight: 800; }.keyword-card-head > div { flex: 1; min-width: 0; }.keyword-card h3 { margin: 0; color: #41343a; }.keyword-card p { margin: 4px 0 0; overflow: hidden; color: #917d85; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }.keyword-card dl { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 7px; margin: 14px 0; }.keyword-card dl div { padding: 9px; border-radius: 10px; background: #faf7f8; }.keyword-card dt { color: #9d8990; font-size: 10px; }.keyword-card dd { margin: 4px 0 0; overflow: hidden; color: #55434b; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }.keyword-actions { display: flex; justify-content: flex-end; padding-top: 9px; border-top: 1px dashed #eadde2; }
.violation-summary { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 9px; margin-top: 14px; }.violation-summary button { display: flex; align-items: center; gap: 9px; padding: 13px; border: 1px solid #eee2e6; border-radius: 14px; color: #88747c; background: #fff; cursor: pointer; }.violation-summary b { color: #c14f72; font-size: 20px; }.violation-list { display: grid; min-height: 180px; gap: 9px; }.violation-card { display: grid; grid-template-columns: minmax(180px, .8fr) minmax(260px, 1.5fr) minmax(150px, .6fr) auto; align-items: center; gap: 14px; padding: 14px 15px; border: 1px solid #eee2e6; border-left: 4px solid #e7b66d; border-radius: 15px; background: #fff; }.violation-card.temp_ban { border-left-color: #e47c8f; }.violation-card.permanent_ban { border-left-color: #bf415e; }.violation-user { display: flex; min-width: 0; align-items: center; gap: 10px; }.violation-user > div { display: flex; min-width: 0; flex-direction: column; gap: 3px; }.violation-user strong { overflow: hidden; color: #49393f; text-overflow: ellipsis; white-space: nowrap; }.violation-user span { overflow: hidden; color: #9a858d; font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }.violation-content { min-width: 0; }.violation-content blockquote { margin: 0 0 5px; overflow-wrap: anywhere; color: #57464d; line-height: 1.55; }.violation-content span { color: #9b858e; font-size: 10px; }.violation-content b { color: #c05074; }.violation-result { display: flex; align-items: flex-start; flex-direction: column; gap: 4px; }.violation-result > span, .violation-result small { color: #927e86; font-size: 10px; }.violation-actions { display: flex; flex-direction: column; align-items: flex-end; }
.ip-grid { display: grid; min-height: 180px; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }.ip-grid > :deep(.el-empty) { grid-column: 1 / -1; }.ip-card { display: flex; align-items: center; gap: 12px; padding: 15px; border: 1px solid #e2ebf1; border-radius: 16px; background: #fbfdff; }.ip-lock { display: grid; flex: 0 0 42px; width: 42px; height: 42px; place-items: center; border-radius: 13px; color: #4e82aa; background: #e5f2fc; }.ip-main { display: flex; min-width: 0; flex: 1; flex-direction: column; gap: 3px; }.ip-main h3 { margin: 0; color: #3e4650; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }.ip-main p { margin: 0; overflow: hidden; color: #70808c; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }.ip-main span, .ip-main small { color: #91a0aa; font-size: 10px; }.risk-pagination { justify-content: center; margin-top: 18px; }
.ip-dialog-note { display: flex; gap: 9px; padding: 11px 12px; margin-bottom: 17px; border-radius: 12px; color: #9b6d3f; background: #fff6e8; font-size: 12px; line-height: 1.5; }.ip-dialog-note :deep(.el-icon) { flex: 0 0 auto; margin-top: 2px; }.full-width { width: 100%; }
:global(.danger-dropdown) { color: var(--el-color-danger) !important; }

@media (max-width: 1180px) {
  .metric-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .room-workspace { grid-template-columns: 290px minmax(0, 1fr); }
  .message-toolbar { grid-template-columns: minmax(180px, 1fr) 130px 120px; }.message-toolbar .auto-refresh { justify-content: flex-start; }
  .violation-card { grid-template-columns: minmax(160px, .8fr) minmax(230px, 1.4fr) minmax(130px, .6fr); }.violation-actions { grid-column: 1 / -1; flex-direction: row; justify-content: flex-end; }
}
@media (max-width: 900px) {
  .room-toolbar { grid-template-columns: 1fr 1fr; }.room-toolbar .el-input { grid-column: 1 / -1; }
  .room-workspace { grid-template-columns: 1fr; }.room-list-panel { max-height: 390px; overflow: auto; border-right: 0; border-bottom: 1px solid #eee3e7; }
  .keyword-grid, .ip-grid { grid-template-columns: 1fr; }.keyword-tester { grid-template-columns: 1fr; }.tester-result { grid-column: auto; }
  .violation-toolbar { grid-template-columns: 1fr 1fr; }.violation-toolbar .el-input { grid-column: 1 / -1; }
}
@media (max-width: 680px) {
  .chat-hero { min-height: auto; padding: 24px; }.hero-orbit { display: none; }
  .metric-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }.metric-card:last-child { grid-column: 1 / -1; }
  .workspace-card { padding-inline: 12px; }.workspace-tabs :deep(.el-tabs__item) { padding: 0 11px; font-size: 12px; }
  .room-toolbar, .risk-toolbar, .violation-toolbar, .ip-toolbar { grid-template-columns: 1fr 1fr; }.room-toolbar .el-input, .risk-toolbar .el-input { grid-column: 1 / -1; }
  .selected-room-header { align-items: flex-start; flex-direction: column; }.selected-room-actions { width: 100%; flex-wrap: wrap; }
  .message-toolbar { grid-template-columns: 1fr 1fr; }.message-toolbar .el-input { grid-column: 1 / -1; }
  .message-card { flex-wrap: wrap; }.message-main { min-width: calc(100% - 92px); }.message-actions { width: 100%; justify-content: flex-end; }.message-meta > span { width: 100%; margin-left: 0; }
  .keyword-card dl { grid-template-columns: 1fr; }.tester-control { flex-direction: column; }
  .violation-summary { grid-template-columns: repeat(2, minmax(0, 1fr)); }.violation-card { grid-template-columns: 1fr; }.violation-actions { grid-column: auto; }
}
</style>
