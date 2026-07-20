import { flushPromises, mount } from '@vue/test-utils';
import { defineComponent, h } from 'vue';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { AiNovelDetail } from '@/types/ai-novel';

import NovelEditorDrawer from './NovelEditorDrawer.vue';

const serviceMocks = vi.hoisted(() => ({
  getCreatorNovel: vi.fn(),
  saveNovelDraft: vi.fn(),
  submitNovel: vi.fn(),
  uploadNovelCover: vi.fn(),
}));

const messageMocks = vi.hoisted(() => ({
  success: vi.fn(),
  warning: vi.fn(),
  error: vi.fn(),
  confirm: vi.fn(),
}));

vi.mock('@/services/ai-novels', () => serviceMocks);
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

describe('NovelEditorDrawer', () => {
  afterEach(() => {
    vi.clearAllMocks();
    document.body.innerHTML = '';
  });

  it('shows a persistent description error, then saves and submits after it is fixed', async () => {
    serviceMocks.getCreatorNovel.mockResolvedValue(novelDetail());
    serviceMocks.saveNovelDraft.mockImplementation(async (_id, payload) => novelDetail({
      description: payload.description,
      revision: 2,
    }));
    serviceMocks.submitNovel.mockResolvedValue(novelDetail({
      description: '末日重生故事',
      revision: 3,
      status: 'pending',
      chapterStatus: 'pending',
    }));

    const wrapper = mount(NovelEditorDrawer, {
      props: { modelValue: false, novelId: 2 },
      global: { stubs: { ElDrawer: DrawerStub } },
      attachTo: document.body,
    });
    await wrapper.setProps({ modelValue: true });
    await flushPromises();

    expect(wrapper.find('.novel-file-upload input[type="file"]').attributes('multiple')).toBe('');

    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(wrapper.text()).toContain('请填写作品简介');
    expect(messageMocks.warning).toHaveBeenCalledWith(expect.objectContaining({
      message: '请填写作品简介',
    }));
    await vi.waitFor(() => {
      expect(wrapper.find('.field-description').text()).toContain('请填写作品简介');
    });
    expect(document.activeElement).toBe(wrapper.find('.field-description textarea').element);
    expect(serviceMocks.saveNovelDraft).not.toHaveBeenCalled();
    expect(serviceMocks.submitNovel).not.toHaveBeenCalled();

    await wrapper.find('.field-description textarea').setValue('末日重生故事');
    expect(wrapper.text()).not.toContain('请填写作品简介');

    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(serviceMocks.saveNovelDraft).toHaveBeenCalledTimes(1);
    expect(serviceMocks.submitNovel).toHaveBeenCalledWith(2, 2);
    wrapper.unmount();
  });

  it('shows published chapters and submits linked edits together with new chapters', async () => {
    serviceMocks.getCreatorNovel.mockResolvedValue(publishedNovelDetail());
    serviceMocks.saveNovelDraft.mockImplementation(async (_id, payload) => {
      expect(payload.serializationStatus).toBe('ongoing');
      expect(payload.chapters).toEqual([
        expect.objectContaining({
          id: 20,
          publishedChapterId: 20,
          title: '第一章 醒来',
          content: '审核前保留的线上正文，现已补充线索。',
        }),
        expect.objectContaining({
          id: 21,
          publishedChapterId: 21,
          title: '第二章 清单',
          content: '第二章线上正文。',
        }),
        expect.objectContaining({
          publishedChapterId: undefined,
          title: '第三章 避难所',
          content: '新增章节正文。',
        }),
      ]);
      return publishedNovelDetail({ revision: 2, includeDraftChanges: true });
    });
    serviceMocks.submitNovel.mockResolvedValue(
      publishedNovelDetail({ revision: 3, includeDraftChanges: true, changesPending: true }),
    );

    const wrapper = mount(NovelEditorDrawer, {
      props: { modelValue: false, novelId: 2 },
      global: { stubs: { ElDrawer: DrawerStub } },
      attachTo: document.body,
    });
    await wrapper.setProps({ modelValue: true });
    await flushPromises();

    expect(wrapper.text()).toContain('已发布章节与本次变更');
    expect(wrapper.text()).toContain('第一章 醒来');
    expect(wrapper.text()).toContain('第二章 清单');
    expect(wrapper.text()).toContain('已发布');

    await wrapper.find('.chapter-body-input textarea').setValue('审核前保留的线上正文，现已补充线索。');
    const addButton = wrapper.findAll('button').find((candidate) => candidate.text().includes('添加章节'));
    if (!addButton) throw new Error('添加章节按钮未渲染');
    await addButton.trigger('click');
    await wrapper.find('.chapter-title-input input').setValue('第三章 避难所');
    await wrapper.find('.chapter-body-input textarea').setValue('新增章节正文。');

    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(serviceMocks.saveNovelDraft).toHaveBeenCalledTimes(1);
    expect(serviceMocks.submitNovel).toHaveBeenCalledWith(2, 2);
    wrapper.unmount();
  });

  it('allows published work metadata to be submitted as a separate review change', async () => {
    serviceMocks.getCreatorNovel.mockResolvedValue(publishedNovelDetail());
    serviceMocks.saveNovelDraft.mockImplementation(async (_id, payload) => {
      expect(payload.title).toBe('月港协议：修订版');
      expect(payload.description).toBe('更新后的作品简介，会在审核通过后替换线上展示。');
      return publishedNovelDetail({
        revision: 2,
        metadataRevision: metadataRevision('draft'),
      });
    });
    serviceMocks.submitNovel.mockResolvedValue(publishedNovelDetail({
      revision: 3,
      metadataRevision: metadataRevision('pending'),
    }));

    const wrapper = mount(NovelEditorDrawer, {
      props: { modelValue: false, novelId: 2 },
      global: { stubs: { ElDrawer: DrawerStub } },
      attachTo: document.body,
    });
    await wrapper.setProps({ modelValue: true });
    await flushPromises();

    expect(wrapper.find('.field-title input').attributes('disabled')).toBeUndefined();
    await wrapper.find('.field-title input').setValue('月港协议：修订版');
    await wrapper.find('.field-description textarea').setValue('更新后的作品简介，会在审核通过后替换线上展示。');
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(serviceMocks.saveNovelDraft).toHaveBeenCalledTimes(1);
    expect(serviceMocks.submitNovel).toHaveBeenCalledWith(2, 2);
    wrapper.unmount();
  });
});

