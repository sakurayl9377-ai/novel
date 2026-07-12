part of '../profile_screen.dart';

class _EditProfilePage extends StatefulWidget {
  const _EditProfilePage({
    required this.profile,
    required this.token,
    required this.service,
  });

  final UserProfile profile;
  final String token;
  final InteractionService service;

  @override
  State<_EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<_EditProfilePage> {
  late final TextEditingController _nickname;
  late final TextEditingController _signature;
  late final TextEditingController _bio;
  late final TextEditingController _spaceTitle;
  late final TextEditingController _avatarUrl;
  late final TextEditingController _bannerUrl;
  late final TextEditingController _dynamicAvatarUrl;
  late final List<TextEditingController> _photos;
  late String _theme;
  late String _gender;
  late bool _privacyMode;
  bool _isSaving = false;
  bool _isUploadingAvatar = false;
  bool _isUploadingBanner = false;
  bool _isUploadingDynamicAvatar = false;
  final Set<int> _uploadingPhotos = <int>{};

  @override
  void initState() {
    super.initState();
    final user = widget.profile.user;
    _nickname = TextEditingController(text: user.nickname);
    _signature = TextEditingController(text: user.signature);
    _bio = TextEditingController(text: user.bio);
    _spaceTitle = TextEditingController(text: user.spaceTitle);
    _avatarUrl = TextEditingController(text: user.avatarUrl);
    _bannerUrl = TextEditingController(text: user.profileBannerUrl);
    _dynamicAvatarUrl = TextEditingController(text: user.dynamicAvatarUrl);
    _theme = user.profileTheme;
    _gender = user.gender;
    _privacyMode = user.privacyMode;
    final limit = _photoLimit(user.growth.level);
    _photos = List.generate(limit, (index) {
      final photo = index < widget.profile.photos.length
          ? widget.profile.photos[index]
          : null;
      return TextEditingController(text: photo?.imageUrl ?? '');
    });
  }

  @override
  void dispose() {
    _nickname.dispose();
    _signature.dispose();
    _bio.dispose();
    _spaceTitle.dispose();
    _avatarUrl.dispose();
    _bannerUrl.dispose();
    _dynamicAvatarUrl.dispose();
    for (final controller in _photos) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final level = widget.profile.user.growth.level;
    final photoSlotIndices = _photoWallSlotIndices();
    final addPhotoIndex = _nextPhotoWallIndex();
    final photoWallItemCount =
        photoSlotIndices.length + (addPhotoIndex == null ? 0 : 1);
    return Scaffold(
      appBar: AppBar(title: const Text('编辑资料')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _SurfaceCard(
            child: Row(
              children: [
                GestureDetector(
                  onTap: _isUploadingAvatar ? null : _pickAndUploadAvatar,
                  child: _AvatarEditPreview(
                    avatarUrl: _avatarUrl.text.trim(),
                    fallbackUser: widget.profile.user,
                    isUploading: _isUploadingAvatar,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    _isUploadingAvatar
                        ? '头像上传中...'
                        : '点击头像更换\n支持 JPG、PNG、WebP，大小不超过 5MB',
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      height: 1.55,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              children: [
                _EditRow(label: '昵称', controller: _nickname),
                _EditRow(label: '签名', controller: _signature),
                _EditRow(label: '简介', controller: _bio),
                _EditRow(label: '空间标题', controller: _spaceTitle),
                const SizedBox(height: 10),
                _GenderPicker(
                  value: _gender,
                  onChanged: (value) => setState(() => _gender = value),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _privacyMode,
                  onChanged: (value) => setState(() => _privacyMode = value),
                  title: const Text(
                    '隐私模式',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: const Text('开启后别人无法查看主页或关注你'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '图片资料',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                _ProfileImageUploadTile(
                  title: '空间封面',
                  subtitle: '推荐横图，支持 JPG、PNG、WebP、GIF',
                  imageUrl: _bannerUrl.text.trim(),
                  aspectRatio: 16 / 7,
                  icon: Icons.panorama_outlined,
                  isUploading: _isUploadingBanner,
                  onTap: _isUploadingBanner
                      ? null
                      : () => _pickAndUploadProfileImage(
                          kind: 'banner',
                          label: '空间封面',
                          setUploading: (value) => _isUploadingBanner = value,
                          setUrl: (url) => _bannerUrl.text = url,
                        ),
                  onClear: _bannerUrl.text.trim().isEmpty || _isUploadingBanner
                      ? null
                      : () => setState(() => _bannerUrl.clear()),
                ),
                const SizedBox(height: 12),
                _ProfileImageUploadTile(
                  title: '动态头像',
                  subtitle: level < 5 ? 'Lv5 解锁后可上传' : '支持 JPG、PNG、WebP、GIF',
                  imageUrl: _dynamicAvatarUrl.text.trim(),
                  aspectRatio: 1,
                  icon: Icons.motion_photos_on_outlined,
                  isUploading: _isUploadingDynamicAvatar,
                  locked: level < 5,
                  onTap: level < 5 || _isUploadingDynamicAvatar
                      ? null
                      : () => _pickAndUploadProfileImage(
                          kind: 'dynamicAvatar',
                          label: '动态头像',
                          setUploading: (value) =>
                              _isUploadingDynamicAvatar = value,
                          setUrl: (url) => _dynamicAvatarUrl.text = url,
                        ),
                  onClear:
                      _dynamicAvatarUrl.text.trim().isEmpty ||
                          _isUploadingDynamicAvatar ||
                          level < 5
                      ? null
                      : () => setState(() => _dynamicAvatarUrl.clear()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '照片墙（最多${_photos.length}张）',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: photoWallItemCount,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 1,
                  ),
                  itemBuilder: (context, index) {
                    if (index >= photoSlotIndices.length) {
                      return _EditablePhotoWallSlot(
                        imageUrl: '',
                        index: addPhotoIndex!,
                        isAddSlot: true,
                        isUploading: false,
                        onTap: () => _pickAndUploadPhoto(addPhotoIndex),
                        onClear: null,
                      );
                    }
                    final photoIndex = photoSlotIndices[index];
                    final isUploading = _uploadingPhotos.contains(photoIndex);
                    return _EditablePhotoWallSlot(
                      imageUrl: _photos[photoIndex].text.trim(),
                      index: photoIndex,
                      isAddSlot: false,
                      isUploading: isUploading,
                      onTap: isUploading
                          ? null
                          : () => _pickAndUploadPhoto(photoIndex),
                      onClear:
                          _photos[photoIndex].text.trim().isEmpty || isUploading
                          ? null
                          : () => setState(() => _photos[photoIndex].clear()),
                    );
                  },
                ),
                const SizedBox(height: 10),
                const Text(
                  '点击空位添加图片，已上传图片保存资料后生效。',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '资料主题',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _ThemeChoice(
                      label: '默认蓝',
                      value: 'sakura',
                      color: AppTheme.primaryColor,
                      selected: _theme == 'sakura',
                      locked: false,
                      onTap: () => setState(() => _theme = 'sakura'),
                    ),
                    _ThemeChoice(
                      label: '星空紫',
                      value: 'night',
                      color: const Color(0xFF705CFF),
                      selected: _theme == 'night',
                      locked: level < 2,
                      onTap: () => setState(() => _theme = 'night'),
                    ),
                    _ThemeChoice(
                      label: '薄荷绿',
                      value: 'mint',
                      color: const Color(0xFF21B77B),
                      selected: _theme == 'mint',
                      locked: level < 2,
                      onTap: () => setState(() => _theme = 'mint'),
                    ),
                    _ThemeChoice(
                      label: '樱花粉',
                      value: 'sakura-pink',
                      color: const Color(0xFFE95F8D),
                      selected: _theme == 'sakura-pink',
                      locked: level < 2,
                      onTap: () => setState(() => _theme = 'sakura-pink'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存资料'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_nickname.text.trim().isEmpty) {
      _message('请输入昵称');
      return;
    }
    setState(() => _isSaving = true);
    try {
      final photoWall = _photos
          .map((controller) => controller.text.trim())
          .where((url) => url.isNotEmpty)
          .map((url) => {'imageUrl': url})
          .toList();
      final profile = await widget.service.updateMyProfile(
        token: widget.token,
        nickname: _nickname.text.trim(),
        gender: _gender,
        signature: _signature.text.trim(),
        bio: _bio.text.trim(),
        spaceTitle: _spaceTitle.text.trim(),
        avatarUrl: _avatarUrl.text.trim(),
        profileBannerUrl: _bannerUrl.text.trim(),
        dynamicAvatarUrl: _dynamicAvatarUrl.text.trim(),
        profileTheme: _theme,
        privacyMode: _privacyMode,
        photoWall: photoWall,
      );
      if (!mounted) return;
      Navigator.pop(context, profile);
    } catch (_) {
      if (mounted) _message('资料保存失败，请检查等级权限或网络');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _pickAndUploadAvatar() {
    return _pickAndUploadProfileImage(
      kind: 'avatar',
      label: '头像',
      setUploading: (value) => _isUploadingAvatar = value,
      setUrl: (url) => _avatarUrl.text = url,
    );
  }

  List<int> _photoWallSlotIndices() {
    final indices = <int>[];
    for (var index = 0; index < _photos.length; index++) {
      if (_photos[index].text.trim().isNotEmpty ||
          _uploadingPhotos.contains(index)) {
        indices.add(index);
      }
    }
    return indices;
  }

  int? _nextPhotoWallIndex() {
    if (_uploadingPhotos.isNotEmpty) return null;
    for (var index = 0; index < _photos.length; index++) {
      if (_photos[index].text.trim().isEmpty) return index;
    }
    return null;
  }

  Future<void> _pickAndUploadPhoto(int index) {
    return _pickAndUploadProfileImage(
      kind: 'photo',
      label: '照片 ${index + 1}',
      setUploading: (value) {
        if (value) {
          _uploadingPhotos.add(index);
        } else {
          _uploadingPhotos.remove(index);
        }
      },
      setUrl: (url) => _photos[index].text = url,
    );
  }

  Future<void> _pickAndUploadProfileImage({
    required String kind,
    required String label,
    required ValueChanged<bool> setUploading,
    required ValueChanged<String> setUrl,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'gif'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.single;
      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null || bytes.isEmpty) {
        _message('$label文件读取失败');
        return;
      }
      if (bytes.length > 5 * 1024 * 1024) {
        _message('$label不能超过 5MB');
        return;
      }

      final mimeType = _profileImageMimeType(file.extension ?? file.name);
      if (mimeType == null) {
        _message('请选择 JPG、PNG、WebP 或 GIF 图片');
        return;
      }

      if (!mounted) return;
      setState(() => setUploading(true));
      final url = await widget.service.uploadProfileImage(
        token: widget.token,
        kind: kind,
        bytes: bytes,
        mimeType: mimeType,
      );
      if (!mounted) return;
      setState(() => setUrl(url));
      _message('$label上传成功，保存资料后生效');
    } catch (_) {
      if (mounted) _message('$label上传失败，请稍后重试');
    } finally {
      if (mounted) setState(() => setUploading(false));
    }
  }

  String? _profileImageMimeType(String value) {
    final ext = value.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => null,
    };
  }

  void _message(String value) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }
}
