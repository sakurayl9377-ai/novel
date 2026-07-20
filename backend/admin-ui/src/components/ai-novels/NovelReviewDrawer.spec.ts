import { flushPromises, mount } from '@vue/test-utils';
import { defineComponent, h } from 'vue';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { AiChapterReviewDetail, AiMetadataReviewDetail } from '@/types/ai-novel';

import NovelReviewDrawer from './NovelReviewDrawer.vue';

const serviceMocks = vi.hoisted(() => ({
  getReviewChapter: vi.fn(),
  getReviewMetadata: vi.fn(),
  getReviewNovel: vi.fn(),
  reviewChapter: vi.fn(),
  reviewMetadata: vi.fn(),
  reviewNovel: vi.fn(),
}));

vi.mock('@/services/ai-novels', () => serviceMocks);

const DrawerStub = defineComponent({
  name: 'ElDrawer',
  inheritAttrs: false,
  props: { modelValue: Boolean },
  setup(props, { slots }) {
    return () => props.modelValue
      ? h('div', { class: 'drawer-stub' }, [
          h('header', slots.header?.()),
          h('main', slots.default?.()),
          h('footer', slots.footer?.()),
        ])
      : null;
  },
});

describe('NovelReviewDrawer', () => {
  afterEach(() => {
    vi.clearAllMocks();
    document.body.innerHTML = '';
  });

  it('compares the online chapter with its pending revision', async () => {
    serviceMocks.getReviewChapter.mockResolvedValue(chapterReviewDetail('update'));
    const wrapper = mount(NovelReviewDrawer, {
      props: {
        modelValue: false,
        target: { kind: 'chapter', id: 31 },
      },
      global: { stubs: { ElDrawer: DrawerStub } },
      attachTo: document.body,
    });
    await wrapper.setProps({ modelValue: true });
    await flushPromises();

    expect(wrapper.text()).toContain('修改已发布章节');
    expect(wrapper.text()).toContain('线上版本与修改稿对照');
    expect(wrapper.text()).toContain('当前线上正文');
    expect(wrapper.text()).toContain('待审修改正文');
    expect(wrapper.text()).toContain('通过并更新');
    wrapper.unmount();
  });

  it('keeps new chapter review as a single publishable draft', async () => {
    serviceMocks.getReviewChapter.mockResolvedValue(chapterReviewDetail('add'));
    const wrapper = mount(NovelReviewDrawer, {
      props: {
        modelValue: false,
        target: { kind: 'chapter', id: 31 },
      },
      global: { stubs: { ElDrawer: DrawerStub } },
      attachTo: document.body,
    });
    await wrapper.setProps({ modelValue: true });
    await flushPromises();

    expect(wrapper.text()).toContain('新增连载章节');
    expect(wrapper.text()).toContain('待审修改正文');
    expect(wrapper.text()).not.toContain('线上版本与修改稿对照');
    expect(wrapper.text()).toContain('通过并发布');
    wrapper.unmount();
  });

  it('compares online work metadata with its pending revision', async () => {
    serviceMocks.getReviewMetadata.mockResolvedValue(metadataReviewDetail());
    const wrapper = mount(NovelReviewDrawer, {
      props: {
        modelValue: false,
        target: { kind: 'metadata', id: 41 },
      },
      global: { stubs: { ElDrawer: DrawerStub } },
      attachTo: document.body,
    });
    await wrapper.setProps({ modelValue: true });
    await flushPromises();

    expect(wrapper.text()).toContain('作品资料修改');
    expect(wrapper.text()).toContain('当前线上资料与待审修改稿');
    expect(wrapper.text()).toContain('当前线上标题');
    expect(wrapper.text()).toContain('待审修改标题');
    expect(wrapper.text()).toContain('通过并更新资料');
    wrapper.unmount();
  });
});

function chapterReviewDetail(changeType: 'add' | 'update'): AiChapterReviewDetail {
  return {
    item: {
      id: 31,
      novelId: 2,
      novelTitle: '月港协议',
      title: '第二章 协议',
      content: '待审修改正文',
      index: 1,
      status: 'pending',
      replacesChapterId: changeType === 'update' ? 20 : null,
      publishedChapterId: changeType === 'update' ? 20 : null,
      changeType,
      originalTitle: changeType === 'update' ? '第二章 旧协议' : '',
      originalContent: changeType === 'update' ? '当前线上正文' : '',
      reviewNote: '',
      revision: 2,
      ownerId: 7,
      ownerNickname: '星海',
      ownerEmail: 'writer@example.invalid',
      submittedAt: '2026-07-19 15:00:00',
      reviewedAt: '',
      publishedAt: '',
      createdAt: '2026-07-19 14:00:00',
      updatedAt: '2026-07-19 15:00:00',
    },
    reviews: [],
  };
}

function metadataReviewDetail(): AiMetadataReviewDetail {
  return {
    item: {
      id: 41,
      novelId: 2,
      novelTitle: '当前线上标题',
      title: '待审修改标题',
      penName: '星海',
      category: '科幻',
      coverUrl: '',
      description: '待审简介',
      serializationStatus: 'completed',
      status: 'pending',
      reviewNote: '',
      revision: 3,
      ownerId: 7,
      ownerNickname: '星海',
      ownerEmail: 'writer@example.invalid',
      submittedAt: '',
      reviewedAt: '',
      publishedAt: '',
      createdAt: '',
      updatedAt: '',
    },
    novel: {
      id: 'ai-2',
      numericId: 2,
      title: '当前线上标题',
      author: '星海',
      coverUrl: '',
      description: '当前线上简介',
      category: '科幻',
      status: 'published',
      serializationStatus: 'ongoing',
      reviewNote: '',
      revision: 2,
      chapterCount: 2,
      publishedChapterCount: 2,
      pendingChapterCount: 0,
      ownerId: 7,
      ownerNickname: '星海',
      ownerEmail: 'writer@example.invalid',
      submittedAt: '',
      reviewedAt: '',
      publishedAt: '',
      createdAt: '',
      updatedAt: '',
    },
    reviews: [],
  };
}