function submitButton(wrapper: ReturnType<typeof mount>) {
  const button = wrapper.findAll('button').find((candidate) =>
    candidate.text().includes('提交审核') || candidate.text().includes('提交章节变更'),
  );
  if (!button) throw new Error('提交审核按钮未渲染');
  return button;
}

function novelDetail(options: {
  description?: string;
  revision?: number;
  status?: 'draft' | 'pending';
  chapterStatus?: 'draft' | 'pending';
} = {}): AiNovelDetail {
  const status = options.status || 'draft';
  const chapterStatus = options.chapterStatus || 'draft';
  return {
    item: {
      id: 'ai-2',
      numericId: 2,
      title: '重生之末日预告书',
      author: '绘梨衣',
      coverUrl: '/novel-api/uploads/content/novel-covers/test.png',
      description: options.description ?? '',
      category: 'AI原创',
      status,
      serializationStatus: 'ongoing',
      reviewNote: '',
      revision: options.revision || 1,
      chapterCount: 1,
      publishedChapterCount: 0,
      pendingChapterCount: chapterStatus === 'pending' ? 1 : 0,
      ownerId: 1,
      ownerNickname: '管理员',
      ownerEmail: 'admin@example.invalid',
      submittedAt: '',
      reviewedAt: '',
      publishedAt: '',
      createdAt: '',
      updatedAt: '',
    },
    chapters: [{
      id: 10,
      novelId: 2,
      novelTitle: '重生之末日预告书',
      title: '第一章 醒来',
      content: '正文内容',
      index: 0,
      status: chapterStatus,
      replacesChapterId: null,
      publishedChapterId: null,
      changeType: 'add',
      reviewNote: '',
      revision: 1,
      submissionBatchId: null,
      ownerId: 1,
      ownerNickname: '管理员',
      ownerEmail: 'admin@example.invalid',
      submittedAt: '',
      reviewedAt: '',
      publishedAt: '',
      createdAt: '',
      updatedAt: '',
    }],
    reviews: [],
    metadataRevision: null,
    metadataReviews: [],
  };
}

