import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import MetricCard from './MetricCard.vue';

describe('MetricCard', () => {
  it('renders an operational metric and its context', () => {
    const wrapper = mount(MetricCard, {
      props: { label: '待处理举报', value: 4, hint: '需要人工确认', tone: 'danger' },
    });
    expect(wrapper.text()).toContain('待处理举报');
    expect(wrapper.text()).toContain('4');
    expect(wrapper.classes()).toContain('tone-danger');
  });
});
