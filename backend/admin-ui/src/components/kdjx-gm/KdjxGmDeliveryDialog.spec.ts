import { flushPromises, mount } from '@vue/test-utils';
import { defineComponent, h } from 'vue';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  KdjxGmCatalogItem,
  KdjxGmDelivery,
  KdjxGmDeliveryStatus,
  KdjxGmPlayer,
} from '@/types/kdjx-gm';

import KdjxGmDeliveryDialog from './KdjxGmDeliveryDialog.vue';

const serviceMocks = vi.hoisted(() => ({
  createKdjxGmDelivery: vi.fn(),
}));
const messageMocks = vi.hoisted(() => ({
  success: vi.fn(),
  warning: vi.fn(),
  error: vi.fn(),
  confirm: vi.fn(),
}));

vi.mock('@/services/kdjx-gm', () => serviceMocks);
vi.mock('element-plus', async () => {
  const actual = await vi.importActual<typeof import('element-plus')>('element-plus');
  return {
    ...actual,
    ElMessage: {
      success: messageMocks.success,
      warning: messageMocks.warning,
      error: messageMocks.error,
    },
    ElMessageBox: { confirm: messageMocks.confirm },
  };
});

const DialogStub = defineComponent({
  name: 'ElDialog',
  inheritAttrs: false,
  props: { modelValue: Boolean },
  setup(props, { slots }) {
    return () => props.modelValue
      ? h('div', { class: 'dialog-stub' }, [
          h('main', slots.default?.()),
          h('footer', slots.footer?.()),
        ])
      : null;
  },
});

const SelectStub = defineComponent({
  name: 'ElSelectV2',
  inheritAttrs: false,
  props: {
    modelValue: String,
    options: { type: Array, default: () => [] },
  },
  emits: ['update:modelValue'],
  setup(props, { attrs, emit }) {
    return () => h(
      'select',
      {
        ...attrs,
        class: ['item-select-stub', attrs.class],
        value: props.modelValue,
        onChange: (event: Event) => emit(
          'update:modelValue',
          (event.target as HTMLSelectElement).value,
        ),
      },
      (props.options as Array<{ value: string; label: string }>).map(
        (option) => h('option', { value: option.value }, option.label),
      ),
    );
  },
});

const InputNumberStub = defineComponent({
  name: 'ElInputNumber',
  inheritAttrs: false,
  props: { modelValue: Number },
  emits: ['update:modelValue'],
  setup(props, { attrs, emit }) {
    return () => h('input', {
      ...attrs,
      class: 'quantity-stub',
      type: 'number',
      value: props.modelValue,
      onInput: (event: Event) => emit(
        'update:modelValue',
        Number((event.target as HTMLInputElement).value),
      ),
    });
  },
});

const InputStub = defineComponent({
  name: 'ElInput',
  inheritAttrs: false,
  props: { modelValue: String, type: String },
  emits: ['update:modelValue'],
  setup(props, { attrs, emit }) {
    return () => h(props.type === 'textarea' ? 'textarea' : 'input', {
      ...attrs,
      class: 'reason-stub',
      value: props.modelValue,
      onInput: (event: Event) => emit(
        'update:modelValue',
        (event.target as HTMLInputElement).value,
      ),
    });
  },
});

