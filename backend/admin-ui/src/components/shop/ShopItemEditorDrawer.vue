<script setup lang="ts">
import {
  Coin,
  InfoFilled,
  Lock,
  Picture,
  Refresh,
  UploadFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import type { UploadRequestOptions } from 'element-plus';
import { computed, reactive, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import { createShopItem, updateShopItem, uploadShopPreview } from '@/services/shop';
import type { AdminShopItem, ShopCatalogItem } from '@/types/shop';
import { shopIdentityLocked, shopStatusLabel } from '@/utils/shop';

type UploadAjaxError = Parameters<UploadRequestOptions['onError']>[0];

const props = defineProps<{
  modelValue: boolean;
  item: AdminShopItem | null;
  catalog: ShopCatalogItem[];
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [item: AdminShopItem];
  reload: [];
}>();

const saving = ref(false);
const uploading = ref(false);
const openSections = ref(['basics', 'runtime', 'release']);
const form = reactive({
  name: '',
  description: '',
  priceCoins: 0,
  itemType: '',
  assetValue: '',
  minLevel: 1,
  sortOrder: 0,
  previewUrl: '',
  changeNote: '',
});

const editing = computed(() => Boolean(props.item));
const archived = computed(() => props.item?.status === 'archived');
const identityLocked = computed(() => shopIdentityLocked(props.item));
const selectedType = computed(() =>
  props.catalog.find((item) => item.type === form.itemType) || null,
);
const presets = computed(() => selectedType.value?.presets || []);

watch(
  () => props.modelValue,
  (open) => {
    if (open) resetForm();
  },
);

function resetForm(): void {
  const firstType = props.catalog[0];
  Object.assign(form, {
    name: props.item?.name || '',
    description: props.item?.description || '',
    priceCoins: props.item?.priceCoins ?? 100,
    itemType: props.item?.itemType || firstType?.type || '',
    assetValue: props.item?.assetValue || firstType?.presets[0]?.value || '',
    minLevel: props.item?.minLevel ?? 1,
    sortOrder: props.item?.sortOrder ?? 0,
    previewUrl: props.item?.previewUrl || '',
    changeNote: '',
  });
  openSections.value = ['basics', 'runtime', 'release'];
}

function changeType(value: string): void {
  const type = props.catalog.find((item) => item.type === value);
  form.assetValue = type?.presets[0]?.value || '';
}

async function handlePreviewUpload(options: UploadRequestOptions): Promise<void> {
  const file = options.file;
  if (file.size > 3 * 1024 * 1024) {
    const error = new Error('商品预览图不能超过 3MB');
    options.onError(asUploadError(error));
    ElMessage.warning(error.message);
    return;
  }
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) {
    const error = new Error('商品预览图仅支持 JPG、PNG 或 WebP');
    options.onError(asUploadError(error));
    ElMessage.warning(error.message);
    return;
  }
  uploading.value = true;
  try {
    const result = await uploadShopPreview(file);
    form.previewUrl = result.url;
    options.onSuccess(result);
    ElMessage.success('预览图已上传，保存商品后正式生效');
  } catch (error) {
    options.onError(asUploadError(error));
    ElMessage.error(errorMessage(error, '预览图上传失败'));
  } finally {
    uploading.value = false;
  }
}

async function save(): Promise<void> {
  const validation = validateForm();
  if (validation) {
    ElMessage.warning(validation);
    return;
  }
  saving.value = true;
  try {
    const payload = {
      name: form.name.trim(),
      description: form.description.trim(),
      priceCoins: form.priceCoins,
      itemType: form.itemType,
      minLevel: form.minLevel,
      assetValue: form.assetValue,
      previewUrl: form.previewUrl,
      sortOrder: form.sortOrder,
      changeNote: form.changeNote.trim(),
    };
    const result = props.item
      ? await updateShopItem(props.item.id, {
        ...payload,
        expectedRevision: props.item.revision,
      })
      : await createShopItem(payload);
    ElMessage.success(props.item ? '商品修改已保存并写入变更记录' : '商品草稿已创建');
    emit('saved', result.item);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(errorMessage(error, '商品保存失败'));
    if (error instanceof ApiError && error.code === 'shop_item_revision_conflict') {
      emit('reload');
    }
  } finally {
    saving.value = false;
  }
}

function validateForm(): string {
  if (archived.value) return '归档商品需要先恢复为草稿';
  if (!form.name.trim()) return '请填写商品名称';
  if (!form.description.trim()) return '请填写用户能看懂的商品说明';
  if (!form.itemType) return '请选择商品类型';
  if (!form.assetValue) return '请选择客户端运行时预设';
  if (editing.value && !form.changeNote.trim()) return '请填写本次修改原因';
  return '';
}

function asUploadError(error: unknown): UploadAjaxError {
  return error as UploadAjaxError;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(720px, 97vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="editor-heading">
        <span>{{ editing ? 'PRODUCT REVISION' : 'NEW PRODUCT DRAFT' }}</span>
        <h2>{{ editing ? item?.name : '创建商品草稿' }}</h2>
        <p v-if="item">{{ shopStatusLabel(item.status) }} · 版本 {{ item.revision }} · {{ item.holderCount }} 位持有人</p>
        <p v-else>先完成可验证的商品配置，保存后再单独上架。</p>
      </div>
    </template>

    <div class="editor-body">
      <ElAlert
        v-if="archived"
        title="归档商品只读"
        description="请在商品列表中先恢复为草稿，再进行编辑。"
        type="warning"
        :closable="false"
        show-icon
      />

      <ElCollapse v-model="openSections" class="editor-collapse">
        <ElCollapseItem name="basics">
          <template #title>
            <span class="collapse-heading"><ElIcon><InfoFilled /></ElIcon>基础信息与商品预览</span>
          </template>
          <div class="section-grid">
            <ElFormItem class="wide" label="商品名称" required>
              <ElInput v-model="form.name" maxlength="80" show-word-limit :disabled="archived" placeholder="用户在商店中看到的名称" />
            </ElFormItem>
            <ElFormItem class="wide" label="商品说明" required>
              <ElInput v-model="form.description" type="textarea" :rows="3" maxlength="500" show-word-limit :disabled="archived" placeholder="说明商品效果与适用位置，不填写内部实现细节" />
            </ElFormItem>
            <div class="preview-field wide">
              <div class="preview-frame" :class="{ empty: !form.previewUrl }">
                <img v-if="form.previewUrl" :src="form.previewUrl" alt="商品预览" />
                <span v-else><ElIcon><Picture /></ElIcon><b>尚未上传预览图</b></span>
              </div>
              <div class="preview-actions">
                <strong>商品预览图</strong>
                <p>JPG、PNG 或 WebP，最大 3MB。图片会上传到站内存储，不接受 URL。</p>
                <ElUpload
                  accept="image/jpeg,image/png,image/webp"
                  :show-file-list="false"
                  :http-request="handlePreviewUpload"
                  :disabled="archived || uploading"
                >
                  <ElButton :icon="UploadFilled" :loading="uploading" :disabled="archived">
                    {{ form.previewUrl ? '替换图片' : '上传图片' }}
                  </ElButton>
                </ElUpload>
              </div>
            </div>
          </div>
        </ElCollapseItem>

        <ElCollapseItem name="runtime">
          <template #title>
            <span class="collapse-heading"><ElIcon><Lock /></ElIcon>客户端能力与兑换规则</span>
          </template>
          <ElAlert
            v-if="identityLocked"
            title="商品身份已锁定"
            :description="item?.holderCount || item?.equipmentCount ? '已有用户持有或装备该商品，类型与运行时预设不能再改变。' : '销售中商品需要先停止销售，才能改变类型与运行时预设。'"
            type="info"
            :closable="false"
            show-icon
          />
          <div class="section-grid runtime-grid">
            <ElFormItem label="商品类型" required>
              <ElSelect v-model="form.itemType" :disabled="archived || identityLocked" placeholder="选择客户端能力" @change="changeType">
                <ElOption v-for="option in catalog" :key="option.type" :label="option.label" :value="option.type">
                  <span>{{ option.label }}</span>
                  <small>{{ option.equipSlot ? '可装备' : '权益解锁' }}</small>
                </ElOption>
              </ElSelect>
            </ElFormItem>
            <ElFormItem label="运行时预设" required>
              <ElSelect v-model="form.assetValue" :disabled="archived || identityLocked" placeholder="选择 App 已实现的效果">
                <ElOption v-for="preset in presets" :key="preset.value" :label="preset.label" :value="preset.value">
                  <span>{{ preset.label }}</span><small>{{ preset.value }}</small>
                </ElOption>
              </ElSelect>
            </ElFormItem>
            <ElFormItem label="兑换价格">
              <ElInputNumber v-model="form.priceCoins" :min="0" :max="1000000" :step="10" controls-position="right" :disabled="archived" />
              <span class="field-suffix"><ElIcon><Coin /></ElIcon>樱花币</span>
            </ElFormItem>
            <ElFormItem label="最低等级">
              <ElSelect v-model="form.minLevel" :disabled="archived">
                <ElOption v-for="level in 7" :key="level" :label="`Lv.${level}`" :value="level" />
              </ElSelect>
            </ElFormItem>
            <ElFormItem label="商店排序">
              <ElInputNumber v-model="form.sortOrder" :min="0" :max="100000" :step="10" controls-position="right" :disabled="archived" />
              <span class="field-note">数值越小越靠前</span>
            </ElFormItem>
          </div>
        </ElCollapseItem>

        <ElCollapseItem name="release">
          <template #title>
            <span class="collapse-heading"><ElIcon><Refresh /></ElIcon>保存与上架检查</span>
          </template>
          <div class="release-checks">
            <span :class="{ ready: form.name.trim() && form.description.trim() }"><i />名称与说明完整</span>
            <span :class="{ ready: form.itemType && form.assetValue }"><i />能力预设有效</span>
            <span :class="{ ready: form.previewUrl }"><i />已上传真实预览图</span>
          </div>
          <ElFormItem v-if="editing" label="修改原因" required class="change-note">
            <ElInput v-model="form.changeNote" type="textarea" :rows="3" maxlength="300" show-word-limit :disabled="archived" placeholder="说明为何修改，后续会和修改前后内容一起保留" />
          </ElFormItem>
          <p class="release-note">保存只更新草稿或当前商品，不会自动上架。上架操作需要在列表中单独确认并填写原因。</p>
        </ElCollapseItem>
      </ElCollapse>
    </div>

    <template #footer>
      <div class="drawer-footer">
        <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
        <ElButton type="primary" :loading="saving" :disabled="archived || uploading" @click="save">
          {{ editing ? '保存修改' : '创建草稿' }}
        </ElButton>
      </div>
    </template>
  </ElDrawer>
</template>

<style scoped>
.editor-heading span { color: var(--sakura-600); font-size: 11px; font-weight: 800; letter-spacing: .08em; }
.editor-heading h2 { margin: 5px 0 3px; color: var(--ink-900); font-size: 20px; letter-spacing: 0; }
.editor-heading p { margin: 0; color: var(--ink-500); font-size: 12px; }
.editor-body { display: grid; gap: 14px; }
.editor-collapse { border-top: 0; }
.collapse-heading { display: inline-flex; align-items: center; gap: 8px; color: var(--ink-900); font-weight: 750; }
.section-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 2px 16px; padding: 6px 2px 12px; }
.section-grid .wide { grid-column: 1 / -1; }
.section-grid :deep(.el-select), .section-grid :deep(.el-input-number) { width: 100%; }
.section-grid :deep(.el-form-item__label) { color: var(--ink-700); font-weight: 650; }
.preview-field { display: grid; grid-template-columns: 150px minmax(0, 1fr); gap: 16px; align-items: center; padding: 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.preview-frame { width: 150px; aspect-ratio: 4 / 3; overflow: hidden; border-radius: 7px; background: white; }
.preview-frame img { width: 100%; height: 100%; object-fit: cover; display: block; }
.preview-frame.empty { display: grid; place-items: center; border: 1px dashed var(--ink-300); color: var(--ink-500); }
.preview-frame.empty span { display: grid; justify-items: center; gap: 7px; font-size: 11px; }
.preview-frame.empty .el-icon { font-size: 28px; }
.preview-actions strong { color: var(--ink-900); font-size: 14px; }
.preview-actions p { margin: 5px 0 12px; color: var(--ink-500); font-size: 12px; line-height: 1.55; }
.runtime-grid { margin-top: 12px; }
.runtime-grid :deep(.el-select-dropdown__item) small { margin-left: auto; }
.field-suffix { display: inline-flex; align-items: center; gap: 4px; margin-top: 6px; color: #9a6517; font-size: 11px; }
.field-note { margin-top: 6px; color: var(--ink-500); font-size: 11px; }
.release-checks { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; margin: 5px 0 16px; }
.release-checks span { display: flex; align-items: center; gap: 8px; min-height: 42px; padding: 9px 10px; border: 1px solid var(--line); border-radius: 7px; color: var(--ink-500); background: var(--surface-muted); font-size: 12px; }
.release-checks i { width: 8px; height: 8px; flex: 0 0 8px; border-radius: 50%; background: var(--ink-300); }
.release-checks span.ready { color: #2c7659; border-color: #b9dfcf; background: #f2fbf7; }
.release-checks span.ready i { background: #43a77d; }
.change-note { margin-bottom: 8px; }
.release-note { margin: 0 0 12px; color: var(--ink-500); font-size: 12px; line-height: 1.6; }
.drawer-footer { display: flex; justify-content: flex-end; gap: 10px; }
@media (max-width: 640px) {
  .section-grid { grid-template-columns: 1fr; }
  .section-grid .wide { grid-column: auto; }
  .preview-field { grid-template-columns: 1fr; }
  .preview-frame { width: 100%; max-height: 210px; }
  .release-checks { grid-template-columns: 1fr; }
}
</style>
