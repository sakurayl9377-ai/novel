import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/local_library.dart';
import 'package:novel_app/services/download_manager_service.dart';

void main() {
  test('an interrupted manga download resumes from the persistent queue', () {
    const interrupted = DownloadItem(
      id: 'manga-resume',
      type: LibraryItemType.manga,
      itemId: 'book-1',
      title: 'Book',
      coverUrl: '',
      chapterTitle: 'Chapter 1',
      chapterUrl: 'https://example.com/chapter-1',
      cachedCount: 8,
      totalCount: 20,
      downloadedBytes: 1024,
      totalBytes: 4096,
      localPath: 'downloads/manga-resume/chapter.json',
      errorMessage: 'stale transient error',
      createdAtMs: 10,
      updatedAtMs: 20,
      status: 'downloading',
    );

    final recovered = recoverInterruptedDownload(
      interrupted,
      recoveredAtMs: 30,
    );

    expect(recovered.status, 'queued');
    expect(recovered.errorMessage, isEmpty);
    expect(recovered.updatedAtMs, 30);
    expect(recovered.cachedCount, 8);
    expect(recovered.downloadedBytes, 1024);
    expect(recovered.localPath, interrupted.localPath);
  });

  test('paused and completed downloads keep their explicit state', () {
    DownloadItem item(String status) => DownloadItem(
      id: status,
      type: LibraryItemType.manga,
      itemId: 'book-1',
      title: 'Book',
      coverUrl: '',
      createdAtMs: 10,
      updatedAtMs: 20,
      status: status,
    );

    expect(
      recoverInterruptedDownload(item('paused'), recoveredAtMs: 30).status,
      'paused',
    );
    expect(
      recoverInterruptedDownload(item('done'), recoveredAtMs: 30).status,
      'done',
    );
  });
}
