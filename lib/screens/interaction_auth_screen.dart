import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../config/theme.dart';
import '../providers/interaction_auth_provider.dart';
import '../services/interaction_auth_service.dart';
import '../widgets/interaction_ui.dart';

enum _AuthMode { login, register, reset }

enum _EmailCheckState { idle, checking, available, unavailable }

class InteractionAuthScreen extends StatefulWidget {
  const InteractionAuthScreen({super.key});

  @override
  State<InteractionAuthScreen> createState() => _InteractionAuthScreenState();
}

class _InteractionAuthScreenState extends State<InteractionAuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _captchaController = TextEditingController();
  final _emailCodeController = TextEditingController();
  final _emailFocusNode = FocusNode();

  _AuthMode _mode = _AuthMode.login;
  bool _isSendingCode = false;
  int _cooldownSeconds = 0;
  Timer? _cooldownTimer;
  CaptchaInfo? _captcha;
  _EmailCheckState _emailCheckState = _EmailCheckState.idle;
  String _emailCheckMessage = '';
  int _emailCheckSerial = 0;

  bool get _needsCaptcha => _mode != _AuthMode.login;

  @override
  void initState() {
    super.initState();
    _emailFocusNode.addListener(_handleEmailFocusChanged);
    _emailController.addListener(_handleEmailTextChanged);
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailFocusNode.removeListener(_handleEmailFocusChanged);
    _emailController.removeListener(_handleEmailTextChanged);
    _emailFocusNode.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nicknameController.dispose();
    _captchaController.dispose();
    _emailCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    final isReset = _mode == _AuthMode.reset;
    return Scaffold(
      backgroundColor: const Color(0xFFF2F6FC),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF2F6FC),
        title: Text(isReset ? '重置密码' : '互动账号'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _PremiumAuthHero(mode: _mode),
            const SizedBox(height: 12),
            if (!isReset) ...[
              if (auth.betaTestAccountEnabled) ...[
                _BetaTestAccountPanel(
                  isLoading: auth.isLoading,
                  onPressed: _enterBetaTestAccount,
                ),
                const SizedBox(height: 12),
              ],
              _ModeSwitch(
                mode: _mode,
                disabled: auth.isLoading,
                onChanged: _switchMode,
              ),
              const SizedBox(height: 12),
            ],
            _GlassPanel(
              child: isReset
                  ? _ResetForm(
                      emailController: _emailController,
                      passwordController: _passwordController,
                      confirmPasswordController: _confirmPasswordController,
                      captchaController: _captchaController,
                      emailCodeController: _emailCodeController,
                      captcha: _captcha,
                      isSendingCode: _isSendingCode,
                      cooldownSeconds: _cooldownSeconds,
                      isLoading: auth.isLoading,
                      onRefreshCaptcha: _refreshCaptcha,
                      onSendCode: _sendEmailCode,
                      onSubmit: _submit,
                      onBackToLogin: () => _switchMode(_AuthMode.login),
                    )
                  : _LoginRegisterForm(
                      mode: _mode,
                      emailController: _emailController,
                      emailFocusNode: _emailFocusNode,
                      emailCheckState: _emailCheckState,
                      emailCheckMessage: _emailCheckMessage,
                      passwordController: _passwordController,
                      nicknameController: _nicknameController,
                      captchaController: _captchaController,
                      emailCodeController: _emailCodeController,
                      captcha: _captcha,
                      isSendingCode: _isSendingCode,
                      cooldownSeconds: _cooldownSeconds,
                      isLoading: auth.isLoading,
                      onRefreshCaptcha: _refreshCaptcha,
                      onSendCode: _sendEmailCode,
                      onSubmit: _submit,
                      onForgotPassword: () => _switchMode(_AuthMode.reset),
                      onCreateAccount: () => _switchMode(_AuthMode.register),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _switchMode(_AuthMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _captchaController.clear();
      _emailCodeController.clear();
      _emailCheckState = _EmailCheckState.idle;
      _emailCheckMessage = '';
      if (mode != _AuthMode.reset) _confirmPasswordController.clear();
    });
    if (mode != _AuthMode.login) unawaited(_refreshCaptcha());
  }

  void _handleEmailFocusChanged() {
    if (!_emailFocusNode.hasFocus && _mode == _AuthMode.register) {
      unawaited(_checkRegisterEmailAvailability());
    }
  }

  void _handleEmailTextChanged() {
    if (_emailCheckState == _EmailCheckState.idle &&
        _emailCheckMessage.isEmpty) {
      return;
    }
    setState(() {
      _emailCheckState = _EmailCheckState.idle;
      _emailCheckMessage = '';
    });
  }

  Future<void> _checkRegisterEmailAvailability() async {
    if (_mode != _AuthMode.register) return;
    final email = _emailController.text.trim();
    final serial = ++_emailCheckSerial;
    if (email.isEmpty) {
      if (mounted) {
        setState(() {
          _emailCheckState = _EmailCheckState.idle;
          _emailCheckMessage = '';
        });
      }
      return;
    }
    if (!_isValidEmail(email)) {
      setState(() {
        _emailCheckState = _EmailCheckState.unavailable;
        _emailCheckMessage = '请输入正确的邮箱';
      });
      return;
    }
    setState(() {
      _emailCheckState = _EmailCheckState.checking;
      _emailCheckMessage = '正在检查邮箱';
    });
    try {
      final result = await context
          .read<InteractionAuthProvider>()
          .checkEmailStatus(email: email, purpose: 'register');
      if (!mounted ||
          serial != _emailCheckSerial ||
          _emailController.text.trim() != email) {
        return;
      }
      setState(() {
        _emailCheckState = result.available
            ? _EmailCheckState.available
            : _EmailCheckState.unavailable;
        _emailCheckMessage = result.message.isEmpty
            ? (result.available ? '邮箱可用' : '邮箱不可用')
            : result.message;
      });
    } catch (error) {
      if (!mounted || serial != _emailCheckSerial) return;
      setState(() {
        _emailCheckState = _EmailCheckState.unavailable;
        _emailCheckMessage = _friendlyError(error);
      });
    }
  }

  Future<void> _refreshCaptcha() async {
    if (!_needsCaptcha) return;
    try {
      final captcha = await context
          .read<InteractionAuthProvider>()
          .fetchCaptcha();
      if (!mounted) return;
      setState(() {
        _captcha = captcha;
        _captchaController.clear();
      });
    } catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    }
  }

  Future<void> _sendEmailCode() async {
    final email = _emailController.text.trim();
    final captchaCode = _captchaController.text.trim();
    final captcha = _captcha;
    if (!_isValidEmail(email)) {
      _showMessage('请输入正确的邮箱');
      return;
    }
    if (captcha == null || captchaCode.isEmpty) {
      _showMessage('请输入图片验证码');
      return;
    }

    setState(() => _isSendingCode = true);
    try {
      final retryAfter = await context
          .read<InteractionAuthProvider>()
          .sendEmailCode(
            email: email,
            captchaId: captcha.captchaId,
            captchaCode: captchaCode,
            purpose: _mode == _AuthMode.reset ? 'reset_password' : 'register',
          );
      if (!mounted) return;
      _showMessage('邮箱验证码已发送');
      _startCooldown(retryAfter <= 0 ? 60 : retryAfter);
    } catch (error) {
      if (!mounted) return;
      _showMessage(_friendlyError(error));
      await _refreshCaptcha();
    } finally {
      if (mounted) setState(() => _isSendingCode = false);
    }
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (!_isValidEmail(email)) {
      _showMessage('请输入正确的邮箱');
      return;
    }
    if (password.length < 8) {
      _showMessage('密码至少 8 位');
      return;
    }
    if (_mode == _AuthMode.reset &&
        password != _confirmPasswordController.text) {
      _showMessage('两次输入的密码不一致');
      return;
    }

    try {
      final auth = context.read<InteractionAuthProvider>();
      switch (_mode) {
        case _AuthMode.login:
          await auth.login(email: email, password: password);
        case _AuthMode.register:
          final emailCode = _emailCodeController.text.trim();
          if (emailCode.isEmpty) {
            _showMessage('请输入邮箱验证码');
            return;
          }
          await auth.register(
            email: email,
            password: password,
            emailCode: emailCode,
            nickname: _nicknameController.text.trim(),
          );
        case _AuthMode.reset:
          final emailCode = _emailCodeController.text.trim();
          if (emailCode.isEmpty) {
            _showMessage('请输入邮箱验证码');
            return;
          }
          await auth.resetPassword(
            email: email,
            password: password,
            emailCode: emailCode,
          );
      }
      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    }
  }

  Future<void> _enterBetaTestAccount() async {
    try {
      await context.read<InteractionAuthProvider>().enterBetaTestAccount();
      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    }
  }

  void _startCooldown(int seconds) {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSeconds = seconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_cooldownSeconds <= 1) {
        timer.cancel();
        setState(() => _cooldownSeconds = 0);
      } else {
        setState(() => _cooldownSeconds--);
      }
    });
  }

  bool _isValidEmail(String value) {
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value);
  }

  String _friendlyError(Object error) {
    if (error is InteractionAuthException) {
      if (error.retryAfter != null && error.retryAfter! > 0) {
        return '${error.message}，${error.retryAfter}s 后再试';
      }
      return error.message;
    }
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

class _BetaTestAccountPanel extends StatelessWidget {
  const _BetaTestAccountPanel({
    required this.isLoading,
    required this.onPressed,
  });

  final bool isLoading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE8C77A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.science_outlined, color: Color(0xFF9A6A12)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '测试版专用账号',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text('无需输入账号密码，仅连接本地或测试服务时可用。'),
          const SizedBox(height: 10),
          FilledButton.icon(
            key: const ValueKey('beta-test-account-button'),
            onPressed: isLoading ? null : onPressed,
            icon: const Icon(Icons.login_rounded),
            label: const Text('一键进入测试账号'),
          ),
        ],
      ),
    );
  }
}

