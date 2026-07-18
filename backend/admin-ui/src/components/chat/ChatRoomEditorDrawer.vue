<script setup lang="ts">
import { Delete, Picture, UploadFilled } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import type { UploadFile } from 'element-plus';
import { computed, onBeforeUnmount, reactive, ref, watch } from 'vue';

import type { ChatRoom, ChatRoomPayload } from '@/types/chat';

const props = defineProps<{
  modelValue: boolean;
  room: ChatRoom | null;
  saving?: boolean;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  submit: [payload: { data: ChatRoomPayload; avatarFile: File | null }];
}>();

const advanced = ref<string[]>([]);
const avatarFile = ref<File | null>(null);
const avatarPreview = ref('');
const customIdEnabled = ref(false);
const form = reactive<ChatRoomPayload>({
  roomId: '',
  name: '',
  avatarUrl: '',
  minLevel: 1,
  category: 'novel',
  isOfficial: false,
  status: 'active',
  botEnabled: true,
});

const editing = computed(() => Boolean(props.room));
const title = computed(() => (editing.value ? '编辑聊天室' : '新建聊天室'));
const visiblePreview = computed(() => avatarPreview.value || form.avatarUrl);

watch(
  () => [props.modelValue, props.room] as const,
  ([open, room]) => {
    if (!open) {
      revokePreview();
      return;
    }
    revokePreview();
    avatarFile.value = null;
    advanced.value = [];
    customIdEnabled.value = false;
    Object.assign(form, {
      roomId: room?.roomId || '',
      name: room?.name || '',
      avatarUrl: room?.avatarUrl || '',
      minLevel: room?.minLevel || 1,
      category: room?.category || 'novel',
      isOfficial: room?.isOfficial || false,
      status: room?.status === 'hidden' ? 'hidden' : 'active',
      botEnabled: room?.botEnabled ?? true,
    });
  },
  { immediate: true },
);

onBeforeUnmount(revokePreview);

function close(): void {
  emit('update:modelValue', false);
}

function selectAvatar(uploadFile: UploadFile): void {
  const file = uploadFile.raw;
  if (!file) return;
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) {
    ElMessage.warning('头像仅支持 JPG、PNG 或 WebP');
    return;
  }
  if (file.size > 5 * 1024 * 1024) {
    ElMessage.warning('头像不能超过 5MB');
    return;
  }
  revokePreview();
  avatarFile.value = file;
  avatarPreview.value = URL.createObjectURL(file);
}

function removeAvatar(): void {
  revokePreview();
  avatarFile.value = null;
  form.avatarUrl = '';
}

function submit(): void {
  const name = form.name.trim();
  if (!name) {
    ElMessage.warning('请填写聊天室名称');
    return;
  }
  const roomId = editing.value
    ? String(form.roomId || '')
    : customIdEnabled.value
      ? String(form.roomId || '').trim()
      : '';
  if (!editing.value && customIdEnabled.value && !/^[A-Za-z0-9][A-Za-z0-9:._-]{1,79}$/.test(roomId)) {
    ElMessage.warning('自定义 ID 需以字母或数字开头，只能包含字母、数字、点、冒号、下划线和短横线');
    return;
  }
  emit('submit', {
    data: {
      roomId,
      name,
      avatarUrl: form.avatarUrl,
      minLevel: form.minLevel,
      category: form.category,
      isOfficial: form.isOfficial,
      status: form.status,
      botEnabled: form.botEnabled,
    },
    avatarFile: avatarFile.value,
  });
}

