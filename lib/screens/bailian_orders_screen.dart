import 'package:flutter/material.dart';

import '../services/bailian_game_service.dart';

class BailianOrdersScreen extends StatefulWidget {
  const BailianOrdersScreen({super.key, required this.token, this.service});

  final String token;
  final BailianGameService? service;

  @override
  State<BailianOrdersScreen> createState() => _BailianOrdersScreenState();
}

class _BailianOrdersScreenState extends State<BailianOrdersScreen> {
  static const _pageSize = 20;
  late final BailianGameService _service;
  final List<BailianPayment> _items = [];
  bool _loading = false;
  bool _hasMore = true;
  int _snapshotMaxId = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? BailianGameService();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _service.listPayments(
        widget.token,
        offset: refresh ? 0 : _items.length,
        limit: _pageSize,
        snapshotMaxId: refresh ? 0 : _snapshotMaxId,
      );
      if (!mounted) return;
      setState(() {
        if (refresh) _items.clear();
        _items.addAll(page.items);
        _hasMore = page.hasMore;
        _snapshotMaxId = page.snapshotMaxId;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的订单')),
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: 420,
            child: Center(
              child: FilledButton(
                onPressed: () => _load(refresh: true),
                child: const Text('加载失败，点击重试'),
              ),
            ),
          ),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 420, child: Center(child: Text('暂无消费记录'))),
        ],
      );
    }
    return ListView.separated(
      key: const ValueKey('bailian-orders-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: _items.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == _items.length) {
          return Center(
            child: TextButton(
              onPressed: _loading ? null : _load,
              child: Text(_loading ? '加载中…' : '加载更多'),
            ),
          );
        }
        return _OrderCard(payment: _items[index]);
      },
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.payment});

  final BailianPayment payment;

  @override
  Widget build(BuildContext context) {
    final createdAt = payment.createdAt?.toLocal();
    final dateText = createdAt == null
        ? '时间未知'
        : '${createdAt.year}-${_two(createdAt.month)}-${_two(createdAt.day)} '
              '${_two(createdAt.hour)}:${_two(createdAt.minute)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    payment.productName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _StatusChip(status: payment.status),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              payment.moneyCents > 0
                  ? '${payment.coinCost} 樱花币  ·  ¥${(payment.moneyCents / 100).toStringAsFixed(2)}'
                  : '${payment.coinCost} 樱花币',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 6),
            Text(dateText, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    const labels = {
      'paid': '已支付',
      'fulfilling': '发货中',
      'fulfilled': '已完成',
      'delivery_failed': '发货失败',
      'refunded': '已退款',
      'completed': '已完成',
    };
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(labels[status] ?? status),
    );
  }
}