class _LoginRegisterForm extends StatelessWidget {
  const _LoginRegisterForm({
    required this.mode,
    required this.emailController,
    required this.emailFocusNode,
    required this.emailCheckState,
    required this.emailCheckMessage,
    required this.passwordController,
    required this.nicknameController,
    required this.captchaController,
    required this.emailCodeController,
    required this.captcha,
    required this.isSendingCode,
    required this.cooldownSeconds,
    required this.isLoading,
    required this.onRefreshCaptcha,
    required this.onSendCode,
    required this.onSubmit,
    required this.onForgotPassword,
    required this.onCreateAccount,
  });

  final _AuthMode mode;
  final TextEditingController emailController;
  final FocusNode emailFocusNode;
  final _EmailCheckState emailCheckState;
  final String emailCheckMessage;
  final TextEditingController passwordController;
  final TextEditingController nicknameController;
  final TextEditingController captchaController;
  final TextEditingController emailCodeController;
  final CaptchaInfo? captcha;
  final bool isSendingCode;
  final int cooldownSeconds;
  final bool isLoading;
  final VoidCallback onRefreshCaptcha;
  final VoidCallback onSendCode;
  final VoidCallback onSubmit;
  final VoidCallback onForgotPassword;
  final VoidCallback onCreateAccount;

