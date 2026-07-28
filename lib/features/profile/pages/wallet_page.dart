part of '../profile_screen.dart';

class ProfileWalletPage extends StatefulWidget {
  const ProfileWalletPage({
    super.key,
    required this.token,
    required this.service,
    this.orderService,
  });

  final String token;
  final InteractionService service;
  final BailianGameService? orderService;

  @override
  State<ProfileWalletPage> createState() => _ProfileWalletPageState();
}

class _ProfileWalletPageState extends State<ProfileWalletPage>
    with SingleTickerProviderStateMixin {
  static const int _ledgerPageSize = 30;
  static const int _ordersPageSize = 20;

  late final TabController _tabController;
  late final BailianGameService _orderService;
  late final TextEditingController _orderSearchController;
  SakuraWalletSnapshot? _wallet;
  List<BailianPayment> _orders = const [];
  bool _walletLoading = false;
  bool _ordersLoading = false;
  bool _ordersHasMore = false;
  int _ordersPage = 1;
  int _ordersTotal = 0;
  int _ordersSnapshotMaxId = 0;
  int _ordersRequestGeneration = 0;
  DateTimeRange? _orderDateRange;
  Timer? _orderSearchDebounce;
  String _walletError = '';
  String _ordersError = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _orderService = widget.orderService ?? BailianGameService();
    _orderSearchController = TextEditingController();
    unawaited(_refreshAll());
  }

  @override
  void dispose() {
    _orderSearchDebounce?.cancel();
    _orderSearchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      _loadWallet(refresh: true),
      _loadOrders(page: 1, resetSnapshot: true),
    ]);
  }

  Future<void> _loadWallet({bool refresh = false}) async {
    if (_walletLoading) return;
    setState(() {
      _walletLoading = true;
      _walletError = '';
    });
    try {
      final next = await widget.service.fetchWallet(
        token: widget.token,
        page: refresh ? 1 : (_wallet?.ledger.page ?? 0) + 1,
        pageSize: _ledgerPageSize,
        snapshotMaxId: refresh ? 0 : (_wallet?.snapshotMaxId ?? 0),
      );
      if (!mounted) return;
      setState(() {
        _wallet = refresh || _wallet == null
            ? next
            : _mergeWalletSnapshots(_wallet!, next);
      });
    } catch (error) {
      if (mounted) setState(() => _walletError = _walletErrorMessage(error));
    } finally {
      if (mounted) setState(() => _walletLoading = false);
    }
  }

  Future<void> _loadOrders({
    required int page,
    bool resetSnapshot = false,
  }) async {
    final targetPage = page < 1 ? 1 : page;
    final generation = ++_ordersRequestGeneration;
    setState(() {
      _ordersLoading = true;
      _ordersError = '';
    });
    try {
      final next = await _orderService.listPayments(
        widget.token,
        offset: (targetPage - 1) * _ordersPageSize,
        limit: _ordersPageSize,
        snapshotMaxId: resetSnapshot ? 0 : _ordersSnapshotMaxId,
        searchQuery: _orderSearchController.text,
        fromDate: _orderDateRange?.start,
        toDate: _orderDateRange?.end,
      );
      if (!mounted || generation != _ordersRequestGeneration) return;
      setState(() {
        _orders = next.items;
        _ordersHasMore = next.hasMore;
        _ordersPage = targetPage;
        _ordersTotal = next.total;
        _ordersSnapshotMaxId = next.snapshotMaxId;
      });
    } catch (error) {
      if (mounted && generation == _ordersRequestGeneration) {
        setState(() => _ordersError = _walletErrorMessage(error));
      }
    } finally {
      if (mounted && generation == _ordersRequestGeneration) {
        setState(() => _ordersLoading = false);
      }
    }
  }

  Future<void> _refreshOrders() async {
    await Future.wait([
      _loadOrders(page: 1, resetSnapshot: true),
      _loadWallet(refresh: true),
    ]);
  }

  void _onOrderSearchChanged(String _) {
    setState(() {});
    _orderSearchDebounce?.cancel();
    _orderSearchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) unawaited(_loadOrders(page: 1, resetSnapshot: true));
    });
  }

  Future<void> _pickOrderDateRange() async {
    final now = DateTime.now();
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _orderDateRange,
    );
    if (!mounted || selected == null) return;
    setState(() => _orderDateRange = selected);
    await _loadOrders(page: 1, resetSnapshot: true);
  }

  void _clearOrderFilters() {
    _orderSearchDebounce?.cancel();
    _orderSearchController.clear();
    setState(() => _orderDateRange = null);
    unawaited(_loadOrders(page: 1, resetSnapshot: true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _profileBottomBackground,
      appBar: AppBar(
        toolbarHeight: 50,
        centerTitle: false,
        titleSpacing: 0,
        title: const Text(
          '钱包',
          style: TextStyle(
            fontSize: 19,
            height: 1,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
            fontFamilyFallback: _profileFontFallback,
          ),
        ),
        backgroundColor: _profileTopBackground,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: Column(
        children: [
          _WalletBalanceHeader(
            balance: _wallet?.balance,
            loading: _walletLoading,
          ),
          Material(
            color: Colors.white,
            child: TabBar(
              controller: _tabController,
              labelColor: _profileAccentBlue,
              unselectedLabelColor: AppTheme.textSecondary,
              indicatorColor: _profileAccentBlue,
              dividerColor: AppTheme.dividerColor,
              indicatorSize: TabBarIndicatorSize.label,
              labelStyle: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFamilyFallback: _profileFontFallback,
              ),
              tabs: const [
                Tab(text: '流水'),
                Tab(text: '订单'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [_buildLedger(), _buildOrders()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLedger() {
    final items = _wallet?.ledger.items ?? const <SakuraWalletLedgerEntry>[];
    if (_walletLoading && items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(key: ValueKey('wallet-loading')),
      );
    }
    if (_walletError.isNotEmpty && items.isEmpty) {
      return _WalletErrorList(
        key: const ValueKey('wallet-ledger-error'),
        message: _walletError,
        onRefresh: () => _loadWallet(refresh: true),
      );
    }
    if (items.isEmpty) {
      return _WalletEmptyList(
        key: const ValueKey('wallet-ledger-empty'),
        icon: Icons.receipt_long_outlined,
        title: '暂无流水',
        subtitle: '樱花币收入和消费记录会显示在这里',
        onRefresh: () => _loadWallet(refresh: true),
      );
    }
    return _WalletPagedList(
      key: const ValueKey('wallet-ledger-list'),
      itemCount: items.length,
      hasMore: _wallet?.ledger.hasMore == true,
      loadingMore: _walletLoading,
      loadMoreError: _walletError,
      onRefresh: () => _loadWallet(refresh: true),
      onLoadMore: () => unawaited(_loadWallet()),
      itemBuilder: (context, index) => _WalletLedgerTile(
        key: ValueKey('wallet-ledger-${items[index].id}-$index'),
        entry: items[index],
      ),
    );
  }

  Widget _buildOrders() {
    return Column(
      children: [
        _WalletOrderFilters(
          controller: _orderSearchController,
          dateRange: _orderDateRange,
          loading: _ordersLoading,
          onSearchChanged: _onOrderSearchChanged,
          onPickDateRange: _pickOrderDateRange,
          onClear: _clearOrderFilters,
        ),
        Expanded(child: _buildOrderResults()),
      ],
    );
  }

  Widget _buildOrderResults() {
    if (_ordersLoading && _orders.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(
          key: ValueKey('wallet-orders-loading'),
        ),
      );
    }
    if (_ordersError.isNotEmpty && _orders.isEmpty) {
      return _WalletErrorList(
        key: const ValueKey('wallet-orders-error'),
        message: _ordersError,
        onRefresh: _refreshOrders,
      );
    }
    if (_orders.isEmpty) {
      final filtered =
          _orderSearchController.text.trim().isNotEmpty ||
          _orderDateRange != null;
      return _WalletEmptyList(
        key: const ValueKey('wallet-orders-empty'),
        icon: filtered ? Icons.search_off_rounded : Icons.shopping_bag_outlined,
        title: filtered ? '没有匹配订单' : '暂无订单',
        subtitle: filtered ? '请调整搜索内容或日期范围' : '使用樱花币支付的消费记录会显示在这里',
        onRefresh: _refreshOrders,
      );
    }
    return _WalletOrderPageList(
      key: const ValueKey('wallet-orders-list'),
      orders: _orders,
      page: _ordersPage,
      total: _ordersTotal,
      pageSize: _ordersPageSize,
      hasNext: _ordersHasMore,
      loading: _ordersLoading,
      error: _ordersError,
      onRefresh: _refreshOrders,
      onPrevious: _ordersPage > 1
          ? () => unawaited(_loadOrders(page: _ordersPage - 1))
          : null,
      onNext: _ordersHasMore
          ? () => unawaited(_loadOrders(page: _ordersPage + 1))
          : null,
      itemBuilder: (context, index) => _WalletOrderTile(
        key: ValueKey('wallet-order-${_walletOrderKey(_orders[index])}-$index'),
        order: _orders[index],
      ),
    );
  }
}

class _WalletBalanceHeader extends StatelessWidget {
  const _WalletBalanceHeader({required this.balance, required this.loading});

  final int? balance;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('wallet-balance-header'),
      width: double.infinity,
      color: const Color(0xFFFFF8FB),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 17),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFFFE3EC),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.local_florist_outlined,
              color: Color(0xFFCF4773),
              size: 24,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '樱花币余额',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  balance == null ? '--' : _formatThousands(balance!),
                  key: const ValueKey('wallet-balance-value'),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 28,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
              ],
            ),
          ),
          if (loading && balance != null)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

class _WalletOrderFilters extends StatelessWidget {
  const _WalletOrderFilters({
    required this.controller,
    required this.dateRange,
    required this.loading,
    required this.onSearchChanged,
    required this.onPickDateRange,
    required this.onClear,
  });

  final TextEditingController controller;
  final DateTimeRange? dateRange;
  final bool loading;
  final ValueChanged<String> onSearchChanged;
  final Future<void> Function() onPickDateRange;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final hasFilters = controller.text.trim().isNotEmpty || dateRange != null;
    final dateLabel = dateRange == null
        ? '日期'
        : '${_walletFilterDate(dateRange!.start)} - '
              '${_walletFilterDate(dateRange!.end)}';
    final search = TextField(
      key: const ValueKey('wallet-order-search'),
      controller: controller,
      onChanged: onSearchChanged,
      onSubmitted: onSearchChanged,
      textInputAction: TextInputAction.search,
      maxLength: 100,
      decoration: InputDecoration(
        hintText: '搜索商品或订单号',
        counterText: '',
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清除搜索',
                onPressed: () {
                  controller.clear();
                  onSearchChanged('');
                },
                icon: const Icon(Icons.close_rounded, size: 19),
              ),
        isDense: true,
        filled: true,
        fillColor: const Color(0xFFF7F8FA),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide.none,
        ),
      ),
    );
    final dateButton = SizedBox(
      height: 44,
      child: OutlinedButton.icon(
        key: const ValueKey('wallet-order-date-filter'),
        onPressed: () => unawaited(onPickDateRange()),
        icon: const Icon(Icons.calendar_month_outlined, size: 19),
        label: Text(dateLabel, overflow: TextOverflow.ellipsis),
      ),
    );
    final clearButton = IconButton(
      key: const ValueKey('wallet-order-clear-filters'),
      tooltip: '清除筛选',
      onPressed: hasFilters ? onClear : null,
      icon: const Icon(Icons.filter_alt_off_outlined),
    );

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppTheme.dividerColor)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 480) {
                  return Column(
                    children: [
                      search,
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: dateButton),
                          const SizedBox(width: 4),
                          clearButton,
                        ],
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: search),
                    const SizedBox(width: 10),
                    SizedBox(width: 190, child: dateButton),
                    const SizedBox(width: 4),
                    clearButton,
                  ],
                );
              },
            ),
          ),
          if (loading) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}

