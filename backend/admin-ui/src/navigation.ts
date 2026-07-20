import type { Component } from 'vue';
import {
  Bell,
  ChatDotRound,
  Coin,
  Collection,
  Connection,
  DataAnalysis,
  DocumentChecked,
  Files,
  Flag,
  Goods,
  Grid,
  Histogram,
  MagicStick,
  Monitor,
  Opportunity,
  Promotion,
  Setting,
  Tickets,
  User,
  VideoCamera,
} from '@element-plus/icons-vue';

export interface NavigationItem {
  label: string;
  route: string;
  icon: Component;
  adminOnly?: boolean;
  legacy?: boolean;
}

export interface NavigationGroup {
  key: string;
  label: string;
  items: NavigationItem[];
}

export const navigationGroups: NavigationGroup[] = [
  {
    key: 'workbench',
    label: '工作台',
    items: [
      { label: '运营总览', route: 'dashboard', icon: Grid, adminOnly: true },
      { label: 'AI 小说', route: 'ai-novels', icon: MagicStick },
    ],
  },
  {
    key: 'content',
    label: '内容与社区',
    items: [
      { label: '内容运营', route: 'content', icon: Collection, adminOnly: true, legacy: true },
      { label: '评论审核', route: 'comments', icon: Tickets, adminOnly: true },
      { label: '弹幕管理', route: 'danmaku', icon: VideoCamera, adminOnly: true },
      { label: '聊天室', route: 'chat', icon: ChatDotRound, adminOnly: true },
      { label: '举报中心', route: 'reports', icon: Flag, adminOnly: true },
    ],
  },
  {
    key: 'users',
    label: '用户与经济',
    items: [
      { label: '用户管理', route: 'users', icon: User, adminOnly: true },
      { label: '资金流水', route: 'finance', icon: Coin, adminOnly: true },
      { label: '商店与装扮', route: 'shop', icon: Goods, adminOnly: true },
      { label: '成长规则', route: 'growth-rules', icon: Opportunity, adminOnly: true },
    ],
  },
  {
    key: 'operations',
    label: '增长与运营',
    items: [
      { label: '增长运营', route: 'growth-ops', icon: Histogram, adminOnly: true },
      { label: '赛马运营', route: 'race', icon: Promotion, adminOnly: true },
      { label: '公告与通知', route: 'notifications', icon: Bell, adminOnly: true, legacy: true },
    ],
  },
  {
    key: 'system',
    label: '系统',
    items: [
      { label: '质量分析', route: 'analytics', icon: DataAnalysis, adminOnly: true, legacy: true },
      { label: '版本与设备', route: 'versions', icon: Monitor, adminOnly: true, legacy: true },
      { label: '发布管理', route: 'releases', icon: Files, adminOnly: true, legacy: true },
      { label: '审计日志', route: 'audit', icon: DocumentChecked, adminOnly: true, legacy: true },
      { label: '代理管理', route: 'proxy', icon: Connection, adminOnly: true, legacy: true },
      { label: '系统配置', route: 'settings', icon: Setting, adminOnly: true, legacy: true },
    ],
  },
];

export function visibleNavigation(role: string | undefined): NavigationGroup[] {
  const isAdmin = role === 'admin';
  const migratedLabels: Record<string, string> = {
    notifications: '公告与通知',
    analytics: '质量分析',
    versions: '版本与设备',
    releases: '发布管理',
    audit: '审计日志',
    proxy: '代理管理',
    settings: '系统配置',
  };
  return navigationGroups
    .map((group) => ({
      ...group,
      items: group.items
        .filter((item) => !item.adminOnly || isAdmin)
        .map((item) => migratedLabels[item.route]
          ? { ...item, label: migratedLabels[item.route], legacy: false }
          : item),
    }))
    .filter((group) => group.items.length > 0);
}
