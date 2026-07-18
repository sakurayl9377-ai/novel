import { createRouter, createWebHashHistory } from 'vue-router';

const AdminLayout = () => import('@/layouts/AdminLayout.vue');
const LoginView = () => import('@/views/LoginView.vue');
const DashboardView = () => import('@/views/DashboardView.vue');
const AiNovelsView = () => import('@/views/AiNovelsView.vue');
const ModerationView = () => import('@/views/ModerationView.vue');
const DanmakuView = () => import('@/views/DanmakuView.vue');
const ChatView = () => import('@/views/ChatView.vue');
const UsersView = () => import('@/views/UsersView.vue');
const FinanceView = () => import('@/views/FinanceView.vue');
const LegacyModuleView = () => import('@/views/LegacyModuleView.vue');
const NotFoundView = () => import('@/views/NotFoundView.vue');

const legacyRoutes = [
  ['content', '内容运营', '目录、推荐位、来源与功能开关'],
  ['growth-ops', '增长运营', '推荐、榜单、活动与赛季'],
  ['shop', '商店与装扮', '商品、素材与用户库存'],
  ['growth-rules', '成长规则', '等级、积分与权益规则'],
  ['race', '赛马运营', '轮次、下注、赛季与公平审计'],
  ['notifications', '通知发布', '草稿、分群与发送记录'],
  ['analytics', '质量分析', '错误、性能和功能转化'],
  ['versions', '版本与设备', '版本覆盖和设备上报'],
  ['releases', '发布管理', '线上版本与备份状态'],
  ['audit', '审计日志', '管理员敏感操作追踪'],
  ['proxy', '代理管理', 'Mihomo 服务与节点策略'],
  ['settings', '系统配置', '服务密钥、机器人和公告'],
] as const;

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    {
      path: '/login',
      name: 'login',
      component: LoginView,
      meta: { title: '登录' },
    },
    {
      path: '/',
      component: AdminLayout,
      meta: { requiresAuth: true },
      children: [
        { path: '', redirect: '/dashboard' },
        {
          path: 'dashboard',
          name: 'dashboard',
          component: DashboardView,
          meta: {
            title: '运营总览',
            hint: '服务健康、业务指标和待处理任务',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'ai-novels',
          name: 'ai-novels',
          component: AiNovelsView,
          meta: {
            title: 'AI 小说',
            hint: '创作、投稿、连载与审核工作台',
            requiresAuth: true,
          },
        },
        {
          path: 'comments',
          name: 'comments',
          component: ModerationView,
          meta: {
            title: '评论审核',
            hint: '读取完整对话上下文并处理评论',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'reports',
          name: 'reports',
          component: ModerationView,
          meta: {
            title: '举报中心',
            hint: '核对举报目标并记录处置结果',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'danmaku',
          name: 'danmaku',
          component: DanmakuView,
          meta: {
            title: '弹幕管理',
            hint: '本地弹幕审核、剧集定位与时间轴上下文',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'chat',
          name: 'chat',
          component: ChatView,
          meta: {
            title: '聊天室',
            hint: '房间配置、消息审核与社区风控',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'users',
          name: 'users',
          component: UsersView,
          meta: {
            title: '用户管理',
            hint: '账号、权限、设备、风险与资产操作工作台',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'finance',
          name: 'finance',
          component: FinanceView,
          meta: {
            title: '资金流水',
            hint: '成长值与樱花币的不可变账本、来源核对和人工账变',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        ...legacyRoutes.map(([path, title, hint]) => ({
          path,
          name: path,
          component: LegacyModuleView,
          meta: {
            title,
            hint,
            requiresAuth: true,
            requiresAdmin: true,
            legacy: true,
          },
        })),
      ],
    },
    { path: '/:pathMatch(.*)*', name: 'not-found', component: NotFoundView },
  ],
});