describe('KdjxGmDeliveryDialog', () => {
  afterEach(() => {
    vi.resetAllMocks();
    document.body.innerHTML = '';
  });

  it('reuses the same UUID after a transport failure and only submits a catalog item', async () => {
    const player = samplePlayer();
    const delivery = sampleDelivery(player, 'succeeded');
    serviceMocks.createKdjxGmDelivery
      .mockRejectedValueOnce(new Error('网络中断'))
      .mockResolvedValueOnce({ ok: true, idempotent: false, delivery });
    messageMocks.confirm.mockResolvedValue('confirm');

    const wrapper = await mountOpenDialog({ player });

    expect(wrapper.text()).toContain('游戏邮件附件');
    expect(wrapper.text()).not.toContain('直接到账');
    await fillValidForm(wrapper);

    await sendButton(wrapper).trigger('click');
    await flushPromises();
    await sendButton(wrapper).trigger('click');
    await flushPromises();

    expect(serviceMocks.createKdjxGmDelivery).toHaveBeenCalledTimes(2);
    const firstPayload = serviceMocks.createKdjxGmDelivery.mock.calls[0][1];
    const secondPayload = serviceMocks.createKdjxGmDelivery.mock.calls[1][1];
    expect(firstPayload).toEqual(expect.objectContaining({
      deliveryType: 'mail',
      itemId: '19',
      quantity: 2,
      expectedRoleId: player.lastRoleId,
      expectedServerKey: player.lastServerKey,
      expectedLinkUpdatedAt: player.linkedUpdatedAt,
      reason: '玩家工单核实补发',
    }));
    expect(firstPayload.requestId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    expect(secondPayload.requestId).toBe(firstPayload.requestId);
    expect(wrapper.emitted('update:modelValue')).toContainEqual([false]);
    wrapper.unmount();
  });

  it('rejects an item id that was not selected from the server catalog', async () => {
    const wrapper = await mountOpenDialog();
    wrapper.findComponent(SelectStub).vm.$emit('update:modelValue', 'not-in-catalog');
    await wrapper.find('.reason-stub').setValue('玩家工单核实补发');
    await flushPromises();

    await sendButton(wrapper).trigger('click');
    await flushPromises();

    expect(messageMocks.warning).toHaveBeenCalledWith('请从物品目录中选择要发放的物品');
    expect(messageMocks.confirm).not.toHaveBeenCalled();
    expect(serviceMocks.createKdjxGmDelivery).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it('only exposes mail-compatible catalog items in the dropdown', async () => {
    const directOnlyItem = sampleCatalogItem({
      id: '20',
      name: '仅直发测试物品',
      deliveryTypes: ['direct'],
    });
    const wrapper = await mountOpenDialog({
      catalog: [sampleCatalogItem(), directOnlyItem],
    });

    expect(wrapper.findComponent(SelectStub).props('options')).toEqual([
      expect.objectContaining({ value: '19' }),
    ]);
    wrapper.findComponent(SelectStub).vm.$emit('update:modelValue', directOnlyItem.id);
    await wrapper.find('.reason-stub').setValue('玩家工单核实补发');
    await flushPromises();
    await sendButton(wrapper).trigger('click');

    expect(messageMocks.warning).toHaveBeenCalledWith('请从物品目录中选择要发放的物品');
    expect(serviceMocks.createKdjxGmDelivery).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it('accepts a catalog-backed resource quantity above 9999', async () => {
    const player = samplePlayer();
    serviceMocks.createKdjxGmDelivery.mockResolvedValue({
      ok: true,
      idempotent: false,
      delivery: sampleDelivery(player, 'succeeded'),
    });
    messageMocks.confirm.mockResolvedValue('confirm');
    const wrapper = await mountOpenDialog({
      player,
      catalog: [sampleCatalogItem({ id: '401', maxQuantity: 2_147_483_647 })],
    });

    await wrapper.find('.item-select-stub').setValue('401');
    await wrapper.find('.quantity-stub').setValue('900000000');
    await wrapper.find('.reason-stub').setValue('大型活动批量补发');
    await flushPromises();

    expect(wrapper.find('.quantity-stub').attributes('max')).toBe('2147483647');
    await sendButton(wrapper).trigger('click');
    await flushPromises();
    expect(serviceMocks.createKdjxGmDelivery).toHaveBeenCalledWith(
      player.userId,
      expect.objectContaining({ itemId: '401', quantity: 900000000 }),
    );
    wrapper.unmount();
  });

  it('blocks delivery when the player game identity is incomplete', async () => {
    const player = samplePlayer({
      canDeliverItems: false,
      deliveryBlockCode: 'kdjx_player_identity_incomplete',
    });
    const wrapper = await mountOpenDialog({ player });

    expect(wrapper.text()).toContain('玩家的游戏身份关联不完整');
    expect(sendButton(wrapper).attributes('disabled')).toBeDefined();
    expect(messageMocks.confirm).not.toHaveBeenCalled();
    expect(serviceMocks.createKdjxGmDelivery).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it('does not send when the operator cancels the second confirmation', async () => {
    messageMocks.confirm.mockRejectedValue('cancel');
    const wrapper = await mountOpenDialog();
    await fillValidForm(wrapper);

    await sendButton(wrapper).trigger('click');
    await flushPromises();

    expect(messageMocks.confirm).toHaveBeenCalledTimes(1);
    expect(serviceMocks.createKdjxGmDelivery).not.toHaveBeenCalled();
    expect(messageMocks.error).not.toHaveBeenCalled();
    expect(wrapper.emitted('update:modelValue')).toBeUndefined();
    wrapper.unmount();
  });

  it.each(['failed', 'unknown'] as const)(
    'keeps the same UUID and dialog open after a %s delivery result',
    async (status) => {
      const player = samplePlayer();
      const delivery = sampleDelivery(player, status);
      serviceMocks.createKdjxGmDelivery.mockResolvedValue({
        ok: false,
        idempotent: false,
        delivery,
      });
      messageMocks.confirm.mockResolvedValue('confirm');
      const wrapper = await mountOpenDialog({ player });
      await fillValidForm(wrapper);

      await sendButton(wrapper).trigger('click');
      await flushPromises();
      await sendButton(wrapper).trigger('click');
      await flushPromises();

      expect(serviceMocks.createKdjxGmDelivery).toHaveBeenCalledTimes(2);
      const firstRequestId = serviceMocks.createKdjxGmDelivery.mock.calls[0][1].requestId;
      const secondRequestId = serviceMocks.createKdjxGmDelivery.mock.calls[1][1].requestId;
      expect(secondRequestId).toBe(firstRequestId);
      expect(wrapper.emitted('update:modelValue')).toBeUndefined();
      if (status === 'failed') {
        expect(messageMocks.error).toHaveBeenCalledWith(expect.stringContaining('游戏服已拒绝'));
      } else {
        expect(messageMocks.warning).toHaveBeenCalledWith(expect.stringContaining('请勿新建请求'));
      }
      wrapper.unmount();
    },
  );
});

async function mountOpenDialog(options: {
  player?: KdjxGmPlayer;
  catalog?: KdjxGmCatalogItem[];
} = {}) {
  const wrapper = mount(KdjxGmDeliveryDialog, {
    props: {
      modelValue: false,
      player: options.player || samplePlayer(),
      catalog: options.catalog || [sampleCatalogItem()],
      catalogLoading: false,
    },
    global: {
      stubs: {
        ElDialog: DialogStub,
        ElSelectV2: SelectStub,
        ElInputNumber: InputNumberStub,
        ElInput: InputStub,
      },
    },
    attachTo: document.body,
  });
  await wrapper.setProps({ modelValue: true });
  await flushPromises();
  return wrapper;
}

async function fillValidForm(wrapper: ReturnType<typeof mount>) {
  await wrapper.find('.item-select-stub').setValue('19');
  await wrapper.find('.quantity-stub').setValue('2');
  await wrapper.find('.reason-stub').setValue('玩家工单核实补发');
}

function sendButton(wrapper: ReturnType<typeof mount>) {
  const button = wrapper.findAll('button').find((candidate) =>
    candidate.text().includes('下一步确认'),
  );
  if (!button) throw new Error('发放确认按钮未渲染');
  return button;
}

function sampleCatalogItem(overrides: Partial<KdjxGmCatalogItem> = {}): KdjxGmCatalogItem {
  return {
    id: '19',
    name: '测试仙剑',
    description: '活动奖励用的限定武器',
    type: '16',
    quality: '5',
    maxQuantity: 9,
    deliveryTypes: ['mail'],
    ...overrides,
  };
}

function sampleDelivery(
  player: KdjxGmPlayer,
  status: KdjxGmDeliveryStatus,
): KdjxGmDelivery {
  return {
    id: 1,
    requestId: '',
    userId: player.userId,
    email: player.email,
    nickname: player.nickname,
    adminUserId: 9,
    adminEmail: 'admin@example.com',
    adminNickname: '管理员',
    deliveryType: 'mail',
    roleId: player.lastRoleId,
    serverKey: player.lastServerKey,
    itemId: '19',
    itemName: '测试仙剑',
    itemType: '武器',
    itemQuality: '橙色',
    quantity: 2,
    reason: '玩家工单核实补发',
    status,
    remoteReference: status === 'succeeded' ? 'mail-1' : '',
    errorCode: status === 'failed' ? 'remote_rejected' : '',
    createdAt: '2026-07-28 10:00:00',
    updatedAt: '2026-07-28 10:00:00',
    completedAt: status === 'unknown' ? '' : '2026-07-28 10:00:00',
  };
}

function samplePlayer(overrides: Partial<KdjxGmPlayer> = {}): KdjxGmPlayer {
  return {
    userId: 42,
    email: 'player@example.com',
    nickname: '测试玩家',
    userStatus: 'active',
    userRole: 'user',
    sakuraCoins: 200,
    userCreatedAt: '2026-07-01 10:00:00',
    lastLoginAt: '2026-07-28 09:00:00',
    gameOpenId: 'sakura_test_player_0042',
    gameAccountId: '64a000000000000000000042',
    lastRoleId: '64b000000000000000000042',
    lastServerKey: 'game.cn.1',
    linkedAt: '2026-07-20 10:00:00',
    linkedUpdatedAt: '2026-07-28 09:30:00',
    canDeliverItems: true,
    deliveryBlockCode: '',
    activeGameSessions: 1,
    paymentCount: 0,
    lastPaymentStatus: '',
    lastPaymentAt: '',
    ...overrides,
  };
}