class _WalletOrderPageList extends StatelessWidget {
  const _WalletOrderPageList({
    super.key,
    required this.orders,
    required this.page,
    required this.total,
    required this.pageSize,
    required this.hasNext,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onPrevious,
    required this.onNext,
    required this.itemBuilder,
  });

  final List<BailianPayment> orders;
  final int page;
  final int total;
  final int pageSize;
  final bool hasNext;
  final bool loading;
  final String error;
  final Future<void> Function() onRefresh;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        itemCount: orders.length + 1,
        separatorBuilder: (_, index) => index >= orders.length - 1
            ? const SizedBox.shrink()
            : const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          if (index < orders.length) return itemBuilder(context, index);
          return _WalletOrderPagination(
            page: page,
            total: total,
            pageSize: pageSize,
            hasNext: hasNext,
            loading: loading,
            error: error,
            onPrevious: onPrevious,
            onNext: onNext,
          );
        },
      ),
    );
  }
}

class _WalletOrderPagination extends StatelessWidget {
  const _WalletOrderPagination({
    required this.page,
    required this.total,
    required this.pageSize,
    required this.hasNext,
    required this.loading,
    required this.error,
    required this.onPrevious,
    required this.onNext,
  });

  final int page;
  final int total;
  final int pageSize;
  final bool hasNext;
  final bool loading;
  final String error;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final totalPages = math.max(1, (total + pageSize - 1) ~/ pageSize);
    return Container(
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppTheme.dividerColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFC74848), fontSize: 12),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                key: const ValueKey('wallet-orders-previous-page'),
                tooltip: '上一页',
                onPressed: loading ? null : onPrevious,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              SizedBox(
                width: 148,
                child: Text(
                  '第 $page / $totalPages 页  共 $total 笔',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('wallet-orders-next-page'),
                tooltip: '下一页',
                onPressed: loading || !hasNext ? null : onNext,
                icon: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WalletPagedList extends StatelessWidget {
  const _WalletPagedList({
    super.key,
    required this.itemCount,
    required this.hasMore,
    required this.loadingMore,
    required this.loadMoreError,
    required this.onRefresh,
    required this.onLoadMore,
    required this.itemBuilder,
  });

  final int itemCount;
  final bool hasMore;
  final bool loadingMore;
  final String loadMoreError;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    final showFooter = hasMore || loadingMore || loadMoreError.isNotEmpty;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (hasMore && notification.metrics.extentAfter < 160) onLoadMore();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
          itemCount: itemCount + (showFooter ? 1 : 0),
          separatorBuilder: (_, index) => index >= itemCount - 1
              ? const SizedBox.shrink()
              : const Divider(height: 1, indent: 72),
          itemBuilder: (context, index) {
            if (index < itemCount) return itemBuilder(context, index);
            return _WalletLoadMoreFooter(
              loading: loadingMore,
              error: loadMoreError,
              onPressed: onLoadMore,
            );
          },
        ),
      ),
    );
  }
}