function revokePreview(): void {
  if (avatarPreview.value) URL.revokeObjectURL(avatarPreview.value);
  avatarPreview.value = '';
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    :title="title"
    size="min(560px, 94vw)"
    class="room-editor-drawer"
    @close="close"
  >
    <div class="editor-intro">
      <span class="intro-icon"><Picture /></span>
      <div>
        <strong>{{ editing ? '调整房间展示与准入规则' : '创建一个可直接使用的社区房间' }}</strong>
        <p>头像通过本地图片上传；高级配置默认收起，常用字段保持在第一屏。</p>
      </div>
    </div>

    <ElForm label-position="top" class="room-form">
      <ElFormItem label="聊天室名称" required>
        <ElInput v-model="form.name" maxlength="40" show-word-limit placeholder="例如：樱花小说茶话会" />
      </ElFormItem>

      <ElFormItem label="内容分类" required>
        <ElSelect v-model="form.category" class="full-width">
          <ElOption label="小说" value="novel" />
          <ElOption label="动漫" value="anime" />
          <ElOption label="漫画" value="manga" />
        </ElSelect>
      </ElFormItem>

      <ElFormItem label="房间头像">
        <div class="avatar-upload-row">
          <ElUpload
            drag
            action="#"
            accept="image/jpeg,image/png,image/webp"
            :auto-upload="false"
            :show-file-list="false"
            :on-change="selectAvatar"
            class="avatar-uploader"
          >
            <img v-if="visiblePreview" :src="visiblePreview" alt="聊天室头像预览" class="avatar-preview" />
            <div v-else class="avatar-empty">
              <ElIcon><UploadFilled /></ElIcon>
              <span>点击或拖入图片</span>
            </div>
          </ElUpload>
          <div class="upload-hint">
            <strong>JPG / PNG / WebP</strong>
            <span>最大 5MB，建议使用 1:1 图片</span>
            <ElButton v-if="visiblePreview" text type="danger" :icon="Delete" @click="removeAvatar">
              移除头像
            </ElButton>
          </div>
        </div>
      </ElFormItem>

      <ElCollapse v-model="advanced" class="advanced-collapse">
        <ElCollapseItem name="access" title="准入、状态与机器人（高级）">
          <div class="two-column-form">
            <ElFormItem label="最低进入等级">
              <ElSelect v-model="form.minLevel" class="full-width">
                <ElOption v-for="level in 7" :key="level" :label="`Lv.${level}`" :value="level" />
              </ElSelect>
            </ElFormItem>
            <ElFormItem v-if="editing" label="房间状态">
              <ElSelect v-model="form.status" class="full-width">
                <ElOption label="开放中" value="active" />
                <ElOption label="隐藏（用户不可进入）" value="hidden" />
              </ElSelect>
            </ElFormItem>
          </div>
          <div class="switch-row">
            <div>
              <strong>官方房间</strong>
              <span>在客户端优先展示并标记为官方</span>
            </div>
            <ElSwitch v-model="form.isOfficial" />
          </div>
          <div class="switch-row">
            <div>
              <strong>小樱机器人</strong>
              <span>开启后机器人加入房间并响应符合条件的消息</span>
            </div>
            <ElSwitch v-model="form.botEnabled" />
          </div>
        </ElCollapseItem>

        <ElCollapseItem v-if="!editing" name="identifier" title="自定义房间 ID（一般无需设置）">
          <div class="switch-row compact">
            <div>
              <strong>使用自定义 ID</strong>
              <span>留给固定活动入口或已有客户端约定；普通房间自动生成更安全。</span>
            </div>
            <ElSwitch v-model="customIdEnabled" />
          </div>
          <ElInput
            v-if="customIdEnabled"
            v-model="form.roomId"
            maxlength="80"
            placeholder="例如 novel-sakura-club"
          />
        </ElCollapseItem>

        <ElCollapseItem v-else name="identifier" title="系统标识">
          <ElInput :model-value="form.roomId" disabled />
          <p class="field-note">房间 ID 已被客户端和消息记录引用，创建后不能修改。</p>
        </ElCollapseItem>
      </ElCollapse>
    </ElForm>

    <template #footer>
      <div class="drawer-actions">
        <ElButton @click="close">取消</ElButton>
        <ElButton type="primary" :loading="saving" @click="submit">
          {{ editing ? '保存房间' : '创建房间' }}
        </ElButton>
      </div>
    </template>
  </ElDrawer>
</template>

<style scoped>
.editor-intro {
  display: flex;
  gap: 14px;
  padding: 16px;
  margin-bottom: 22px;
  border: 1px solid #f7dce6;
  border-radius: 16px;
  background: linear-gradient(135deg, #fff7fa, #fffdf7);
}

.intro-icon {
  display: grid;
  flex: 0 0 42px;
  width: 42px;
  height: 42px;
  place-items: center;
  color: #d65f8c;
  border-radius: 13px;
  background: #ffe5ef;
}

.intro-icon :deep(svg) { width: 21px; }
.editor-intro strong { color: #352b31; }
.editor-intro p { margin: 5px 0 0; color: #8a747d; line-height: 1.6; font-size: 13px; }
.full-width { width: 100%; }

.avatar-upload-row { display: flex; align-items: center; gap: 18px; width: 100%; }
.avatar-uploader { width: 132px; }
.avatar-uploader :deep(.el-upload-dragger) {
  width: 132px;
  height: 132px;
  padding: 0;
  overflow: hidden;
  border-radius: 22px;
  border-color: #efc7d6;
  background: #fff9fb;
}
.avatar-preview { width: 100%; height: 100%; object-fit: cover; }
.avatar-empty { display: grid; height: 100%; place-content: center; gap: 8px; color: #b56b87; font-size: 12px; }
.avatar-empty :deep(.el-icon) { margin: auto; font-size: 27px; }
.upload-hint { display: flex; flex-direction: column; align-items: flex-start; gap: 6px; color: #947d86; font-size: 12px; }
.upload-hint strong { color: #57464d; }

.advanced-collapse { margin-top: 8px; border-top: 1px solid #f1e4e8; }
.advanced-collapse :deep(.el-collapse-item__header) { font-weight: 650; color: #5f4b54; }
.two-column-form { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
.switch-row { display: flex; align-items: center; justify-content: space-between; gap: 18px; padding: 13px 0; border-top: 1px dashed #f0e0e5; }
.switch-row.compact { border-top: 0; padding-top: 0; }
.switch-row > div { display: flex; flex-direction: column; gap: 4px; }
.switch-row strong { color: #493a40; font-size: 14px; }
.switch-row span, .field-note { color: #947f87; font-size: 12px; line-height: 1.55; }
.field-note { margin: 8px 0 0; }
.drawer-actions { display: flex; justify-content: flex-end; gap: 10px; }

@media (max-width: 560px) {
  .avatar-upload-row { align-items: flex-start; }
  .two-column-form { grid-template-columns: 1fr; gap: 0; }
}
</style>
