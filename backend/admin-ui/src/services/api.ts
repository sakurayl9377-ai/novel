import { runtimeConfig } from '@/config/runtime';

export const adminTokenStorageKey = 'novelAdminToken';

export class ApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
    public readonly code: string,
    public readonly details?: unknown,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export interface ApiRequestOptions extends Omit<RequestInit, 'body'> {
  body?: unknown;
  auth?: boolean;
}

export interface ApiFormRequestOptions extends Omit<RequestInit, 'body'> {
  auth?: boolean;
}

export async function apiRequest<T>(
  path: string,
  options: ApiRequestOptions = {},
): Promise<T> {
  const serializedBody = options.body === undefined
    ? undefined
    : JSON.stringify(options.body);
  const headers = authorizedHeaders(options.headers, options.auth);
  if (serializedBody !== undefined) headers.set('Content-Type', 'application/json');

  return executeRequest<T>(path, {
    ...options,
    headers,
    body: serializedBody,
  });
}

export async function apiFormRequest<T>(
  path: string,
  body: FormData,
  options: ApiFormRequestOptions = {},
): Promise<T> {
  return executeRequest<T>(path, {
    ...options,
    method: options.method || 'POST',
    headers: authorizedHeaders(options.headers, options.auth),
    body,
  });
}

export function queryString(values: Record<string, unknown>): string {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(values)) {
    if (value === '' || value === null || value === undefined) continue;
    params.set(key, String(value));
  }
  const query = params.toString();
  return query ? `?${query}` : '';
}

function authorizedHeaders(source: HeadersInit | undefined, auth = true): Headers {
  const headers = new Headers(source);
  const token = localStorage.getItem(adminTokenStorageKey) || '';
  if (auth !== false && token) headers.set('Authorization', `Bearer ${token}`);
  return headers;
}

