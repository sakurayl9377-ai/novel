import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/modao_game_service.dart';

class ModaoGameScreen extends StatefulWidget {
  const ModaoGameScreen({super.key, required this.token, this.service});

  final String token;
  final ModaoGameService? service;

  @override
  State<ModaoGameScreen> createState() => _ModaoGameScreenState();
}

class _ModaoGameScreenState extends State<ModaoGameScreen>
    with WidgetsBindingObserver {
  late final ModaoGameService _service;
  ModaoGameManifest? _manifest;
  ModaoInstalledGame _installed = const ModaoInstalledGame.notInstalled();
  ModaoDownloadState _download = const ModaoDownloadState.none();
  Timer? _pollTimer;
  bool _loading = true;
  bool _busy = false;
  bool _downloadVerified = false;
  bool _polling = false;
  bool _waitingForInstallPermission = false;
  String _busyLabel = '';
  String? _error;
  DateTime? _speedSampleAt;
  int _speedSampleBytes = 0;
  double _bytesPerSecond = 0;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? ModaoGameService();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_waitingForInstallPermission) {
      unawaited(_resumeInstallAfterPermission());
    } else {
      unawaited(_refreshDeviceState());
    }
  }

  Future<void> _load() async {
    _pollTimer?.cancel();
    var verificationAttempted = false;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final manifest = await _service.fetchManifest();
      final installed = await _service.getInstalledGame();
      var download = await _service.getDownloadState();
      if (_canMigrateDownloadManager(download, manifest)) {
        download = await _migrateDownloadManager(
          download,
          manifest,
          promptForMetered: true,
        );
      } else if (_canResumeAppHttpDownload(download, manifest)) {
        download = await _resumeAppHttpDownload(
          download,
          manifest,
          promptForMetered: true,
        );
      } else if (_requiresSegmentedDownloadMigration(download, manifest)) {
        await _service.clearDownload();
        download = const ModaoDownloadState.none();
      }
      if (_downloadBelongsToAnotherVersion(download, manifest)) {
        await _service.clearDownload();
        download = const ModaoDownloadState.none();
      }
      var verified = false;
      if (installed.isCurrentFor(manifest) &&
          download.status == ModaoDownloadStatus.completed) {
        await _service.clearDownload();
        download = const ModaoDownloadState.none();
      } else if (download.status == ModaoDownloadStatus.completed) {
        verificationAttempted = true;
        _setBusyLabel('正在校验安装包');
        await _service.verifyDownloadedApk(manifest, download.localPath);
        verified = true;
      }
      if (!mounted) return;
      setState(() {
        _manifest = manifest;
        _installed = installed;
        _download = download;
        _downloadVerified = verified;
        _loading = false;
        _busy = false;
        _error = download.status == ModaoDownloadStatus.failed
            ? (download.reason.isEmpty ? '游戏下载失败，请重试' : download.reason)
            : null;
      });
      if (download.isActive) _startPolling();
    } catch (error) {
      if (!mounted) return;
      if (verificationAttempted) {
        await _service.clearDownload().catchError((_) {});
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _busy = false;
        _download = const ModaoDownloadState.none();
        _downloadVerified = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _refreshDeviceState() async {
    final manifest = _manifest;
    if (!mounted || manifest == null || _loading || _busy) return;
    try {
      final installed = await _service.getInstalledGame();
      var download = await _service.getDownloadState();
      if (_canMigrateDownloadManager(download, manifest)) {
        download = await _migrateDownloadManager(
          download,
          manifest,
          promptForMetered: false,
        );
      } else if (_canResumeAppHttpDownload(download, manifest)) {
        download = await _resumeAppHttpDownload(
          download,
          manifest,
          promptForMetered: false,
        );
      } else if (_requiresSegmentedDownloadMigration(download, manifest)) {
        await _service.clearDownload();
        download = const ModaoDownloadState.none();
      }
      if (_downloadBelongsToAnotherVersion(download, manifest)) {
        await _service.clearDownload();
        download = const ModaoDownloadState.none();
      }
      if (installed.isCurrentFor(manifest) &&
          download.status == ModaoDownloadStatus.completed) {
        await _service.clearDownload();
        download = const ModaoDownloadState.none();
      }
      if (!mounted) return;
      setState(() {
        _installed = installed;
        _download = download;
        if (download.status != ModaoDownloadStatus.completed) {
          _downloadVerified = false;
        }
      });
      if (download.isActive) _startPolling();
    } catch (_) {
      // Resume refresh is best-effort; the explicit retry remains available.
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _bytesPerSecond = 0;
    _speedSampleAt = DateTime.now();
    _speedSampleBytes = _download.downloadedBytes;
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_pollDownload()),
    );
  }

  Future<void> _pollDownload() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final next = await _service.getDownloadState();
      _updateSpeed(next.downloadedBytes);
      if (!mounted) return;
      setState(() => _download = next);
      if (next.status == ModaoDownloadStatus.completed) {
        _pollTimer?.cancel();
        await _verifyCompletedDownload(next);
      } else if (next.status == ModaoDownloadStatus.failed) {
        _pollTimer?.cancel();
        if (mounted) {
          setState(() {
            _error = next.reason.isEmpty ? '游戏下载失败，请重试' : next.reason;
          });
        }
      }
    } catch (error) {
      _pollTimer?.cancel();
      if (mounted) setState(() => _error = _messageFor(error));
    } finally {
      _polling = false;
    }
  }

  void _updateSpeed(int downloadedBytes) {
    final now = DateTime.now();
    final previous = _speedSampleAt;
    if (previous != null) {
      final seconds = now.difference(previous).inMilliseconds / 1000;
      if (seconds > 0) {
        final current =
            math.max(0, downloadedBytes - _speedSampleBytes) / seconds;
        _bytesPerSecond = _bytesPerSecond == 0
            ? current
            : (_bytesPerSecond * 0.65) + (current * 0.35);
      }
    }
    _speedSampleAt = now;
    _speedSampleBytes = downloadedBytes;
  }

  Future<void> _verifyCompletedDownload(ModaoDownloadState download) async {
    final manifest = _manifest;
    if (manifest == null) return;
    setState(() {
      _busy = true;
      _busyLabel = '正在校验安装包';
      _error = null;
    });
    try {
      await _service.verifyDownloadedApk(manifest, download.localPath);
      if (!mounted) return;
      setState(() {
        _downloadVerified = true;
        _busy = false;
      });
    } catch (error) {
      await _service.clearDownload().catchError((_) {});
      if (!mounted) return;
      setState(() {
        _download = const ModaoDownloadState.none();
        _downloadVerified = false;
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _beginDownload() async {
    final manifest = _manifest;
    if (manifest == null || _busy) return;
    setState(() {
      _busy = true;
      _busyLabel = '正在检查设备';
      _error = null;
    });
    try {
      final environment = await _service.getDeviceEnvironment();
      if (!environment.connected || !environment.validated) {
        throw const ModaoGameException('当前网络不可用，请检查网络连接');
      }
      final requiredBytes = calculateModaoRequiredFreeBytes(
        apkSizeBytes: manifest.sizeBytes,
        partSizeBytes: manifest.parts.map((part) => part.sizeBytes),
        retainedBytes:
            _download.status == ModaoDownloadStatus.failed &&
                _download.segmented &&
                !_downloadBelongsToAnotherVersion(_download, manifest)
            ? _download.retainedBytes
            : 0,
      );
      if (environment.freeBytes < requiredBytes) {
        throw ModaoGameException(
          '存储空间不足，至少需要 ${_formatBytes(requiredBytes)} 可用空间',
        );
      }
      var allowMetered = false;
      if (environment.metered) {
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('使用移动网络下载？'),
            content: Text('本次下载约 ${_formatBytes(manifest.sizeBytes)}。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('继续下载'),
              ),
            ],
          ),
        );
        if (confirmed != true) {
          setState(() => _busy = false);
          return;
        }
        allowMetered = true;
      }
      final download = await _service.startDownload(
        manifest,
        allowMetered: allowMetered,
      );
      if (!mounted) return;
      setState(() {
        _download = download;
        _downloadVerified = false;
        _busy = false;
      });
      _startPolling();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _cancelDownload() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = '正在取消下载';
    });
    try {
      await _service.clearDownload();
      _pollTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _download = const ModaoDownloadState.none();
        _downloadVerified = false;
        _busy = false;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _messageFor(error);
        });
      }
    }
  }

  Future<void> _install() async {
    if (_busy || !_downloadVerified) return;
    final allowed = await _service.canInstallPackages();
    if (!allowed) {
      _waitingForInstallPermission = true;
      final opened = await _service.openInstallPermissionSettings();
      if (!opened && mounted) {
        _waitingForInstallPermission = false;
        setState(() => _error = '无法打开安装权限设置');
      }
      return;
    }
    await _performInstall();
  }

  Future<void> _resumeInstallAfterPermission() async {
    if (!_waitingForInstallPermission) return;
    final allowed = await _service.canInstallPackages().catchError(
      (_) => false,
    );
    if (!allowed) return;
    _waitingForInstallPermission = false;
    await _performInstall();
  }

  Future<void> _performInstall() async {
    final manifest = _manifest;
    if (manifest == null || _download.localPath.isEmpty) return;
    setState(() {
      _busy = true;
      _busyLabel = '正在准备安装';
      _error = null;
    });
    try {
      await _service.verifyDownloadedApk(manifest, _download.localPath);
      await _service.installApk(_download.localPath);
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _launch() async {
    final manifest = _manifest;
    if (_busy || manifest == null || !_installed.isCurrentFor(manifest)) return;
    setState(() {
      _busy = true;
      _busyLabel = '正在登录游戏';
      _error = null;
    });
    try {
      final ticket = await _service.createSsoTicket(widget.token);
      await _service.launchGame(ticket);
      if (mounted) setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  void _setBusyLabel(String label) {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _busyLabel = label;
    });
  }

  String _messageFor(Object error) {
    if (error is ModaoGameException) return error.message;
    if (error is PlatformException &&
        error.message?.trim().isNotEmpty == true) {
      return error.message!.trim();
    }
    return '操作失败，请稍后重试';
  }

  bool _downloadBelongsToAnotherVersion(
    ModaoDownloadState download,
    ModaoGameManifest manifest,
  ) {
    if (download.localPath.isEmpty) return false;
    final path = download.localPath.replaceAll('\\', '/');
    final separator = path.lastIndexOf('/');
    final fileName = separator >= 0 ? path.substring(separator + 1) : path;
    return fileName.isNotEmpty && fileName != manifest.downloadFileName;
  }

  bool _requiresSegmentedDownloadMigration(
    ModaoDownloadState download,
    ModaoGameManifest manifest,
  ) {
    if (manifest.parts.isEmpty ||
        download.status == ModaoDownloadStatus.none ||
        download.status == ModaoDownloadStatus.completed) {
      return false;
    }
    return download.transport != 'app_http' ||
        !download.segmented ||
        download.partCount != manifest.parts.length;
  }

  bool _canMigrateDownloadManager(
    ModaoDownloadState download,
    ModaoGameManifest manifest,
  ) {
    return manifest.parts.isNotEmpty &&
        download.status != ModaoDownloadStatus.none &&
        download.status != ModaoDownloadStatus.completed &&
        download.transport == 'download_manager' &&
        download.segmented &&
        download.partCount == manifest.parts.length &&
        (download.artifactKey.isEmpty ||
            download.artifactKey == manifest.artifactKey) &&
        !_downloadBelongsToAnotherVersion(download, manifest);
  }

  bool _canResumeAppHttpDownload(
    ModaoDownloadState download,
    ModaoGameManifest manifest,
  ) {
    return manifest.parts.isNotEmpty &&
        download.downloadedBytes > 0 &&
        download.status != ModaoDownloadStatus.none &&
        download.status != ModaoDownloadStatus.completed &&
        download.status != ModaoDownloadStatus.merging &&
        download.transport == 'app_http' &&
        download.segmented &&
        download.partCount == manifest.parts.length &&
        download.artifactKey == manifest.artifactKey &&
        !_downloadBelongsToAnotherVersion(download, manifest);
  }

  Future<ModaoDownloadState> _resumeAppHttpDownload(
    ModaoDownloadState current,
    ModaoGameManifest manifest, {
    required bool promptForMetered,
  }) async {
    final ModaoDeviceEnvironment environment;
    try {
      environment = await _service.getDeviceEnvironment();
    } catch (_) {
      return current;
    }
    if (!environment.connected || !environment.validated) return current;
    var allowMetered = false;
    if (environment.metered) {
      if (!promptForMetered || !mounted) return current;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('使用移动网络继续下载？'),
          content: Text('游戏安装包约 ${_formatBytes(manifest.sizeBytes)}。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('暂不继续'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续下载'),
            ),
          ],
        ),
      );
      if (confirmed != true) return current;
      allowMetered = true;
    }
    return _service.startDownload(manifest, allowMetered: allowMetered);
  }

  Future<ModaoDownloadState> _migrateDownloadManager(
    ModaoDownloadState current,
    ModaoGameManifest manifest, {
    required bool promptForMetered,
  }) async {
    final ModaoDeviceEnvironment environment;
    try {
      environment = await _service.getDeviceEnvironment();
    } catch (_) {
      return current;
    }
    if (!environment.connected || !environment.validated) return current;
    var allowMetered = false;
    if (environment.metered) {
      if (!promptForMetered || !mounted) return current;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('使用移动网络继续下载？'),
          content: Text('游戏安装包约 ${_formatBytes(manifest.sizeBytes)}。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('暂不迁移'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续下载'),
            ),
          ],
        ),
      );
      if (confirmed != true) return current;
      allowMetered = true;
    }
    return _service.startDownload(manifest, allowMetered: allowMetered);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C0D1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0C0D1A),
        foregroundColor: Colors.white,
        title: const Text('魔道修仙'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 32),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: _content(),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _content() {
    final manifest = _manifest;
    if (manifest == null) {
      return _ErrorState(message: _error ?? '游戏版本信息暂时不可用', onRetry: _load);
    }
    final trustedInstalled = _installed.isTrustedFor(manifest);
    final currentInstalled = _installed.isCurrentFor(manifest);
    final signatureConflict = _installed.installed && !trustedInstalled;
    final progressTotal = _download.totalBytes > 0
        ? _download.totalBytes
        : manifest.sizeBytes;
    final progress = progressTotal <= 0
        ? 0.0
        : (_download.downloadedBytes / progressTotal).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF181B27),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0x335BD6A8)),
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 58,
                height: 58,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xFF214A3B),
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Icon(
                    Icons.forest_rounded,
                    color: Color(0xFF8DE0B9),
                    size: 32,
                  ),
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '魔道修仙',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _statusText(manifest),
                      style: const TextStyle(
                        color: Color(0xFFADB0C0),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              _StatusBadge(label: currentInstalled ? '已安装' : '待安装'),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: _InfoItem(
                label: '最新版本',
                value: '${manifest.versionName} (${manifest.versionCode})',
              ),
            ),
            Expanded(
              child: _InfoItem(
                label: '下载大小',
                value: _formatBytes(manifest.sizeBytes),
              ),
            ),
          ],
        ),
        if (_download.isActive ||
            _download.status == ModaoDownloadStatus.completed) ...[
          const SizedBox(height: 24),
          LinearProgressIndicator(
            minHeight: 7,
            borderRadius: BorderRadius.circular(4),
            value: _download.status == ModaoDownloadStatus.queued
                ? null
                : progress,
            backgroundColor: const Color(0xFF292D3B),
            color: const Color(0xFF60D6A6),
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: Text(
                  _downloadLabel(),
                  style: const TextStyle(
                    color: Color(0xFFB9BDCA),
                    fontSize: 12,
                  ),
                ),
              ),
              Text(
                '${_formatBytes(_download.downloadedBytes)} / ${_formatBytes(progressTotal)}',
                style: const TextStyle(color: Color(0xFF808596), fontSize: 12),
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        _CheckRow(
          icon: Icons.verified_user_rounded,
          label: signatureConflict
              ? '已安装游戏签名不一致'
              : currentInstalled || _downloadVerified
              ? '游戏签名已验证'
              : '安装前验证游戏签名',
          ok: !signatureConflict,
        ),
        const SizedBox(height: 10),
        _CheckRow(
          icon: Icons.fingerprint_rounded,
          label: _downloadVerified ? '安装包完整性已验证' : '安装前校验 SHA-256',
          ok: !signatureConflict,
        ),
        if (manifest.notes.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text(
            '版本内容',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          ...manifest.notes.map(
            (note) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '• $note',
                style: const TextStyle(color: Color(0xFFA8ACBA), height: 1.4),
              ),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 20),
          _InlineError(message: _error!),
        ],
        const SizedBox(height: 24),
        _actionButton(
          manifest: manifest,
          currentInstalled: currentInstalled,
          signatureConflict: signatureConflict,
        ),
        if (_download.isActive) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _cancelDownload,
            icon: const Icon(Icons.close_rounded),
            label: const Text('取消下载'),
          ),
        ],
      ],
    );
  }

  Widget _actionButton({
    required ModaoGameManifest manifest,
    required bool currentInstalled,
    required bool signatureConflict,
  }) {
    if (_busy) {
      return FilledButton.icon(
        onPressed: null,
        icon: const SizedBox(
          width: 17,
          height: 17,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text(_busyLabel),
      );
    }
    if (signatureConflict) {
      return FilledButton.icon(
        onPressed: null,
        icon: const Icon(Icons.block_rounded),
        label: const Text('已阻止启动'),
      );
    }
    if (currentInstalled) {
      return FilledButton.icon(
        key: const ValueKey<String>('modao-launch-button'),
        onPressed: _launch,
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('进入游戏'),
      );
    }
    if (_downloadVerified) {
      return FilledButton.icon(
        key: const ValueKey<String>('modao-install-button'),
        onPressed: _install,
        icon: const Icon(Icons.install_mobile_rounded),
        label: Text(_installed.installed ? '安装更新' : '安装游戏'),
      );
    }
    if (_download.isActive) {
      return FilledButton.icon(
        onPressed: null,
        icon: const Icon(Icons.downloading_rounded),
        label: Text(
          _download.status == ModaoDownloadStatus.paused ? '等待继续下载' : '正在下载',
        ),
      );
    }
    return FilledButton.icon(
      key: const ValueKey<String>('modao-download-button'),
      onPressed: _beginDownload,
      icon: const Icon(Icons.download_rounded),
      label: Text(_installed.installed ? '下载更新' : '下载游戏'),
    );
  }

  String _statusText(ModaoGameManifest manifest) {
    if (_installed.isCurrentFor(manifest)) {
      return '版本 ${_installed.versionName}';
    }
    if (_installed.installed && !_installed.isTrustedFor(manifest)) {
      return '安全校验未通过';
    }
    if (_downloadVerified) return '安装包已就绪';
    if (_download.isActive) return _downloadLabel();
    if (_installed.installed) return '当前版本 ${_installed.versionName}';
    return '东方玄幻放置冒险';
  }

  String _downloadLabel() {
    return switch (_download.status) {
      ModaoDownloadStatus.queued => '等待下载',
      ModaoDownloadStatus.paused =>
        _download.reason.isEmpty ? '下载已暂停' : _download.reason,
      ModaoDownloadStatus.completed => _downloadVerified ? '校验完成' : '下载完成',
      ModaoDownloadStatus.failed => '下载失败',
      ModaoDownloadStatus.merging => '正在合并安装包',
      ModaoDownloadStatus.downloading =>
        _bytesPerSecond > 0
            ? '下载中 · ${_formatBytes(_bytesPerSecond.round())}/s${_remainingTimeLabel()}'
            : '下载中 · 正在估算剩余时间',
      ModaoDownloadStatus.none => '',
    };
  }

  String _remainingTimeLabel() {
    final remainingBytes = math.max(
      0,
      _download.totalBytes - _download.downloadedBytes,
    );
    if (remainingBytes <= 0 || _bytesPerSecond <= 0) return '';
    final eta = formatModaoDownloadEta(remainingBytes / _bytesPerSecond);
    return eta.isEmpty ? '' : ' · 预计剩余 $eta';
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x1F60D6A6),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x4460D6A6)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF8DE0B9),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _InfoItem extends StatelessWidget {
  const _InfoItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Color(0xFF777C8D), fontSize: 11),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.icon, required this.label, required this.ok});

  final IconData icon;
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? const Color(0xFF76CFA8) : const Color(0xFFFF8C8C);
    return Row(
      children: [
        Icon(icon, color: color, size: 19),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: TextStyle(color: color, fontSize: 13)),
        ),
      ],
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x1FFF5E6C),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x4DFF5E6C)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFFF8992),
            size: 19,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFFFFB5BA)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 100),
      child: Column(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            color: Color(0xFF8B90A0),
            size: 42,
          ),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value >= 100
      ? 0
      : value >= 10
      ? 1
      : 2;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

