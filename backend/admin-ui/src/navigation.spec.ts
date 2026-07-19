import { describe, expect, it } from 'vitest';

import { visibleNavigation } from './navigation';

describe('role-aware navigation', () => {
  it('shows the complete workbench to administrators', () => {
    const routes = visibleNavigation('admin').flatMap((group) => group.items.map((item) => item.route));
    expect(routes).toContain('dashboard');
    expect(routes).toContain('settings');
    expect(routes).toContain('ai-novels');
    expect(
      visibleNavigation('admin')
        .flatMap((group) => group.items)
        .find((item) => item.route === 'comments')?.legacy,
    ).toBeUndefined();
    expect(
      visibleNavigation('admin')
        .flatMap((group) => group.items)
        .find((item) => item.route === 'danmaku')?.legacy,
    ).toBeUndefined();
    expect(
      visibleNavigation('admin')
        .flatMap((group) => group.items)
        .find((item) => item.route === 'chat')?.legacy,
    ).toBeUndefined();
    expect(
      visibleNavigation('admin')
        .flatMap((group) => group.items)
        .find((item) => item.route === 'reports')?.legacy,
    ).toBeUndefined();
    expect(
      visibleNavigation('admin')
        .flatMap((group) => group.items)
        .find((item) => item.route === 'users')?.legacy,
    ).toBeUndefined();
    expect(
      visibleNavigation('admin')
        .flatMap((group) => group.items)
        .find((item) => item.route === 'finance')?.legacy,
    ).toBeUndefined();
    expect(
      visibleNavigation('admin')
        .flatMap((group) => group.items)
        .find((item) => item.route === 'shop')?.legacy,
    ).toBeUndefined();
    expect(
      visibleNavigation('admin')
        .flatMap((group) => group.items)
        .find((item) => item.route === 'growth-rules')?.legacy,
    ).toBeUndefined();
    expect(
      visibleNavigation('admin')
        .flatMap((group) => group.items)
        .find((item) => item.route === 'growth-ops')?.legacy,
    ).toBeUndefined();
    expect(
      visibleNavigation('admin')
        .flatMap((group) => group.items)
        .find((item) => item.route === 'race')?.legacy,
    ).toBeUndefined();
    expect(
      visibleNavigation('admin')
        .flatMap((group) => group.items)
        .find((item) => item.route === 'analytics')?.legacy,
    ).toBe(false);
  });

  it('limits ordinary creators to the AI novel workspace', () => {
    const groups = visibleNavigation('user');
    expect(groups).toHaveLength(1);
    expect(groups[0]?.items.map((item) => item.route)).toEqual(['ai-novels']);
  });
});