  @override
  Widget build(BuildContext context) {
    final isRegister = mode == _AuthMode.register;
    final emailStateColor = switch (emailCheckState) {
      _EmailCheckState.available => const Color(0xFF16A34A),
      _EmailCheckState.unavailable => const Color(0xFFDC2626),
      _EmailCheckState.checking => AppTheme.textSecondary,
      _EmailCheckState.idle => AppTheme.textSecondary,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AuthInput(
          label: '邮箱',
          controller: emailController,
          focusNode: emailFocusNode,
          hintText: '请输入邮箱地址',
          icon: Icons.mail_outline,
          keyboardType: TextInputType.emailAddress,
          helper: isRegister && emailCheckMessage.isNotEmpty
              ? emailCheckMessage
              : null,
          helperColor: emailStateColor,
          suffixIcon: isRegister
              ? _EmailCheckIndicator(state: emailCheckState)
              : null,
        ),
        _AuthInput(
          label: '密码',
          controller: passwordController,
          hintText: '请输入密码',
          icon: Icons.lock_outline,
          obscureText: true,
          textInputAction: isRegister
              ? TextInputAction.next
              : TextInputAction.done,
          onSubmitted: (_) {
            if (!isRegister) onSubmit();
          },
        ),
        if (!isRegister)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: isLoading ? null : onForgotPassword,
              child: const Text('忘记密码？'),
            ),
          ),
        if (isRegister) ...[
          _AuthInput(
            label: '昵称',
            controller: nicknameController,
            hintText: '请输入昵称（2-12个字符）',
            icon: Icons.person_outline,
          ),
          _CaptchaField(
            captchaController: captchaController,
            emailCodeController: emailCodeController,
            captcha: captcha,
            isSendingCode: isSendingCode,
            cooldownSeconds: cooldownSeconds,
            isLoading: isLoading,
            onRefreshCaptcha: onRefreshCaptcha,
            onSendCode: onSendCode,
          ),
        ],
        const SizedBox(height: 10),
        _PrimaryAuthButton(
          label: isRegister ? '注册并登录' : '登录',
          isLoading: isLoading,
          onPressed: onSubmit,
        ),
        if (!isRegister) ...[
          const SizedBox(height: 12),
          _GhostButton(label: '创建账号', onPressed: onCreateAccount),
        ] else ...[
          const SizedBox(height: 12),
          const Text.rich(
            TextSpan(
              text: '我已阅读并同意 ',
              children: [
                TextSpan(
                  text: '《用户协议》',
                  style: TextStyle(color: AppTheme.primaryColor),
                ),
                TextSpan(text: ' 和 '),
                TextSpan(
                  text: '《隐私政策》',
                  style: TextStyle(color: AppTheme.primaryColor),
                ),
              ],
            ),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class _ResetForm extends StatelessWidget {
  const _ResetForm({
    required this.emailController,
    required this.passwordController,
    required this.confirmPasswordController,
    required this.captchaController,
    required this.emailCodeController,
    required this.captcha,
    required this.isSendingCode,
    required this.cooldownSeconds,
    required this.isLoading,
    required this.onRefreshCaptcha,
    required this.onSendCode,
    required this.onSubmit,
    required this.onBackToLogin,
  });

  final TextEditingController emailController;
  final TextEditingController passwordController;
  final TextEditingController confirmPasswordController;
  final TextEditingController captchaController;
  final TextEditingController emailCodeController;
  final CaptchaInfo? captcha;
  final bool isSendingCode;
  final int cooldownSeconds;
  final bool isLoading;
  final VoidCallback onRefreshCaptcha;
  final VoidCallback onSendCode;
  final VoidCallback onSubmit;
  final VoidCallback onBackToLogin;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AuthInput(
          label: '邮箱',
          controller: emailController,
          hintText: '请输入邮箱地址',
          icon: Icons.mail_outline,
          keyboardType: TextInputType.emailAddress,
        ),
        _CaptchaField(
          captchaController: captchaController,
          emailCodeController: emailCodeController,
          captcha: captcha,
          isSendingCode: isSendingCode,
          cooldownSeconds: cooldownSeconds,
          isLoading: isLoading,
          onRefreshCaptcha: onRefreshCaptcha,
          onSendCode: onSendCode,
        ),
        _AuthInput(
          label: '新密码',
          helper: '8-16位，包含字母、数字或符号',
          controller: passwordController,
          hintText: '请输入新密码',
          icon: Icons.lock_outline,
          obscureText: true,
        ),
        _AuthInput(
          label: '确认密码',
          controller: confirmPasswordController,
          hintText: '请再次输入新密码',
          icon: Icons.lock_outline,
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: 10),
        _PrimaryAuthButton(
          label: '重置密码',
          isLoading: isLoading,
          onPressed: onSubmit,
        ),
        const SizedBox(height: 12),
        _GhostButton(label: '返回登录', onPressed: onBackToLogin),
      ],
    );
  }
}