int calculateModaoRequiredFreeBytes({
  required int apkSizeBytes,
  Iterable<int> partSizeBytes = const <int>[],
  int retainedBytes = 0,
}) {
  const maxLong = 0x7FFFFFFFFFFFFFFF;
  const minimumReserveBytes = 512 * 1024 * 1024;
  final boundedApkSize = apkSizeBytes.clamp(0, maxLong);
  final boundedRetainedBytes = retainedBytes.clamp(0, boundedApkSize);
  final remainingDownloadBytes = boundedApkSize - boundedRetainedBytes;
  final tenPercentReserve =
      (boundedApkSize ~/ 10) + (boundedApkSize % 10 == 0 ? 0 : 1);
  var largestPartSize = 0;
  for (final partSize in partSizeBytes) {
    largestPartSize = math.max(largestPartSize, partSize.clamp(0, maxLong));
  }
  final reserveBytes = math.max(
    minimumReserveBytes,
    math.max(largestPartSize, tenPercentReserve),
  );
  if (remainingDownloadBytes > maxLong - reserveBytes) return maxLong;
  return remainingDownloadBytes + reserveBytes;
}

String formatModaoDownloadEta(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return '';
  final rounded = seconds.ceil();
  if (rounded < 60) return '$rounded秒';
  final minutes = (rounded / 60).ceil();
  if (minutes < 60) return '$minutes分钟';
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return remainingMinutes == 0 ? '$hours小时' : '$hours小时$remainingMinutes分钟';
}
