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
const ShopView = () => import('@/views/ShopView.vue');
const GrowthRulesView = () => import('@/views/GrowthRulesView.vue');
const GrowthOperationsView = () => import('@/views/GrowthOperationsView.vue');
const RaceOperationsView = () => import('@/views/RaceOperationsView.vue');
const NotificationsView = () => import('@/views/NotificationsView.vue');
const AnalyticsView = () => import('@/views/AnalyticsView.vue');
const AuditView = () => import('@/views/AuditView.vue');
const VersionsView = () => import('@/views/VersionsView.vue');
const ReleasesView = () => import('@/views/ReleasesView.vue');
const GamesView = () => import('@/views/GamesView.vue');
const ProxyView = () => import('@/views/ProxyView.vue');
const SettingsView = () => import('@/views/SettingsView.vue');
const LegacyModuleView = () => import('@/views/LegacyModuleView.vue');
const NotFoundView = () => import('@/views/NotFoundView.vue');

const legacyRoutes = [
  ['content', '内容运营', '目录、推荐位、来源与功能开关'],
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
  scrollBehavior: () => ({ top: 0 }),
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
        {
          path: 'shop',
          name: 'shop',
          component: ShopView,
          meta: {
            title: '商店与装扮',
            hint: '商品生命周期、素材预览、持有人影响与销售记录',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'growth-rules',
          name: 'growth-rules',
          component: GrowthRulesView,
          meta: {
            title: '成长规则',
            hint: '等级阈值、每日上限、用户影响与规则版本',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'growth-ops',
          name: 'growth-ops',
          component: GrowthOperationsView,
          meta: {
            title: '增长运营',
            hint: '内容转化、榜单规则、活动生命周期与奖励预算',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'race',
          name: 'race',
          component: RaceOperationsView,
          meta: {
            title: '赛马运营',
            hint: '自动赛事监控、轮次公平审计、赛季生命周期与奖励预算',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'notifications',
          name: 'notifications',
          component: NotificationsView,
          meta: {
            title: '公告与通知',
            hint: '启动弹窗、消息中心、受众预览与完整发布记录',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'analytics',
          name: 'analytics',
          component: AnalyticsView,
          meta: {
            title: '质量分析',
            hint: '错误、性能和功能转化',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'versions',
          name: 'versions',
          component: VersionsView,
          meta: {
            title: '版本与设备',
            hint: '版本覆盖、设备上报与升级滞后',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'games',
          name: 'games',
          component: GamesView,
          meta: {
            title: '游戏管理',
            hint: '游戏中心展示与服务器运行状态控制',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'releases',
          name: 'releases',
          component: ReleasesView,
          meta: {
            title: '发布管理',
            hint: '线上版本、安装包完整性与历史备份',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'audit',
          name: 'audit',
          component: AuditView,
          meta: {
            title: '审计日志',
            hint: '管理员敏感操作与请求结果追踪',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'proxy',
          name: 'proxy',
          component: ProxyView,
          meta: {
            title: '代理管理',
            hint: 'Mihomo 服务、订阅源、策略组与节点切换',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        {
          path: 'settings',
          name: 'settings',
          component: SettingsView,
          meta: {
            title: '系统配置',
            hint: 'AI 机器人、语音服务与凭据状态',
            requiresAuth: true,
            requiresAdmin: true,
          },
        },
        ...legacyRoutes.filter(([path]) => !['notifications', 'analytics', 'versions', 'releases', 'audit', 'proxy', 'settings'].includes(path)).map(([path, title, hint]) => ({
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
