import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../design/app_tokens.dart';
import 'chat_room_list_screen.dart';
import 'message_center_screen.dart';

class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  String _activeTopic = '追更';

  void _openChat({String? topic}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChatRoomListScreen()),
      /*
          title: topic == null ? '读者广场' : '$topic讨论',
        ),
      ),
      */
    );
  }

  void _openPublishSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: const Text('发到读者广场'),
                subtitle: const Text('进入聊天室，和在线读者实时讨论'),
                onTap: () {
                  Navigator.pop(context);
                  _openChat(topic: _activeTopic);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_note_outlined),
                title: const Text('长讨论帖'),
                subtitle: const Text('帖子系统接入前，可先用聊天室承接话题'),
                onTap: () {
                  Navigator.pop(context);
                  _openChat(topic: _activeTopic);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openCommunitySettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: true,
                onChanged: null,
                title: const Text('显示热门讨论'),
                subtitle: const Text('当前版本按活跃话题展示'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.notifications_outlined),
                title: const Text('互动消息'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const MessageCenterScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          _CommunityHeader(
            onPublish: _openPublishSheet,
            onSettings: _openCommunitySettings,
          ),
          const SizedBox(height: 14),
          _CommunityActionCard(
            icon: Icons.forum_rounded,
            title: '读者广场',
            subtitle: '实时聊天、追更讨论、书荒互助',
            action: '进入',
            onTap: _openChat,
          ),
          const SizedBox(height: 14),
          _TopicStrip(
            activeTopic: _activeTopic,
            onSelected: (topic) => setState(() => _activeTopic = topic),
          ),
          const SizedBox(height: 18),
          SectionTitle(title: '$_activeTopic热门讨论'),
          const SizedBox(height: 10),
          for (final post in _postsForTopic(_activeTopic))
            _PostTile(
              tag: post.tag,
              title: post.title,
              subtitle: post.subtitle,
              meta: post.meta,
              onTap: () => _openChat(topic: post.tag),
            ),
        ],
      ),
    );
  }

  List<_CommunityPost> _postsForTopic(String topic) {
    return switch (topic) {
      '书评' => const [
        _CommunityPost(
          '书评',
          '长篇小说看到中后期，最怕哪些问题？',
          '节奏、人物线、伏笔回收，欢迎认真吐槽。',
          '86 评论 · 今天',
        ),
        _CommunityPost(
          '推荐',
          '把你书架里舍不得删的一本留下来',
          '高分不一定冷门，但一定要真心喜欢。',
          '203 评论 · 昨天',
        ),
      ],
      '漫评' => const [
        _CommunityPost(
          '漫评',
          '这一季最值得追的动画有哪些？',
          '从剧情节奏、作画稳定性到弹幕氛围一起聊聊。',
          '128 评论 · 2小时前',
        ),
        _CommunityPost('作画', '哪一集的演出让你反复回看？', '分镜、音乐和情绪点都可以展开聊。', '57 评论 · 今天'),
      ],
      '弹幕' => const [
        _CommunityPost('弹幕', '什么样的弹幕会让观看体验变好？', '一起整理弹幕礼仪和高能时刻。', '64 评论 · 今天'),
        _CommunityPost(
          '共看',
          '今晚想开哪部动画的弹幕场？',
          '选片、时间和集数都可以在广场里敲定。',
          '41 评论 · 1小时前',
        ),
      ],
      '同好' => const [
        _CommunityPost('同好', '找一起追更的同好小队', '留下作品名和更新时间，组个轻松追更局。', '92 评论 · 今天'),
        _CommunityPost('安利', '用一句话安利你最近沉迷的作品', '不要剧透，越真诚越好。', '176 评论 · 昨天'),
      ],
      _ => const [
        _CommunityPost(
          '追更',
          '今天更新后最想讨论的桥段？',
          '新章节、新一集、最新弹幕都可以来聊。',
          '118 评论 · 刚刚',
        ),
        _CommunityPost(
          '推荐',
          '把你书架里舍不得删的一本留下来',
          '高分不一定冷门，但一定要真心喜欢。',
          '203 评论 · 昨天',
        ),
      ],
    };
  }
}

class _CommunityHeader extends StatelessWidget {
  const _CommunityHeader({required this.onPublish, required this.onSettings});

  final VoidCallback onPublish;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '社区',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            IconButton(
              tooltip: '发布',
              onPressed: onPublish,
              icon: const Icon(Icons.edit_square),
            ),
            IconButton(
              tooltip: '设置',
              onPressed: onSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommunityActionCard extends StatelessWidget {
  const _CommunityActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0D172033),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppTokens.brandSoft,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: AppTokens.brand),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              action,
              style: const TextStyle(
                color: AppTokens.brand,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppTokens.brand),
          ],
        ),
      ),
    );
  }
}

class _TopicStrip extends StatelessWidget {
  const _TopicStrip({required this.activeTopic, required this.onSelected});

  final String activeTopic;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    const topics = ['追更', '书评', '漫评', '弹幕', '同好'];
    return Row(
      children: [
        for (final topic in topics)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: InkWell(
                onTap: () => onSelected(topic),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: activeTopic == topic
                        ? AppTokens.brand
                        : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    topic,
                    style: TextStyle(
                      color: activeTopic == topic
                          ? Colors.white
                          : AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 17,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

class _PostTile extends StatelessWidget {
  const _PostTile({
    required this.tag,
    required this.title,
    required this.subtitle,
    required this.meta,
    required this.onTap,
  });

  final String tag;
  final String title;
  final String subtitle;
  final String meta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppTokens.brandSoft,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                tag,
                style: const TextStyle(
                  color: AppTokens.brand,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    meta,
                    style: const TextStyle(
                      color: AppTheme.textHint,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommunityPost {
  const _CommunityPost(this.tag, this.title, this.subtitle, this.meta);

  final String tag;
  final String title;
  final String subtitle;
  final String meta;
}
