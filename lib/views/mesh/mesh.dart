import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/config/tailscale.dart';
import 'package:bett_box/views/mesh/zerotier.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

class _MeshTab {
  final String label;
  final Widget child;

  const _MeshTab({required this.label, required this.child});
}

/// Mesh 页面。
///
/// 在页面上方提供与「代理」页一致的选项卡，用于切换不同的组网组件
/// （如 Tailscale、ZeroTier 等）。
class MeshView extends StatefulWidget {
  const MeshView({super.key});

  @override
  State<MeshView> createState() => _MeshViewState();
}

class _MeshViewState extends State<MeshView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const List<_MeshTab> _tabs = [
    _MeshTab(
      label: 'Tailscale',
      child: KeepScope(keep: true, child: TailscaleListView(asPage: false)),
    ),
    _MeshTab(
      label: 'ZeroTier',
      child: KeepScope(keep: true, child: ZeroTierView()),
    ),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Widget _buildTabBar() {
    if (globalState.isAndroidTV) {
      return TabBar(
        controller: _tabController,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        dividerColor: Colors.transparent,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        indicator: BoxDecoration(
          color: context.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        indicatorColor: Colors.transparent,
        labelColor: context.colorScheme.onPrimaryContainer,
        unselectedLabelColor: context.colorScheme.onSurfaceVariant,
        tabs: [
          for (final tab in _tabs)
            Tab(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(tab.label),
              ),
            ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: GroupTabBar(
        controller: _tabController,
        labels: [for (final tab in _tabs) tab.label],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Mesh',
      body: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTabBar(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [for (final tab in _tabs) tab.child],
            ),
          ),
        ],
      ),
    );
  }
}