class _WalletLoadMoreFooter extends StatelessWidget {
  const _WalletLoadMoreFooter({
    required this.loading,
    required this.error,
    required this.onPressed,
  });

  final bool loading;
  final String error;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        height: 52,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return SizedBox(
      height: 52,
      child: Center(
        child: TextButton.icon(
          onPressed: onPressed,
          icon: Icon(
            error.isEmpty ? Icons.expand_more_rounded : Icons.refresh_rounded,
            size: 18,
          ),
          label: Text(error.isEmpty ? '加载更多' : '加载失败，点击重试'),
        ),
      ),
    );
  }
}

class _WalletLedgerTile extends StatelessWidget {
  const _WalletLedgerTile({super.key, required this.entry});

  final SakuraWalletLedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final positive = entry.coinsDelta > 0;
    final amountColor = positive
        ? const Color(0xFF17845B)
        : entry.coinsDelta < 0
        ? const Color(0xFFC74848)
        : AppTheme.textSecondary;
    final actionLabel = _walletActionLabel(entry.action);
    final description = entry.description.isEmpty
        ? actionLabel
        : entry.description;
    final meta = [
      if (entry.description.isNotEmpty) actionLabel,
      _walletDateTime(entry.createdAt),
    ].where((item) => item.isNotEmpty).join(' · ');
    return ColoredBox(
      color: Colors.white,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
        leading: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: amountColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            positive ? Icons.add_rounded : Icons.remove_rounded,
            color: amountColor,
            size: 21,
          ),
        ),
        title: Text(
          description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: meta.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
        trailing: Text(
          '${entry.coinsDelta > 0 ? '+' : ''}${entry.coinsDelta}',
          style: TextStyle(
            color: amountColor,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _WalletOrderTile extends StatelessWidget {
  const _WalletOrderTile({super.key, required this.order});

  final BailianPayment order;

  @override
  Widget build(BuildContext context) {
    final status = _walletOrderStatus(order.status);
    final meta = [
      _walletDate(order.createdAt),
      if (order.moneyCents > 0)
        '价值 ¥${(order.moneyCents / 100).toStringAsFixed(2)}',
      _walletOrderSource(order.source),
    ].where((item) => item.isNotEmpty).join(' · ');
    return ColoredBox(
      color: Colors.white,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
        leading: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFEDF4FF),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.shopping_bag_outlined,
            color: _profileAccentBlue,
            size: 21,
          ),
        ),
        title: Text(
          order.productName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: meta.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(meta, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              order.coinCost > 0 ? '-${order.coinCost}' : '0',
              style: const TextStyle(
                color: Color(0xFFC74848),
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              status.label,
              style: TextStyle(
                color: status.color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WalletEmptyList extends StatelessWidget {
  const _WalletEmptyList({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onRefresh,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: constraints.maxHeight,
                child: InteractionEmptyState(
                  icon: icon,
                  title: title,
                  subtitle: subtitle,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WalletErrorList extends StatelessWidget {
  const _WalletErrorList({
    super.key,
    required this.message,
    required this.onRefresh,
  });

  final String message;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: 420,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.account_balance_wallet_outlined,
                      size: 46,
                      color: AppTheme.textHint,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: () => unawaited(onRefresh()),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('重新加载'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

SakuraWalletSnapshot _mergeWalletSnapshots(
  SakuraWalletSnapshot current,
  SakuraWalletSnapshot next,
) {
  final items = <SakuraWalletLedgerEntry>[];
  final keys = <String>{};
  for (final item in [...current.ledger.items, ...next.ledger.items]) {
    final key = item.id.isNotEmpty
        ? 'id:${item.id}'
        : '${item.action}:${item.coinsDelta}:${item.createdAt}';
    if (keys.add(key)) items.add(item);
  }
  return SakuraWalletSnapshot(
    balance: next.balance,
    snapshotMaxId: current.snapshotMaxId > 0
        ? current.snapshotMaxId
        : next.snapshotMaxId,
    ledger: SakuraWalletLedgerPage(
      page: next.ledger.page,
      pageSize: next.ledger.pageSize,
      total: next.ledger.total,
      items: items,
    ),
  );
}

String _walletOrderKey(BailianPayment order) {
  if (order.id.isNotEmpty) return 'id:${order.id}';
  if (order.gameOrderId.isNotEmpty) return 'game:${order.gameOrderId}';
  return '${order.productId}:${order.coinCost}:${order.createdAt}';
}

String _walletActionLabel(String action) {
  return switch (action.trim().toLowerCase()) {
    'sign_in' || 'daily_signin' => '每日签到',
    'activity_reward' => '活动奖励',
    'login_bonus' || 'login_reward' => '登录赠送',
    'shop_redeem' => '商城兑换',
    'bailian_payment' || 'game_payment' => '游戏支付',
    'horse_race_bet' => '赛马下注',
    'horse_race_reward' => '赛马奖励',
    'admin_adjustment' => '后台调整',
    _ => action.trim().isEmpty ? '余额变动' : action.trim(),
  };
}

_WalletOrderStatus _walletOrderStatus(String status) {
  return switch (status.trim().toLowerCase()) {
    'paid' ||
    'fulfilled' ||
    'completed' ||
    'succeeded' => const _WalletOrderStatus('支付成功', Color(0xFF17845B)),
    'pending' ||
    'created' ||
    'fulfilling' => const _WalletOrderStatus('处理中', Color(0xFFD27A14)),
    'refunded' => const _WalletOrderStatus('已退款', Color(0xFF52647A)),
    'failed' ||
    'cancelled' ||
    'delivery_failed' => const _WalletOrderStatus('支付失败', Color(0xFFC74848)),
    _ => const _WalletOrderStatus('状态未知', AppTheme.textSecondary),
  };
}

String _walletOrderSource(String source) {
  return switch (source.trim().toLowerCase()) {
    'bailian' => '花雨世界',
    'shop' => '商城',
    'horse_race' => '赛马',
    _ => '',
  };
}

String _walletDateTime(String raw) {
  if (raw.trim().isEmpty) return '';
  final normalized = raw.trim().replaceFirst(' ', 'T');
  final hasOffset = RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$').hasMatch(normalized);
  final parsed = DateTime.tryParse(hasOffset ? normalized : '${normalized}Z');
  return parsed == null ? raw : _walletDate(parsed);
}

String _walletDate(DateTime? value) {
  if (value == null) return '';
  final local = value.toLocal();
  return '${local.year}.${_twoDigits(local.month)}.${_twoDigits(local.day)} '
      '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}

String _walletFilterDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}.${_twoDigits(local.month)}.${_twoDigits(local.day)}';
}

String _walletErrorMessage(Object error) {
  return switch (error) {
    InteractionServiceException(:final message) => message,
    BailianGameException(:final message) => message,
    _ => '钱包加载失败，请稍后重试',
  };
}

class _WalletOrderStatus {
  const _WalletOrderStatus(this.label, this.color);

  final String label;
  final Color color;
}
