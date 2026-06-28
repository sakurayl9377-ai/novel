import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../config/theme.dart';
import '../models/book_source.dart';
import '../providers/book_source_provider.dart';

class BookSourceManageScreen extends StatefulWidget {
  const BookSourceManageScreen({super.key});

  @override
  State<BookSourceManageScreen> createState() => _BookSourceManageScreenState();
}

class _BookSourceManageScreenState extends State<BookSourceManageScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showAddSourceDialog,
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt),
            onPressed: () {
              context.read<BookSourceProvider>().addDefaultSources();
            },
          ),
        ],
      ),
      body: Consumer<BookSourceProvider>(
        builder: (context, provider, _) {
          if (provider.sources.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(40),
                    ),
                    child: const Icon(
                      Icons.language,
                      size: 40,
                      color: AppTheme.primaryColor,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '暂无书源',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '点击右上角 + 添加书源',
                    style: TextStyle(fontSize: 13, color: AppTheme.textHint),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () =>
                        context.read<BookSourceProvider>().addDefaultSources(),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('添加默认书源'),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: provider.sources.length,
            separatorBuilder: (context, index) =>
                const Divider(height: 1, indent: 16, endIndent: 16),
            itemBuilder: (context, index) {
              final source = provider.sources[index];
              return _buildSourceItem(source, provider);
            },
          );
        },
      ),
    );
  }

  Widget _buildSourceItem(BookSource source, BookSourceProvider provider) {
    return Dismissible(
      key: Key(source.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => provider.deleteSource(source.id),
      child: ListTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: source.enabled
                ? AppTheme.primaryColor.withValues(alpha: 0.1)
                : AppTheme.textHint.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.language,
            color: source.enabled ? AppTheme.primaryColor : AppTheme.textHint,
          ),
        ),
        title: Text(
          source.name,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: source.enabled ? AppTheme.textPrimary : AppTheme.textHint,
          ),
        ),
        subtitle: Text(
          source.baseUrl,
          style: TextStyle(
            fontSize: 12,
            color: source.enabled ? AppTheme.textSecondary : AppTheme.textHint,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '权重: ${source.weight}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textHint),
            ),
            const SizedBox(width: 8),
            Switch(
              value: source.enabled,
              onChanged: (v) => provider.toggleSource(source.id, v),
              activeTrackColor: AppTheme.primaryColor.withValues(alpha: 0.5),
            ),
          ],
        ),
        onTap: () => _showEditSourceDialog(source),
      ),
    );
  }

  void _showAddSourceDialog() {
    _showSourceDialog(null);
  }

  void _showEditSourceDialog(BookSource source) {
    _showSourceDialog(source);
  }

  void _showSourceDialog(BookSource? existing) {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final urlController = TextEditingController(text: existing?.baseUrl ?? '');
    final searchController = TextEditingController(
      text: existing?.searchUrl ?? '',
    );
    final chapterController = TextEditingController(
      text: existing?.chapterListUrl ?? '',
    );
    final contentController = TextEditingController(
      text: existing?.contentUrl ?? '',
    );
    final isEditing = existing != null;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(isEditing ? '编辑书源' : '添加书源'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '书源名称',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: nameController,
                  decoration: _inputDecoration('例如：笔趣阁'),
                ),
                const SizedBox(height: 12),
                const Text(
                  '网站地址',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: urlController,
                  decoration: _inputDecoration('固定使用：https://www.bqg995.xyz'),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
                const Text(
                  '搜索地址（可选）',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: searchController,
                  decoration: _inputDecoration('使用 {keyword} 代替搜索词'),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
                const Text(
                  '章节列表地址（可选）',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: chapterController,
                  decoration: _inputDecoration('留空则从首页解析'),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
                const Text(
                  '内容地址（可选）',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: contentController,
                  decoration: _inputDecoration('留空则自动匹配'),
                  keyboardType: TextInputType.url,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (nameController.text.isEmpty || urlController.text.isEmpty) {
                  return;
                }

                final source = BookSource(
                  id: existing?.id ?? const Uuid().v4(),
                  name: nameController.text,
                  baseUrl: urlController.text,
                  searchUrl: searchController.text,
                  chapterListUrl: chapterController.text,
                  contentUrl: contentController.text,
                  enabled: existing?.enabled ?? true,
                  weight: existing?.weight ?? 0,
                );

                if (isEditing) {
                  await context.read<BookSourceProvider>().updateSource(source);
                } else {
                  await context.read<BookSourceProvider>().addSource(source);
                }

                if (ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text(isEditing ? '书源已更新' : '书源已添加'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: Text(isEditing ? '保存' : '添加'),
            ),
          ],
        );
      },
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textHint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.dividerColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.dividerColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.primaryColor, width: 1.5),
      ),
      isDense: true,
    );
  }
}