class _CaptchaField extends StatelessWidget {
  const _CaptchaField({
    required this.captchaController,
    required this.emailCodeController,
    required this.captcha,
    required this.isSendingCode,
    required this.cooldownSeconds,
    required this.isLoading,
    required this.onRefreshCaptcha,
    required this.onSendCode,
  });

  final TextEditingController captchaController;
  final TextEditingController emailCodeController;
  final CaptchaInfo? captcha;
  final bool isSendingCode;
  final int cooldownSeconds;
  final bool isLoading;
  final VoidCallback onRefreshCaptcha;
  final VoidCallback onSendCode;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _AuthInput(
          label: '图片验证码',
          controller: captchaController,
          hintText: '请输入图片验证码',
          icon: Icons.verified_user_outlined,
          trailing: _CaptchaBox(captcha: captcha, onTap: onRefreshCaptcha),
        ),
        _AuthInput(
          label: '邮箱验证码',
          controller: emailCodeController,
          hintText: '请输入邮箱验证码',
          icon: Icons.mark_email_read_outlined,
          keyboardType: TextInputType.number,
          trailing: SizedBox(
            width: 104,
            height: 44,
            child: OutlinedButton(
              onPressed: isSendingCode || cooldownSeconds > 0 || isLoading
                  ? null
                  : onSendCode,
              child: Text(cooldownSeconds > 0 ? '${cooldownSeconds}s' : '发验证码'),
            ),
          ),
        ),
      ],
    );
  }
}

