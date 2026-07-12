import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/theme.dart';
import '../models/interaction_models.dart';
import '../providers/interaction_auth_provider.dart';
import '../services/interaction_service.dart';
import 'interaction_ui.dart';

class CommentPreviewPanel extends StatefulWidget {
  const CommentPreviewPanel({
    super.key,
    required this.title,
    required this.targetType,
    required this.targetId,
    required this.onTap,
    this.chapterId = '',
    this.episodeId = '',
    this.moreText = '更多评论',
    this.emptyText = '来发第一条友善的评论',
    this.enableRating = false,
    this.onSummaryLoaded,
    this.service,
  });

  final String title;
  final String targetType;
  final String targetId;
  final String chapterId;
  final String episodeId;
  final String moreText;
  final String emptyText;
  final bool enableRating;
  final VoidCallback onTap;
  final ValueChanged<InteractionCommentSummary>? onSummaryLoaded;
  final InteractionService? service;

  @override
  State<CommentPreviewPanel> createState() => _CommentPreviewPanelState();
}

class _CommentPreviewPanelState extends State<CommentPreviewPanel> {
  late final InteractionService _service;
  Future<InteractionCommentSummary>? _summaryFuture;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? InteractionService();
    _summaryFuture = _loadSummary();
  }

  @override
  void didUpdateWidget(covariant CommentPreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetType != widget.targetType ||
        oldWidget.targetId != widget.targetId ||
        oldWidget.chapterId != widget.chapterId ||
        oldWidget.episodeId != widget.episodeId) {
      setState(() => _summaryFuture = _loadSummary());
    }
  }

  Future<InteractionCommentSummary> _loadSummary() async {
    final summary = await _service.fetchCommentSummary(
      targetType: widget.targetType,
      targetId: widget.targetId,
      chapterId: widget.chapterId,
      episodeId: widget.episodeId,
      previewSize: 2,
    );
    widget.onSummaryLoaded?.call(summary);
    return summary;
  }

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;
    final background = isNight ? AppTheme.nightCard : Colors.white;
    final borderColor = isNight ? Colors.white12 : AppTheme.dividerColor;

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
            boxShadow: [
              if (!isNight)
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
            ],
          ),
          child: FutureBuilder<InteractionCommentSummary>(
            future: _summaryFuture,
            builder: (context, snapshot) {
              final summary = snapshot.data;
              final comments = summary?.items ?? const <InteractionComment>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PreviewHeader(
                    title: widget.title,
                    moreText: widget.moreText,
                    commentCount: summary?.commentCount ?? 0,
                    ratingAvg: widget.enableRating ? summary?.ratingAvg : null,
                    isLoading:
                        snapshot.connectionState == ConnectionState.waiting,
                  ),
                  const SizedBox(height: 13),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const _PreviewSkeleton()
                  else if (summary == null || comments.isEmpty)
                    _PreviewEmpty(text: widget.emptyText)
                  else ...[
                    for (var index = 0; index < comments.length; index++) ...[
                      if (index > 0) const Divider(height: 18),
                      _PreviewCommentRow(
                        comment: comments[index],
                        showRating: widget.enableRating,
                        onUserTap: () => _openUserProfile(comments[index].user),
                      ),
                    ],
                    const SizedBox(height: 12),
                    const _PreviewInputHint(),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _openUserProfile(InteractionUserBrief user) async {
    final auth = context.read<InteractionAuthProvider>();
    try {
      final profile = await _service.fetchUserProfile(
        userId: user.id,
        token: auth.token,
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => InteractionUserProfileSheet(
          profile: profile,
          isSelf: auth.user?.id == profile.user.id,
          onFollowChanged: (follow) => _service.followUser(
            token: auth.token,
            userId: profile.user.id,
            follow: follow,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

class _PreviewHeader extends StatelessWidget {
  const _PreviewHeader({
    required this.title,
    required this.moreText,
    required this.commentCount,
    required this.ratingAvg,
    required this.isLoading,
  });

  final String title;
  final String moreText;
  final int commentCount;
  final double? ratingAvg;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final rating = ratingAvg;
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppTheme.primaryColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.rate_review_outlined,
            color: AppTheme.primaryColor,
            size: 19,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (rating != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${rating.toStringAsFixed(rating.truncateToDouble() == rating ? 0 : 1)}分',
                    style: const TextStyle(
                      color: Color(0xFFC77800),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              Text(
                isLoading ? '加载中' : _countText(commentCount),
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        Text(
          moreText,
          style: const TextStyle(
            color: AppTheme.primaryColor,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 2),
        const Icon(Icons.chevron_right, color: AppTheme.primaryColor, size: 18),
      ],
    );
  }

  static String _countText(int count) {
    if (count <= 0) return '暂无评论';
    if (count >= 10000) return '${(count / 10000).toStringAsFixed(1)}万条';
    return '$count条';
  }
}

class _PreviewCommentRow extends StatelessWidget {
  const _PreviewCommentRow({
    required this.comment,
    required this.showRating,
    required this.onUserTap,
  });

  final InteractionComment comment;
  final bool showRating;
  final VoidCallback onUserTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InteractionAvatar(
            label: comment.user.nickname,
            imageUrl: comment.user.avatarUrl,
            size: 30,
            onTap: onUserTap,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        comment.user.nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (showRating && comment.rating != null)
                      _TinyRating(value: comment.rating!),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  comment.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  [
                    _relativeTime(comment.createdAt),
                    if (comment.likeCount > 0) '赞 ${comment.likeCount}',
                    if (comment.replyCount > 0) '回复 ${comment.replyCount}',
                  ].join(' · '),
                  style: const TextStyle(
                    color: AppTheme.textHint,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TinyRating extends StatelessWidget {
  const _TinyRating({required this.value});

  final int value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < 5; index++)
          Icon(
            index < value ? Icons.star : Icons.star_border,
            color: Colors.amber,
            size: 12,
          ),
      ],
    );
  }
}

class _PreviewSkeleton extends StatelessWidget {
  const _PreviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        _SkeletonLine(widthFactor: 0.92),
        SizedBox(height: 8),
        _SkeletonLine(widthFactor: 0.72),
      ],
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({required this.widthFactor});

  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: Alignment.centerLeft,
      child: Container(
        height: 14,
        decoration: BoxDecoration(
          color: AppTheme.dividerColor.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(7),
        ),
      ),
    );
  }
}

class _PreviewEmpty extends StatelessWidget {
  const _PreviewEmpty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            text,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
        ),
        const SizedBox(height: 12),
        const _PreviewInputHint(),
      ],
    );
  }
}

class _PreviewInputHint extends StatelessWidget {
  const _PreviewInputHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.dividerColor),
      ),
      child: const Row(
        children: [
          Icon(Icons.edit_outlined, color: AppTheme.textHint, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '写下你的想法，和大家一起讨论',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

String _relativeTime(String value) {
  final date = DateTime.tryParse(value.replaceFirst(' ', 'T'));
  if (date == null) return value;
  final diff = DateTime.now().difference(date);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
  if (diff.inDays < 1) return '${diff.inHours}小时前';
  if (diff.inDays < 30) return '${diff.inDays}天前';
  return '${date.month}月${date.day}日';
}
