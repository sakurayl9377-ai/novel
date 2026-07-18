import type {
  ChatKeywordMatchType,
  ChatMessageStatus,
  ChatMessageType,
  ChatRoomCategory,
  ChatRoomStatus,
  ChatViolationAction,
} from '@/types/chat';

export function chatRoomCategoryLabel(value: ChatRoomCategory | string): string {
  return ({ novel: '小说', anime: '动漫', manga: '漫画' } as Record<string, string>)[value]
    || value
    || '未分类';
}

export function chatRoomStatusLabel(value: ChatRoomStatus | string): string {
  return ({ active: '开放中', hidden: '已隐藏', deleted: '已解散' } as Record<string, string>)[value]
    || value;
}

export function chatMessageStatusLabel(value: ChatMessageStatus | string): string {
  return ({ visible: '展示中', deleted: '已删除' } as Record<string, string>)[value]
    || value;
}

export function chatMessageTypeLabel(value: ChatMessageType | string): string {
  return ({
    text: '文字',
    image: '图片',
    audio: '语音',
    file: '文件',
    sticker: '贴纸',
    share: '内容分享',
  } as Record<string, string>)[value] || value;
}

export function chatKeywordMatchLabel(value: ChatKeywordMatchType | string): string {
  return value === 'exact' ? '整句精确匹配' : '包含即命中';
}

export function chatViolationActionLabel(value: ChatViolationAction | string): string {
  return ({
    blocked: '已拦截消息',
    temp_ban: '已临时封禁',
    permanent_ban: '已永久封禁',
  } as Record<string, string>)[value] || value;
}

export function chatBlockReasonLabel(value: string): string {
  const [reason, ...details] = value.split(':');
  const label = ({
    admin_block: '管理员手动封禁',
    malicious_registration: '恶意重复注册',
    chat_keyword_temp: '聊天违规临时封禁',
    chat_keyword_permanent: '聊天违规永久封禁',
    chat_keyword_manual_review: '聊天违规人工复核',
  } as Record<string, string>)[reason || ''];
  if (label) return details.length ? `${label} · ${details.join(':')}` : label;
  return value || '未填写原因';
}

export function chatKeywordMatches(
  keyword: string,
  matchType: ChatKeywordMatchType,
  content: string,
): boolean {
  const normalizedKeyword = normalizeChatKeywordText(keyword);
  const normalizedContent = normalizeChatKeywordText(content);
  if (!normalizedKeyword || !normalizedContent) return false;
  return matchType === 'exact'
    ? normalizedContent === normalizedKeyword
    : normalizedContent.includes(normalizedKeyword);
}

export function normalizeChatKeywordText(value: string): string {
  return String(value || '')
    .toLowerCase()
    .replace(/\s+/g, '')
    .replace(/[._\-~·,，。!！?？:：;；'"“”‘’()[\]{}【】<>《》]/g, '')
    .trim();
}

export function chatMessageSummary(type: ChatMessageType, content: string): string {
  const clean = String(content || '').trim();
  if (clean) return clean;
  return `[${chatMessageTypeLabel(type)}消息]`;
}