class _PremiumAuthHero extends StatelessWidget {
  const _PremiumAuthHero({required this.mode});

  final _AuthMode mode;

  @override
  Widget build(BuildContext context) {
    final isReset = mode == _AuthMode.reset;
    final isRegister = mode == _AuthMode.register;
    return Container(
      height: isReset ? 208 : 252,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isReset
              ? const [Color(0xFF111B2C), Color(0xFF273B5C)]
              : const [Color(0xFF101A31), Color(0xFF19427C)],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F10213A),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _AuthGlowPainter())),
          Positioned(
            right: -18,
            top: isReset ? 20 : 12,
            child: Icon(
              isReset ? Icons.security_rounded : Icons.auto_awesome_rounded,
              size: isReset ? 156 : 172,
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          Positioned(right: 20, top: 20, child: _HeroMedal(isReset: isReset)),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isReset ? '重置密码' : (isRegister ? '欢迎加入' : '欢迎回来'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 27,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isReset ? '为你的账号安全保驾护航' : 'Sakura',
                  style: const TextStyle(
                    color: Color(0xFFFFD98B),
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  isReset ? '验证邮箱后即可设置新密码' : '开启你的专属旅程',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (!isReset)
                  Row(
                    children: const [
                      Expanded(
                        child: _BenefitChip(
                          icon: Icons.shield_outlined,
                          title: '等级成长',
                          subtitle: '解锁更多特权',
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: _BenefitChip(
                          icon: Icons.monetization_on_outlined,
                          title: '樱花币',
                          subtitle: '兑换礼物',
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: _BenefitChip(
                          icon: Icons.palette_outlined,
                          title: '空间装扮',
                          subtitle: '打造个性空间',
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroMedal extends StatelessWidget {
  const _HeroMedal({required this.isReset});

  final bool isReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFFFFE6A3), Color(0xFFD39C3A)],
        ),
        boxShadow: const [BoxShadow(color: Color(0x55D39C3A), blurRadius: 18)],
      ),
      child: Icon(
        isReset ? Icons.lock_rounded : Icons.local_florist_rounded,
        color: const Color(0xFF18233A),
        size: 34,
      ),
    );
  }
}

class _BenefitChip extends StatelessWidget {
  const _BenefitChip({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        children: [
          Icon(icon, color: const Color(0xFFFFD98B), size: 20),
          const SizedBox(height: 5),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.68),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.mode,
    required this.disabled,
    required this.onChanged,
  });

  final _AuthMode mode;
  final bool disabled;
  final ValueChanged<_AuthMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF0F8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          _ModeTab(
            label: '登录',
            selected: mode == _AuthMode.login,
            onTap: disabled ? null : () => onChanged(_AuthMode.login),
          ),
          _ModeTab(
            label: '注册',
            selected: mode == _AuthMode.register,
            onTap: disabled ? null : () => onChanged(_AuthMode.register),
          ),
        ],
      ),
    );
  }
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x12000000),
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? AppTheme.primaryColor : AppTheme.textSecondary,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthInput extends StatefulWidget {
  const _AuthInput({
    required this.label,
    required this.controller,
    required this.hintText,
    required this.icon,
    this.keyboardType,
    this.focusNode,
    this.textInputAction = TextInputAction.next,
    this.obscureText = false,
    this.helper,
    this.helperColor,
    this.suffixIcon,
    this.trailing,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String hintText;
  final IconData icon;
  final TextInputType? keyboardType;
  final FocusNode? focusNode;
  final TextInputAction textInputAction;
  final bool obscureText;
  final String? helper;
  final Color? helperColor;
  final Widget? suffixIcon;
  final Widget? trailing;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_AuthInput> createState() => _AuthInputState();
}

class _AuthInputState extends State<_AuthInput> {
  late bool _obscureText;

  @override
  void initState() {
    super.initState();
    _obscureText = widget.obscureText;
  }

  @override
  void didUpdateWidget(covariant _AuthInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.obscureText != widget.obscureText) {
      _obscureText = widget.obscureText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final input = TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      obscureText: _obscureText,
      enableSuggestions: !widget.obscureText,
      autocorrect: !widget.obscureText,
      onSubmitted: widget.onSubmitted,
      decoration:
          interactionInputDecoration(
            hintText: widget.hintText,
            icon: widget.icon,
          ).copyWith(
            fillColor: const Color(0xFFF8FAFD),
            suffixIcon: widget.obscureText
                ? IconButton(
                    tooltip: _obscureText ? '鏄剧ず瀵嗙爜' : '闅愯棌瀵嗙爜',
                    icon: Icon(
                      _obscureText
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 19,
                    ),
                    onPressed: () {
                      setState(() => _obscureText = !_obscureText);
                    },
                  )
                : widget.suffixIcon,
          ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.label,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 7),
          if (widget.trailing == null)
            input
          else
            Row(
              children: [
                Expanded(child: input),
                const SizedBox(width: 8),
                widget.trailing!,
              ],
            ),
          if (widget.helper != null) ...[
            const SizedBox(height: 5),
            Text(
              widget.helper!,
              style: TextStyle(
                color: widget.helperColor ?? AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CaptchaBox extends StatelessWidget {
  const _CaptchaBox({required this.captcha, required this.onTap});

  final CaptchaInfo? captcha;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 116,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBF5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFEAD6AE)),
        ),
        clipBehavior: Clip.antiAlias,
        child: captcha == null
            ? const Text(
                '点击刷新',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              )
            : SvgPicture.string(
                captcha!.imageSvg,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Text('点击刷新'),
              ),
      ),
    );
  }
}

class _PrimaryAuthButton extends StatelessWidget {
  const _PrimaryAuthButton({
    required this.label,
    required this.isLoading,
    required this.onPressed,
  });

  final String label;
  final bool isLoading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: FilledButton(
        onPressed: isLoading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppTheme.primaryColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: isLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(label),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: OutlinedButton(onPressed: onPressed, child: Text(label)),
    );
  }
}

