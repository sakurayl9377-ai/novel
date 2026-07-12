import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/theme.dart';
import '../models/interaction_models.dart';
import '../providers/interaction_auth_provider.dart';
import '../services/interaction_service.dart';
import '../widgets/interaction_ui.dart';
import 'interaction_auth_screen.dart';

class CommentThreadScreen extends StatelessWidget {
  const CommentThreadScreen({
    super.key,
    required this.title,
    required this.targetType,
    required this.targetId,
    this.targetTitle = '',
    this.chapterId = '',
    this.chapterTitle = '',
    this.episodeId = '',
    this.episodeTitle = '',
    this.enableRating = false,
    this.inputHint = '发一条友善的评论',
  });

  final String title;
  final String targetType;
  final String targetId;
  final String targetTitle;
  final String chapterId;
  final String chapterTitle;
  final String episodeId;
  final String episodeTitle;
  final bool enableRating;
  final String inputHint;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: CommentInteractionPanel(
        targetType: targetType,
        targetId: targetId,
        targetTitle: targetTitle.isNotEmpty ? targetTitle : title,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        episodeId: episodeId,
        episodeTitle: episodeTitle,
        enableRating: enableRating,
        inputHint: inputHint,
      ),
    );
  }
}

class CommentInteractionPanel extends StatefulWidget {
  const CommentInteractionPanel({
    super.key,
    required this.targetType,
    required this.targetId,
    this.targetTitle = '',
    this.chapterId = '',
    this.chapterTitle = '',
    this.episodeId = '',
    this.episodeTitle = '',
    this.enableRating = false,
    this.inputHint = '发一条友善的评论',
    this.emptyTitle = '还没有评论',
    this.emptySubtitle = '来发第一条友善的评论',
    this.showSortBar = true,
    this.useSafeArea = true,
    this.compact = false,
    this.service,
  });

  final String targetType;
  final String targetId;
  final String targetTitle;
  final String chapterId;
  final String chapterTitle;
  final String episodeId;
  final String episodeTitle;
  final bool enableRating;
  final String inputHint;
  final String emptyTitle;
  final String emptySubtitle;
  final bool showSortBar;
  final bool useSafeArea;
  final bool compact;
  final InteractionService? service;

  @override
  State<CommentInteractionPanel> createState() =>
      _CommentInteractionPanelState();
}

