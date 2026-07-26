import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/kdjx_game_service.dart';

class KdjxGameScreen extends StatefulWidget {
  const KdjxGameScreen({super.key, required this.expectedUserId, this.service});

  static const Key downloadButtonKey = ValueKey<String>('kdjx-download-button');
  static const Key installButtonKey = ValueKey<String>('kdjx-install-button');
  static const Key launchButtonKey = ValueKey<String>('kdjx-launch-button');

  final String expectedUserId;
  final KdjxGameService? service;

  @override
  State<KdjxGameScreen> createState() => _KdjxGameScreenState();
}

class _KdjxGameScreenState extends State<KdjxGameScreen>
    with WidgetsBindingObserver {
  late final KdjxGameService _service;
  KdjxGameManifest? _manifest;
  KdjxInstalledGame _installed = const KdjxInstalledGame.notInstalled();
  KdjxDownloadState _download = const KdjxDownloadState.none();
  Timer? _downloadPoller;
  bool _loading = true;
  bool _busy = false;
  bool _downloadVerified = false;
  bool _polling = false;
  String _busyLabel = '';
  String? _error;
  DateTime? _speedSampleAt;
  int _speedSampleBytes = 0;
  double _bytesPerSecond = 0;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? KdjxGameService();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _downloadPoller?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) {
      unawaited(_refresh(showLoading: false));
    }
  }

  Future<void> _refresh({bool showLoading = true}) async {
    if (showLoading && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final manifest = await _service.fetchManifest();
      final installed = await _service.getInstalledGame();
      var download = await _service.getDownloadState();
      if (download.status == KdjxDownloadStatus.completed &&
          download.localPath.isNotEmpty) {
        try {
          await _service.verifyDownloadedApk(manifest, download.localPath);
          _downloadVerified = true;
        } catch (_) {
          await _service.clearDownload();
          download = const KdjxDownloadState.none();
          _downloadVerified = false;
        }
      }
      if (!mounted) return;
      setState(() {
        _manifest = manifest;
        _installed = installed;
        _download = download;
        _loading = false;
        _error = download.status == KdjxDownloadStatus.failed
            ? (download.reason.isEmpty ? '游戏下载失败，请重试' : download.reason)
            : null;
      });
      _syncDownloadPoller();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _messageFor(error);
      });
    }
  }

  void _syncDownloadPoller() {
    if (_download.isActive) {
      if (_downloadPoller == null) {
        _bytesPerSecond = 0;
        _speedSampleAt = DateTime.now();
        _speedSampleBytes = _download.downloadedBytes;
        _downloadPoller = Timer.periodic(
          const Duration(seconds: 1),
          (_) => unawaited(_pollDownload()),
        );
      }
    } else {
      _downloadPoller?.cancel();
      _downloadPoller = null;
    }
  }

  Future<void> _pollDownload() async {
    if (_busy || _polling) return;
    _polling = true;
    try {
      final next = await _service.getDownloadState();
      _updateSpeed(next.downloadedBytes);
      if (!mounted) return;
      setState(() => _download = next);
      if (next.status == KdjxDownloadStatus.completed) {
        _downloadPoller?.cancel();
        _downloadPoller = null;
        await _verifyCompletedDownload();
      } else if (next.status == KdjxDownloadStatus.failed) {
        _downloadPoller?.cancel();
        _downloadPoller = null;
        setState(() {
          _error = next.reason.isEmpty ? '游戏下载失败，请重试' : next.reason;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _messageFor(error));
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

  Future<void> _verifyCompletedDownload() async {
    final manifest = _manifest;
    if (manifest == null || _download.localPath.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _busyLabel = '正在校验完整安装包';
      _error = null;
    });
    try {
      await _service.verifyDownloadedApk(manifest, _download.localPath);
      if (!mounted) return;
      setState(() {
        _downloadVerified = true;
        _busy = false;
      });
    } catch (error) {
      await _service.clearDownload();
      if (!mounted) return;
      setState(() {
        _download = const KdjxDownloadState.none();
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
      _busyLabel = '正在检查下载条件';
      _error = null;
    });
    try {
      final environment = await _service.getDeviceEnvironment();
      if (!environment.connected || !environment.validated) {
        throw const KdjxGameException('当前网络不可用，请检查网络连接');
      }
      final requiredBytes = manifest.sizeBytes * 2 + 512 * 1024 * 1024;
      if (environment.freeBytes < requiredBytes) {
        throw KdjxGameException(
          '存储空间不足，分片下载和拼接至少需要 ${_formatBytes(requiredBytes)} 可用空间',
        );
      }
      var allowMetered = false;
      if (environment.metered) {
        if (!mounted) return;
        allowMetered =
            await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('使用移动网络下载？'),
                content: Text(
                  '安装包约 ${_formatBytes(manifest.sizeBytes)}，将通过 5 条分片线路下载。',
                ),
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
            ) ??
            false;
        if (!allowMetered) {
          if (mounted) setState(() => _busy = false);
          return;
        }
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
      _syncDownloadPoller();
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
      if (!mounted) return;
      setState(() {
        _download = const KdjxDownloadState.none();
        _downloadVerified = false;
        _busy = false;
      });
      _syncDownloadPoller();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _install() async {
    if (_busy || !_downloadVerified || _download.localPath.isEmpty) return;
    setState(() {
      _busy = true;
      _busyLabel = '正在准备安装';
      _error = null;
    });
    try {
      if (!await _service.canInstallPackages()) {
        final opened = await _service.openInstallPermissionSettings();
        if (!opened) throw const KdjxGameException('无法打开安装权限设置');
        if (mounted) setState(() => _busy = false);
        return;
      }
      await _service.installApk(_download.localPath);
      if (mounted) setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _launch() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = '正在通过 Sakura 授权';
      _error = null;
    });
    try {
      await _service.launchGame(widget.expectedUserId);
      if (!mounted) return;
      setState(() {
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  String _messageFor(Object error) =>
      error is KdjxGameException ? error.message : '操作失败，请稍后重试';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101317),
      appBar: AppBar(
        backgroundColor: const Color(0xFF101317),
        foregroundColor: Colors.white,
        title: const Text('口袋觉醒'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _busy ? null : () => _refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
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
      ),
    );
  }

  Widget _content() {
    final manifest = _manifest;
    if (manifest == null) {
      return _ErrorPanel(
        message: _error ?? '版本信息加载失败',
        onRetry: _busy ? null : _refresh,
      );
    }
    final trustedInstalled = _installed.isTrustedFor(manifest);
    final currentInstalled = _installed.isCurrentFor(manifest);
    final signatureConflict = _installed.installed && !trustedInstalled;
    final progressTotal = _download.totalBytes > 0
        ? _download.totalBytes
        : manifest.sizeBytes;
    final progress = progressTotal > 0
        ? (_download.downloadedBytes / progressTotal).clamp(0.0, 1.0)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: const Color(0xFFE94C4C),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.catching_pokemon_rounded,
                color: Colors.white,
                size: 36,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '口袋觉醒',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _statusText(manifest),
                    style: const TextStyle(color: Color(0xFFAAB2BE)),
                  ),
                ],
              ),
            ),
            _StatusBadge(label: currentInstalled ? '已就绪' : '需更新'),
          ],
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFF181D23),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF303841)),
          ),
          child: Column(
            children: [
              _InfoRow(label: '最新版本', value: manifest.versionName),
              const Divider(height: 25, color: Color(0xFF303841)),
              _InfoRow(label: '安装包大小', value: _formatBytes(manifest.sizeBytes)),
              const Divider(height: 25, color: Color(0xFF303841)),
              _InfoRow(
                label: '下载方式',
                value: manifest.parts.isEmpty
                    ? '整包安全下载'
                    : '${manifest.parts.length} 路分片并发',
              ),
              const Divider(height: 25, color: Color(0xFF303841)),
              const _InfoRow(label: '登录方式', value: 'Sakura App 授权'),
            ],
          ),
        ),
        if (_download.isActive ||
            _download.status == KdjxDownloadStatus.completed) ...[
          const SizedBox(height: 18),
          LinearProgressIndicator(value: progress, minHeight: 7),
          const SizedBox(height: 8),
          Text(
            _downloadLabel(),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFB8C2CE), fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '${_formatBytes(_download.downloadedBytes)} / '
            '${_formatBytes(progressTotal)}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF7F8B98), fontSize: 12),
          ),
        ],
        const SizedBox(height: 18),
        _CheckLine(
          ok: !signatureConflict,
          label: signatureConflict ? '已安装游戏签名不受信任' : '安装包签名固定校验',
        ),
        const SizedBox(height: 10),
        _CheckLine(
          ok: _downloadVerified || currentInstalled,
          label: currentInstalled
              ? '当前版本完整性已确认'
              : _downloadVerified
              ? '五片独立校验和整包校验均通过'
              : '安装前校验每片与整包 SHA-256',
        ),
        if (_error != null) ...[
          const SizedBox(height: 18),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFFF8585)),
          ),
        ],
        const SizedBox(height: 22),
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
    required KdjxGameManifest manifest,
    required bool currentInstalled,
    required bool signatureConflict,
  }) {
    if (_busy) {
      return FilledButton.icon(
        onPressed: null,
        icon: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text(_busyLabel),
      );
    }
    if (signatureConflict) {
      return FilledButton.icon(
        onPressed: null,
        icon: Icon(Icons.block_rounded),
        label: Text('已阻止启动'),
      );
    }
    if (currentInstalled) {
      return FilledButton.icon(
        key: KdjxGameScreen.launchButtonKey,
        onPressed: _launch,
        icon: const Icon(Icons.login_rounded),
        label: const Text('使用 Sakura 登录'),
      );
    }
    if (_downloadVerified) {
      return FilledButton.icon(
        key: KdjxGameScreen.installButtonKey,
        onPressed: _install,
        icon: const Icon(Icons.install_mobile_rounded),
        label: Text(_installed.installed ? '安装热更新' : '安装游戏'),
      );
    }
    if (_download.isActive) {
      return FilledButton.icon(
        onPressed: null,
        icon: Icon(Icons.downloading_rounded),
        label: Text('正在下载'),
      );
    }
    return FilledButton.icon(
      key: KdjxGameScreen.downloadButtonKey,
      onPressed: _beginDownload,
      icon: const Icon(Icons.download_rounded),
      label: Text(_installed.installed ? '下载热更新' : '下载游戏'),
    );
  }

  String _statusText(KdjxGameManifest manifest) {
    if (_installed.isCurrentFor(manifest)) {
      return '版本 ${_installed.versionName}';
    }
    if (_installed.installed && !_installed.isTrustedFor(manifest)) {
      return '安全校验未通过';
    }
    if (_downloadVerified) return '安装包已就绪';
    if (_download.isActive) return _downloadLabel();
    if (_installed.installed) return '当前版本 ${_installed.versionName}';
    return 'Sakura 账号互通版';
  }

  String _downloadLabel() {
    return switch (_download.status) {
      KdjxDownloadStatus.queued => '等待分片下载',
      KdjxDownloadStatus.downloading =>
        _bytesPerSecond > 0
            ? '下载中 · ${_formatBytes(_bytesPerSecond.round())}/s'
                  '${_remainingTimeLabel()}'
            : '下载中 · 正在估算速度和剩余时间',
      KdjxDownloadStatus.merging => '正在校验并合并安装包',
      KdjxDownloadStatus.paused =>
        _download.reason.isEmpty ? '下载已暂停' : _download.reason,
      KdjxDownloadStatus.completed =>
        _downloadVerified ? '完整性校验完成' : '分片拼接完成，等待校验',
      KdjxDownloadStatus.failed => '下载失败',
      KdjxDownloadStatus.none => '',
    };
  }

  String _remainingTimeLabel() {
    final remainingBytes = math.max(
      0,
      _download.totalBytes - _download.downloadedBytes,
    );
    if (remainingBytes <= 0 || _bytesPerSecond <= 0) return '';
    final eta = formatKdjxDownloadEta(remainingBytes / _bytesPerSecond);
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
        color: const Color(0x2235C88A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x6635C88A)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF75DDAA),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: const TextStyle(color: Color(0xFF8E99A6))),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _CheckLine extends StatelessWidget {
  const _CheckLine({required this.ok, required this.label});

  final bool ok;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = ok ? const Color(0xFF75DDAA) : const Color(0xFFFF8585);
    return Row(
      children: [
        Icon(
          ok ? Icons.verified_rounded : Icons.warning_amber_rounded,
          color: color,
          size: 19,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: TextStyle(color: color)),
        ),
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 100),
      child: Column(
        children: [
          const Icon(Icons.cloud_off_rounded, color: Colors.white70, size: 42),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onRetry == null ? null : () => unawaited(onRetry!()),
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
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final precision = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unit]}';
}

String formatKdjxDownloadEta(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return '';
  final rounded = seconds.ceil();
  if (rounded < 60) return '$rounded秒';
  final minutes = (rounded / 60).ceil();
  if (minutes < 60) return '$minutes分钟';
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return remainingMinutes == 0 ? '$hours小时' : '$hours小时$remainingMinutes分钟';
}