class _EmailCheckIndicator extends StatelessWidget {
  const _EmailCheckIndicator({required this.state});

  final _EmailCheckState state;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      _EmailCheckState.checking => const Padding(
        padding: EdgeInsets.all(13),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      _EmailCheckState.available => const Icon(
        Icons.check_circle,
        color: Color(0xFF16A34A),
      ),
      _EmailCheckState.unavailable => const Icon(
        Icons.cancel,
        color: Color(0xFFDC2626),
      ),
      _EmailCheckState.idle => const SizedBox.shrink(),
    };
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white),
        boxShadow: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _AuthGlowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final gold = Paint()
      ..color = const Color(0xFFFFD98B).withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final white = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(size.width * 0.74, size.height * 0.28),
        radius: size.width * 0.28,
      ),
      -0.8,
      4.3,
      false,
      gold,
    );
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(size.width * 0.82, size.height * 0.32),
        radius: size.width * 0.21,
      ),
      0.2,
      3.6,
      false,
      white,
    );
    final petalPaint = Paint()
      ..color = const Color(0xFFFFB7CB).withValues(alpha: 0.42);
    for (final offset in const [
      Offset(0.08, 0.16),
      Offset(0.14, 0.08),
      Offset(0.9, 0.12),
      Offset(0.78, 0.72),
    ]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(size.width * offset.dx, size.height * offset.dy),
          width: 10,
          height: 18,
        ),
        petalPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