class _CommentInteractionPanelState extends State<CommentInteractionPanel> {
  late final InteractionService _service;
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  List<InteractionComment> _comments = const [];
  final Set<int> _likedIds = <int>{};
  bool _isLoading = true;
  bool _isSending = false;
  String _sort = 'hot';
  int _rating = 5;
  InteractionComment? _replyTo;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? InteractionService();
    unawaited(_loadComments());
  }

  @override
  void didUpdateWidget(covariant CommentInteractionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetType != widget.targetType ||
        oldWidget.targetId != widget.targetId ||
        oldWidget.targetTitle != widget.targetTitle ||
        oldWidget.chapterId != widget.chapterId ||
        oldWidget.chapterTitle != widget.chapterTitle ||
        oldWidget.episodeId != widget.episodeId ||
        oldWidget.episodeTitle != widget.episodeTitle) {
      _replyTo = null;
      _controller.clear();
      unawaited(_loadComments());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    setState(() => _isLoading = true);
    try {
      final comments = await _service.fetchComments(
        targetType: widget.targetType,
        targetId: widget.targetId,
        chapterId: widget.chapterId,
        episodeId: widget.episodeId,
        sort: _sort,
        pageSize: 50,
      );
      if (!mounted) return;
      setState(() => _comments = comments);
    } catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<bool> _ensureLoggedIn() async {
    final auth = context.read<InteractionAuthProvider>();
    if (auth.isLoggedIn) return true;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const InteractionAuthScreen()),
    );
    return mounted && context.read<InteractionAuthProvider>().isLoggedIn;
  }

  Future<void> _sendComment() async {
    if (!await _ensureLoggedIn()) return;
    if (!mounted) return;
    final auth = context.read<InteractionAuthProvider>();
    final content = _controller.text.trim();
    if (content.isEmpty) {
      _showMessage('请输入内容');
      return;
    }

    final replyTo = _replyTo;
    setState(() => _isSending = true);
    try {
      await _service.postComment(
        token: auth.token,
        targetType: widget.targetType,
        targetId: widget.targetId,
        targetTitle: widget.targetTitle,
        chapterId: widget.chapterId,
        chapterTitle: widget.chapterTitle,
        episodeId: widget.episodeId,
        episodeTitle: widget.episodeTitle,
        parentId: replyTo?.id,
        content: content,
        rating: replyTo == null && widget.enableRating ? _rating : null,
      );
      if (!mounted) return;
      _controller.clear();
      setState(() => _replyTo = null);
      await _loadComments();
      if (replyTo != null) _showMessage('回复已发布');
    } catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _likeComment(InteractionComment comment) async {
    if (_likedIds.contains(comment.id)) return;
    if (!await _ensureLoggedIn()) return;
    if (!mounted) return;
    final auth = context.read<InteractionAuthProvider>();
    try {
      await _service.likeComment(token: auth.token, commentId: comment.id);
      if (!mounted) return;
      _likedIds.add(comment.id);
      setState(() {
        _comments = _comments
            .map(
              (item) => item.id == comment.id
                  ? item.copyWith(likeCount: item.likeCount + 1)
                  : item,
            )
            .toList();
      });
    } catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    }
  }

  Future<void> _reportComment(InteractionComment comment) async {
    if (!await _ensureLoggedIn()) return;
    if (!mounted) return;
    final auth = context.read<InteractionAuthProvider>();
    try {
      await _service.reportTarget(
        token: auth.token,
        targetType: 'comment',
        targetId: comment.id.toString(),
        reason: '不友善或违规内容',
      );
      if (mounted) _showMessage('已提交举报');
    } catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    }
  }

  void _replyComment(InteractionComment comment) {
    setState(() => _replyTo = comment);
    _focusNode.requestFocus();
  }

  Future<void> _openReplies(InteractionComment comment) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (_) => _RepliesSheet(
        parent: comment,
        service: _service,
        targetType: widget.targetType,
        targetId: widget.targetId,
        targetTitle: widget.targetTitle,
        chapterId: widget.chapterId,
        chapterTitle: widget.chapterTitle,
        episodeId: widget.episodeId,
        episodeTitle: widget.episodeTitle,
      ),
    );
    if (changed == true) await _loadComments();
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
      if (mounted) _showMessage(_friendlyError(error));
    }
  }

  void _changeSort(String value) {
    if (_sort == value) return;
    setState(() => _sort = value);
    unawaited(_loadComments());
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    final content = Column(
      children: [
        if (widget.showSortBar)
          _CommentSortBar(value: _sort, onChanged: _changeSort),
        Expanded(child: _buildList()),
        if (_replyTo != null)
          _ReplyBanner(
            comment: _replyTo!,
            onCancel: () => setState(() => _replyTo = null),
          ),
        _CommentComposer(
          controller: _controller,
          focusNode: _focusNode,
          isLoggedIn: auth.isLoggedIn,
          isSending: _isSending,
          hintText: _replyTo == null
              ? widget.inputHint
              : '回复 @${_replyTo!.user.nickname}',
          enableRating: widget.enableRating && _replyTo == null,
          rating: _rating,
          onRatingChanged: (value) => setState(() => _rating = value),
          onSend: _sendComment,
        ),
      ],
    );

    if (!widget.useSafeArea) return content;
    return SafeArea(top: false, child: content);
  }

  Widget _buildList() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_comments.isEmpty) {
      return InteractionEmptyState(
        icon: Icons.chat_bubble_outline,
        title: widget.emptyTitle,
        subtitle: widget.emptySubtitle,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadComments,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(
          widget.compact ? 12 : 16,
          widget.compact ? 8 : 12,
          widget.compact ? 12 : 16,
          18,
        ),
        itemCount: _comments.length,
        separatorBuilder: (_, _) => const Divider(height: 22),
        itemBuilder: (context, index) {
          final comment = _comments[index];
          return _CommentTile(
            comment: comment,
            showRating: widget.enableRating,
            isLiked: _likedIds.contains(comment.id),
            onLike: () => _likeComment(comment),
            onReply: () => _replyComment(comment),
            onReplies: () => _openReplies(comment),
            onReport: () => _reportComment(comment),
            onUserTap: () => _openUserProfile(comment.user),
          );
        },
      ),
    );
  }

  String _friendlyError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    if (text.contains('SocketException') ||
        text.contains('TimeoutException') ||
        text.contains('ClientException')) {
      return '网络连接失败，请稍后再试';
    }
    return text;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _CommentSortBar extends StatelessWidget {
  const _CommentSortBar({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppTheme.dividerColor)),
      ),
      child: Row(
        children: [
          _SortButton(
            label: '热门评论',
            active: value == 'hot',
            onTap: () => onChanged('hot'),
          ),
          const SizedBox(width: 18),
          _SortButton(
            label: '最新评论',
            active: value == 'latest',
            onTap: () => onChanged('latest'),
          ),
        ],
      ),
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Text(
          label,
          style: TextStyle(
            color: active ? AppTheme.primaryColor : AppTheme.textSecondary,
            fontSize: 15,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.showRating,
    required this.isLiked,
    required this.onLike,
    required this.onReply,
    required this.onReplies,
    required this.onReport,
    required this.onUserTap,
  });

  final InteractionComment comment;
  final bool showRating;
  final bool isLiked;
  final VoidCallback onLike;
  final VoidCallback onReply;
  final VoidCallback onReplies;
  final VoidCallback onReport;
  final VoidCallback onUserTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InteractionAvatar(
          label: comment.user.nickname,
          imageUrl: comment.user.avatarUrl,
          size: 40,
          onTap: onUserTap,
        ),
        const SizedBox(width: 11),
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
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    onSelected: (_) => onReport(),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'report', child: Text('举报')),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.more_vert,
                        color: AppTheme.textHint,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
              if (showRating && comment.rating != null) ...[
                const SizedBox(height: 3),
                _RatingStars(value: comment.rating!, size: 14),
              ],
              const SizedBox(height: 7),
              Text(
                comment.content,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _relativeTime(comment.createdAt),
                      style: const TextStyle(
                        color: AppTheme.textHint,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  _ActionButton(
                    icon: isLiked
                        ? Icons.thumb_up_alt
                        : Icons.thumb_up_alt_outlined,
                    label: comment.likeCount > 0
                        ? comment.likeCount.toString()
                        : '赞',
                    active: isLiked,
                    onTap: onLike,
                  ),
                  const SizedBox(width: 12),
                  _ActionButton(
                    icon: Icons.chat_bubble_outline,
                    label: '回复',
                    onTap: onReply,
                  ),
                ],
              ),
              if (comment.replyCount > 0) ...[
                const SizedBox(height: 10),
                InkWell(
                  onTap: onReplies,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundLight,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '共 ${comment.replyCount} 条回复 >',
                      style: const TextStyle(
                        color: AppTheme.primaryColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppTheme.primaryColor : AppTheme.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 19),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({required this.comment, required this.onCancel});

  final InteractionComment comment;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F8FA),
        border: Border(top: BorderSide(color: AppTheme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '回复 @${comment.user.nickname}：${comment.content}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          IconButton(
            tooltip: '取消回复',
            onPressed: onCancel,
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _CommentComposer extends StatelessWidget {
  const _CommentComposer({
    required this.controller,
    required this.focusNode,
    required this.isLoggedIn,
    required this.isSending,
    required this.hintText,
    required this.enableRating,
    required this.rating,
    required this.onRatingChanged,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isLoggedIn;
  final bool isSending;
  final String hintText;
  final bool enableRating;
  final int rating;
  final ValueChanged<int> onRatingChanged;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppTheme.dividerColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (enableRating) ...[
            Row(
              children: [
                const Text(
                  '我的评分',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                for (var index = 1; index <= 5; index++)
                  InkWell(
                    onTap: () => onRatingChanged(index),
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        index <= rating ? Icons.star : Icons.star_border,
                        color: Colors.amber,
                        size: 21,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: isLoggedIn ? hintText : '登录后参与讨论',
                    hintStyle: const TextStyle(color: AppTheme.textSecondary),
                    filled: true,
                    fillColor: const Color(0xFFF2F3F5),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: isLoggedIn ? '发送' : '登录',
                onPressed: isSending ? null : onSend,
                icon: Icon(isLoggedIn ? Icons.arrow_upward : Icons.login),
                style: IconButton.styleFrom(
                  fixedSize: const Size(42, 42),
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RepliesSheet extends StatefulWidget {
  const _RepliesSheet({
    required this.parent,
    required this.service,
    required this.targetType,
    required this.targetId,
    required this.targetTitle,
    required this.chapterId,
    required this.chapterTitle,
    required this.episodeId,
    required this.episodeTitle,
  });

  final InteractionComment parent;
  final InteractionService service;
  final String targetType;
  final String targetId;
  final String targetTitle;
  final String chapterId;
  final String chapterTitle;
  final String episodeId;
  final String episodeTitle;

  @override
  State<_RepliesSheet> createState() => _RepliesSheetState();
}

class _RepliesSheetState extends State<_RepliesSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<InteractionComment> _replies = const [];
  bool _isLoading = true;
  bool _isSending = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadReplies());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadReplies() async {
    setState(() => _isLoading = true);
    try {
      final replies = await widget.service.fetchReplies(
        commentId: widget.parent.id,
        pageSize: 80,
      );
      if (mounted) setState(() => _replies = replies);
    } catch (_) {
      if (mounted) _showMessage('回复加载失败');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<bool> _ensureLoggedIn() async {
    final auth = context.read<InteractionAuthProvider>();
    if (auth.isLoggedIn) return true;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const InteractionAuthScreen()),
    );
    return mounted && context.read<InteractionAuthProvider>().isLoggedIn;
  }

  Future<void> _sendReply() async {
    if (!await _ensureLoggedIn()) return;
    if (!mounted) return;
    final auth = context.read<InteractionAuthProvider>();
    final content = _controller.text.trim();
    if (content.isEmpty) {
      _showMessage('请输入内容');
      return;
    }
    setState(() => _isSending = true);
    try {
      final reply = await widget.service.postComment(
        token: auth.token,
        targetType: widget.targetType,
        targetId: widget.targetId,
        targetTitle: widget.targetTitle,
        chapterId: widget.chapterId,
        chapterTitle: widget.chapterTitle,
        episodeId: widget.episodeId,
        episodeTitle: widget.episodeTitle,
        parentId: widget.parent.id,
        content: content,
      );
      if (!mounted) return;
      _controller.clear();
      setState(() {
        _changed = true;
        _replies = [..._replies, reply];
      });
    } catch (_) {
      if (mounted) _showMessage('回复失败，请稍后再试');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    final bottom = MediaQuery.viewInsetsOf(context).bottom;

    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.78,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '共 ${widget.parent.replyCount} 条回复',
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context, _changed),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: _CommentTile(
                  comment: widget.parent,
                  showRating: widget.parent.rating != null,
                  isLiked: false,
                  onLike: () {},
                  onReply: () => _focusNode.requestFocus(),
                  onReplies: () {},
                  onReport: () {},
                  onUserTap: () => _openUserProfile(widget.parent.user),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _replies.isEmpty
                    ? const InteractionEmptyState(
                        icon: Icons.chat_bubble_outline,
                        title: '还没有回复',
                        subtitle: '来补充你的想法',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                        itemCount: _replies.length,
                        separatorBuilder: (_, _) => const Divider(height: 22),
                        itemBuilder: (context, index) => _ReplyTile(
                          comment: _replies[index],
                          onUserTap: () =>
                              _openUserProfile(_replies[index].user),
                        ),
                      ),
              ),
              _CommentComposer(
                controller: _controller,
                focusNode: _focusNode,
                isLoggedIn: auth.isLoggedIn,
                isSending: _isSending,
                hintText: '回复 @${widget.parent.user.nickname}',
                enableRating: false,
                rating: 0,
                onRatingChanged: (_) {},
                onSend: _sendReply,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openUserProfile(InteractionUserBrief user) async {
    final auth = context.read<InteractionAuthProvider>();
    try {
      final profile = await widget.service.fetchUserProfile(
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
          onFollowChanged: (follow) => widget.service.followUser(
            token: auth.token,
            userId: profile.user.id,
            follow: follow,
          ),
        ),
      );
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }
}

class _ReplyTile extends StatelessWidget {
  const _ReplyTile({required this.comment, required this.onUserTap});

  final InteractionComment comment;
  final VoidCallback onUserTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InteractionAvatar(
          label: comment.user.nickname,
          imageUrl: comment.user.avatarUrl,
          size: 32,
          onTap: onUserTap,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                comment.user.nickname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                comment.content,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _relativeTime(comment.createdAt),
                style: const TextStyle(color: AppTheme.textHint, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RatingStars extends StatelessWidget {
  const _RatingStars({required this.value, required this.size});

  final int value;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < 5; index++)
          Icon(
            index < value ? Icons.star : Icons.star_border,
            color: Colors.amber,
            size: size,
          ),
      ],
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