async function executeRequest<T>(path: string, options: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${runtimeConfig.apiPrefix}${path}`, options);
  } catch (error) {
    throw new ApiError(
      error instanceof Error ? error.message : '网络连接失败，请稍后重试',
      0,
      'network_error',
    );
  }

  const data = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) {
    const code = String(data.error || `http_${response.status}`);
    if (response.status === 401) {
      window.dispatchEvent(new Event('novel-admin:unauthorized'));
    }
    throw new ApiError(friendlyApiError(code), response.status, code, data);
  }
  return data as T;
}

function friendlyApiError(code: string): string {
  const messages: Record<string, string> = {
    unauthorized: '登录已失效，请重新登录',
    admin_required: '当前账号没有管理权限',
    account_banned: '当前账号已被封禁',
    internal_error: '服务暂时不可用，请稍后重试',
    revision_conflict: '作品已在其他页面发生变化，已为你重新加载最新内容',
    novel_review_in_progress: '作品正在审核中，暂时不能修改',
    novel_cover_file_required: '请选择封面图片',
    novel_cover_file_too_large: '封面不能超过 5MB',
    novel_cover_type_invalid: '封面仅支持 JPG、PNG 或 WebP',
    novel_cover_content_invalid: '图片内容与文件类型不一致，请重新选择',
    novel_cover_upload_required: '请通过封面上传区域选择图片，不能填写外部地址',
    novel_cover_not_found: '封面文件不存在，请重新上传',
    upload_file_quota_exceeded: '上传文件数量已达上限，请删除不用的草稿后重试',
    upload_storage_quota_exceeded: '上传空间已满，请清理不用的内容后重试',
    novel_cannot_be_deleted: '审核中或已发布的作品不能删除',
    chapter_requires_novel_review: '该章节属于整书投稿，请在整书审核队列中处理',
    serial_chapter_review_in_progress: '已有连载章节正在审核，请等待本批次完成后再提交',
    chat_room_exists: '这个房间 ID 已存在，请使用自动生成或换一个 ID',
    chat_room_id_invalid: '房间 ID 格式不正确，请仅使用字母、数字、点、冒号、下划线或短横线',
    chat_room_dissolved: '房间已经解散，成员关系已移除，不能再编辑',
    chat_keyword_exists: '相同关键词规则已经存在，请直接编辑原规则',
    chat_bot_member_locked: '系统机器人成员由房间机器人开关管理，不能手动移出',
    blocked_ip_invalid: '请输入有效的 IPv4 或 IPv6 地址',
    cannot_ban_self: '不能封禁当前登录的管理员账号',
    user_ban_mode_invalid: '请选择限时封禁或永久封禁',
    user_ban_duration_invalid: '请选择列表中的有效封禁时长',
    user_ban_reason_invalid: '请选择有效的封禁原因',
    cannot_change_own_role: '不能修改当前登录账号自身的角色，请由其他管理员操作',
    last_admin_protected: '这是最后一个可用管理员账号，不能封禁或取消其管理员权限',
    user_adjustment_currency_invalid: '请选择成长值或樱花币',
    user_adjustment_direction_invalid: '请选择增加或扣除',
    user_adjustment_amount_invalid: '请输入有效的正整数调整数量',
    user_adjustment_reason_invalid: '请选择有效的账变原因',
    insufficient_user_balance: '用户余额不足，整笔操作已取消',
    cannot_revoke_own_sessions: '不能在用户工作台撤销当前账号自身的登录会话',
    finance_period_invalid: '请选择有效的账本时间范围',
    finance_currency_invalid: '请选择成长值、樱花币或同时变化',
    finance_direction_invalid: '请选择发放或扣除方向',
    shop_status_invalid: '请选择有效的商品状态',
    shop_item_type_invalid: '请选择客户端当前支持的商品类型',
    shop_asset_preset_invalid: '请选择该商品类型下可用的运行时预设',
    shop_preview_file_required: '请选择商品预览图',
    shop_preview_file_too_large: '商品预览图不能超过 3MB',
    shop_preview_type_invalid: '商品预览图仅支持 JPG、PNG 或 WebP',
    shop_preview_content_invalid: '图片内容与文件类型不一致，请重新选择',
    shop_preview_upload_required: '请通过图片上传区域选择预览图，不能填写外部地址',
    shop_preview_not_found: '商品预览图不存在，请重新上传',
    shop_preview_required_for_activation: '上架前必须上传商品预览图',
    shop_item_name_conflict: '已有未归档商品使用相同名称',
    shop_item_preset_conflict: '该运行时预设已有未归档商品，请先处理原商品',
    shop_item_revision_conflict: '商品已在其他页面发生变化，请重新加载后再操作',
    shop_item_identity_locked: '商品已有持有人、正在装备或不处于草稿状态，不能改变类型与运行时预设',
    shop_item_archived: '归档商品不能直接编辑，请先恢复为草稿',
    shop_status_transition_invalid: '当前商品状态不允许执行这个操作',
    shop_status_unchanged: '商品已经处于所选状态',
    growth_rules_shape_invalid: '成长规则必须完整包含 Lv.1 至 Lv.7',
    growth_rules_level_order_invalid: '成长等级顺序无效，请保持 Lv.1 至 Lv.7',
    growth_rules_level_one_points_invalid: 'Lv.1 的起始成长值必须为 0',
    growth_rules_level_one_days_invalid: 'Lv.1 的目标天数必须为 0',
    growth_rules_threshold_order_invalid: '每一级成长值门槛必须严格高于前一级',
    growth_rules_daily_cap_order_invalid: '每日成长上限不能低于前一级',
    growth_rules_target_days_order_invalid: '目标天数不能低于前一级',
    growth_rules_name_invalid: '请填写 24 字以内的等级名称',
    growth_rules_effect_invalid: '请填写 120 字以内的等级效果',
    growth_rules_note_invalid: '请填写本次调整的审核依据',
    growth_rules_no_changes: '草稿与当前发布规则完全一致',
    growth_rules_draft_missing: '当前没有可操作的规则草稿',
    growth_rules_draft_exists: '已有未处理的规则草稿，请先确认是否替换',
    growth_rules_draft_outdated: '草稿基于旧版本创建，请从当前规则重新编辑',
    growth_rules_draft_revision_conflict: '规则草稿已被其他管理员修改，请重新加载',
    growth_rules_impact_acknowledgement_required: '该规则会导致降级或每日上限降低，请确认影响后再发布',
    growth_rules_revision_not_found: '找不到可恢复的成长规则版本',
    growth_ranking_scope_invalid: '请选择有效的榜单范围',
    growth_ranking_content_not_found: '所选内容已不在内容目录中',
    growth_ranking_control_conflict: '同一条排行规则不能同时置顶和排除',
    growth_ranking_revision_conflict: '排行规则已被其他管理员修改，请刷新后重试',
    growth_ranking_control_not_found: '该排行规则已被移除',
    growth_content_type_invalid: '请选择有效的内容类型',
    growth_change_note_invalid: '请填写具体的运营调整原因',
    campaign_banner_file_required: '请选择活动横幅图片',
    campaign_banner_file_too_large: '活动横幅不能超过 5MB',
    campaign_banner_type_invalid: '活动横幅仅支持 JPG、PNG 或 WebP',
    campaign_banner_content_invalid: '图片内容与文件类型不一致，请重新选择',
    campaign_banner_upload_required: '请通过横幅上传区域选择图片，不能填写外部地址',
    campaign_banner_not_found: '活动横幅文件不存在，请重新上传',
    growth_campaign_not_found: '活动不存在或已无法读取',
    growth_campaign_status_invalid: '请选择有效的活动状态',
    growth_campaign_revision_conflict: '活动已被其他管理员修改，请刷新后重试',
    growth_campaign_key_conflict: '活动标识已被使用，请更换后重试',
    growth_campaign_key_locked: '活动标识创建后不能修改',
    growth_campaign_edit_requires_pause: '进行中的活动需要先暂停，才能修改配置',
    growth_campaign_status_transition_invalid: '当前活动状态不允许执行该操作',
    growth_campaign_banner_required_for_activation: '启用活动前必须上传横幅',
    growth_campaign_schedule_required_for_activation: '启用活动前必须设置完整的开始与结束时间',
    growth_campaign_end_must_be_future: '活动结束时间必须晚于当前时间',
    growth_campaign_task_required_for_activation: '启用活动前至少需要一个有效任务',
    growth_campaign_budget_acknowledgement_required: '请先核对并确认活动奖励预算',
    growth_campaign_audience_invalid: '请选择可计算覆盖范围的活动人群',
    growth_campaign_date_range_invalid: '活动结束时间必须晚于开始时间',
    growth_campaign_version_range_invalid: '客户端版本范围设置不正确',
    growth_campaign_restore_requires_pause: '只有草稿或暂停活动可以恢复历史版本',
    growth_campaign_revision_not_found: '找不到可恢复的活动历史版本',
    growth_campaign_revision_invalid: '活动历史版本数据不完整，无法恢复',
    growth_campaign_revision_task_locked: '历史版本会改变已有进度或领奖任务的核心规则，无法恢复',
    growth_campaign_task_not_found: '活动任务不存在或已被移除',
    growth_campaign_task_key_conflict: '同一活动内的任务标识不能重复',
    growth_campaign_task_event_invalid: '请选择有效的任务触发事件',
    growth_campaign_task_content_invalid: '指定内容与所选内容类型不匹配',
    growth_campaign_task_status_invalid: '请选择有效的任务状态',
    growth_campaign_task_progress_locked: '该任务已有用户进度，完成条件不能再修改',
    growth_campaign_task_reward_locked: '该任务已有奖励领取记录，奖励金额不能再修改',
  };
  return messages[code] || code.replaceAll('_', ' ');
}
