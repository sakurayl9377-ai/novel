import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

class LocalImportService {
  final Uuid _uuid = const Uuid();

  Future<Map<String, dynamic>?> importLocalFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return null;

      final file = result.files.first;
      final filePath = file.path;
      if (filePath == null) return null;

      final fileName = file.name;

      // 提取书名
      String bookName = fileName;
      if (bookName.toLowerCase().endsWith('.txt')) {
        bookName = bookName.substring(0, bookName.length - 4);
      }

      // 读取文件内容（优先 UTF-8，失败则 fallback）
      String content;
      try {
        content = await File(filePath).readAsString(encoding: utf8);
      } catch (_) {
        try {
          final bytes = await File(filePath).readAsBytes();
          content = utf8.decode(bytes, allowMalformed: true);
        } catch (_) {
          content = '';
        }
      }

      final novelId = _uuid.v4();

      // 复制文件到应用存储
      final appDirDir = Directory('${_getAppDirPath()}$novelId');
      if (!await appDirDir.exists()) {
        await appDirDir.create(recursive: true);
      }
      final destPath = '${appDirDir.path}/$fileName';
      await File(filePath).copy(destPath);

      // 解析章节
      final chapters = _parseChapters(content, novelId);

      return {
        'novel': {
          'id': novelId,
          'title': bookName,
          'author': '本地导入',
          'isLocal': true,
          'localPath': destPath,
          'status': '已完结',
          'addedAt': DateTime.now().toIso8601String(),
          'lastReadAt': DateTime.now().toIso8601String(),
        },
        'chapters': chapters,
      };
    } catch (e) {
      return null;
    }
  }

  String _getAppDirPath() {
    // 使用临时目录或应用文档目录的替代方案
    final dir = Directory.systemTemp.path;
    return '$dir/novel_app/local_books/';
  }

  List<Map<String, dynamic>> _parseChapters(String content, String novelId) {
    if (content.isEmpty) {
      return [
        {
          'id': '${novelId}_ch0',
          'novelId': novelId,
          'title': '正文',
          'content': '',
          'index': 0,
          'isLoaded': true,
        }
      ];
    }

    final chapterPattern = RegExp(
      r'(第[一二三四五六七八九十百千万零\d]+章[^\n]*'
      r'|第[一二三四五六七八九十百千万零\d]+节[^\n]*'
      r'|前言|楔子|序章|尾声|后记|番外[^\n]*)',
    );

    final matches = chapterPattern.allMatches(content).toList();
    if (matches.isEmpty) {
      return [
        {
          'id': '${novelId}_ch0',
          'novelId': novelId,
          'title': '全文',
          'content': content,
          'index': 0,
          'isLoaded': true,
        }
      ];
    }

    final chapters = <Map<String, dynamic>>[];
    for (int i = 0; i < matches.length; i++) {
      final start = matches[i].start;
      final title = matches[i].group(0) ?? '第${i + 1}章';
      final end = i + 1 < matches.length ? matches[i + 1].start : content.length;
      final chapterContent = content.substring(start, end).trim();

      chapters.add({
        'id': '${novelId}_ch$i',
        'novelId': novelId,
        'title': title,
        'content': chapterContent,
        'index': i,
        'isLoaded': true,
      });
    }

    return chapters;
  }
}