function publishedNovelDetail(options: {
  revision?: number;
  includeDraftChanges?: boolean;
  changesPending?: boolean;
  metadataRevision?: AiNovelDetail['metadataRevision'];
} = {}): AiNovelDetail {
  const changeStatus = options.changesPending ? 'pending' : 'draft';
  const chapters: AiNovelDetail['chapters'] = [
    publishedChapter(20, 0, '第一章 醒来', '审核前保留的线上正文。'),
    publishedChapter(21, 1, '第二章 清单', '第二章线上正文。'),
  ];
  if (options.includeDraftChanges) {
    chapters.splice(1, 0, {
      ...publishedChapter(22, 0, '第一章 醒来', '审核前保留的线上正文，现已补充线索。'),
      status: changeStatus,
      replacesChapterId: 20,
      publishedChapterId: 20,
      changeType: 'update',
      originalTitle: '第一章 醒来',
      originalContent: '审核前保留的线上正文。',
    });
    chapters.push({
      ...publishedChapter(23, 2, '第三章 避难所', '新增章节正文。'),
      status: changeStatus,
      replacesChapterId: null,
      publishedChapterId: null,
      changeType: 'add',
    });
  }
  return {
    item: {
      ...novelDetail({ description: '末日重生故事' }).item,
      status: 'published',
      serializationStatus: 'ongoing',
      revision: options.revision || 1,
      chapterCount: options.includeDraftChanges ? 3 : 2,
      publishedChapterCount: 2,
      pendingChapterCount: options.changesPending ? 2 : 0,
    },
    chapters,
    reviews: [],
    metadataRevision: options.metadataRevision || null,
    metadataReviews: [],
  };
}

function metadataRevision(status: 'draft' | 'pending'): NonNullable<AiNovelDetail['metadataRevision']> {
  return {
    id: 40,
    novelId: 2,
    novelTitle: '月港协议',
    title: '月港协议：修订版',
    penName: '绘梨衣',
    category: 'AI原创',
    coverUrl: '/novel-api/uploads/content/novel-covers/test.png',
    description: '更新后的作品简介，会在审核通过后替换线上展示。',
    serializationStatus: 'ongoing',
    status,
    reviewNote: '',
    revision: 2,
    ownerId: 1,
    ownerNickname: '管理员',
    ownerEmail: 'admin@example.invalid',
    submittedAt: '',
    reviewedAt: '',
    publishedAt: '',
    createdAt: '',
    updatedAt: '',
  };
}

function publishedChapter(
  id: number,
  index: number,
  title: string,
  content: string,
): AiNovelDetail['chapters'][number] {
  return {
    id,
    novelId: 2,
    novelTitle: '重生之末日预告书',
    title,
    content,
    index,
    status: 'published',
    replacesChapterId: null,
    publishedChapterId: id,
    changeType: 'published',
    reviewNote: '',
    revision: 1,
    submissionBatchId: null,
    ownerId: 1,
    ownerNickname: '管理员',
    ownerEmail: 'admin@example.invalid',
    submittedAt: '',
    reviewedAt: '',
    publishedAt: '',
    createdAt: '',
    updatedAt: '',
  };
}
