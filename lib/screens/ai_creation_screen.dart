import 'dart:async';

import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/novel.dart';
import '../services/ai_creation_service.dart';
import '../widgets/book_cover_widget.dart';
import 'book_detail_screen.dart';

class AiCreationScreen extends StatefulWidget {
  const AiCreationScreen({super.key});

  @override
  State<AiCreationScreen> createState() => _AiCreationScreenState();
}

class _AiCreationScreenState extends State<AiCreationScreen> {
  final AiCreationService _service = AiCreationService();
  final TextEditingController _searchController = TextEditingController();
  List<Novel> _items = const [];
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({String query = ''}) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final items = await _service.fetchNovels(query: query);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  void _open(Novel novel) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetailScreen(novel: novel)),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 创作区')),
      body: RefreshIndicator(
        onRefresh: () => _load(query: _searchController.text),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
          children: [
            TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onSubmitted: (value) => _load(query: value),
              decoration: InputDecoration(
                hintText: '搜索 AI 原创小说或作者',
                prefixIcon: const Icon(Icons.auto_awesome_outlined),
                suffixIcon: IconButton(
                  onPressed: () => _load(query: _searchController.text),
                  icon: const Icon(Icons.search),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'AI 原创连载',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              '所有作品均由创作者投稿并经过管理员审核。',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error.isNotEmpty)
              _AiEmptyState(
                icon: Icons.cloud_off_outlined,
                message: _error,
                action: () => _load(query: _searchController.text),
              )
            else if (_items.isEmpty)
              const _AiEmptyState(
                icon: Icons.auto_stories_outlined,
                message: 'AI 创作区暂时还没有已发布作品',
              )
            else
              for (final novel in _items)
                _AiNovelCard(novel: novel, onTap: () => _open(novel)),
          ],
        ),
      ),
    );
  }
}

class _AiNovelCard extends StatelessWidget {
  const _AiNovelCard({required this.novel, required this.onTap});

  final Novel novel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 82,
                height: 110,
                child: BookCoverWidget.fill(novel: novel),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      novel.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      novel.author,
                      style: const TextStyle(color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      novel.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        height: 1.45,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${novel.chapterCount} 章 · ${novel.status}',
                      style: const TextStyle(color: AppTheme.primaryColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AiEmptyState extends StatelessWidget {
  const _AiEmptyState({required this.icon, required this.message, this.action});

  final IconData icon;
  final String message;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        children: [
          Icon(icon, size: 54, color: AppTheme.textHint),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: action, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}
