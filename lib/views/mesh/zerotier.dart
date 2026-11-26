import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

/// ZeroTier UI 雏形页。
///
/// 仅提供页面结构与交互占位，具体内核集成与状态同步待后续实现。
class ZeroTierView extends StatelessWidget {
  const ZeroTierView({super.key});

  static const Map<String, Map<String, String>> _strings = {
    'enable': {'zh': '启用 ZeroTier', 'en': 'Enable ZeroTier'},
    'enableDesc': {
      'zh': '通过 ZeroTier 虚拟局域网互联（UI 预览，功能开发中）',
      'en': 'Connect via ZeroTier virtual LAN (UI preview, coming soon)',
    },
    'comingSoon': {
      'zh': 'ZeroTier 功能正在开发中，敬请期待',
      'en': 'ZeroTier support is under development',
    },
    'status': {'zh': '节点状态', 'en': 'Node Status'},
    'statusValue': {'zh': '未集成（UI 雏形）', 'en': 'Not integrated (Preview)'},
    'nodeId': {'zh': '节点 ID', 'en': 'Node ID'},
    'managedIps': {'zh': '虚拟 IP', 'en': 'Managed IPs'},
    'networks': {'zh': '网络列表', 'en': 'Networks'},
    'joinNetwork': {'zh': '加入网络', 'en': 'Join Network'},
    'joinNetworkDesc': {
      'zh': '输入 16 位 ZeroTier Network ID',
      'en': 'Enter 16-digit ZeroTier Network ID',
    },
    'noNetworks': {'zh': '暂未加入任何网络', 'en': 'No networks joined yet'},
    'settings': {'zh': '高级设置', 'en': 'Advanced Settings'},
    'planet': {'zh': '自定义 Planet / Moon', 'en': 'Custom Planet / Moon'},
    'planetDesc': {
      'zh': '配置私有根服务器或中继节点',
      'en': 'Configure custom root servers or moons',
    },
    'allowDns': {'zh': '接管网络 DNS', 'en': 'Accept Managed DNS'},
    'allowDnsDesc': {
      'zh': '允许 ZeroTier 网络下发 DNS 配置',
      'en': 'Allow ZeroTier to configure DNS for joined networks',
    },
  };

  void _notifyComingSoon(String Function(String) t) {
    globalState.showNotifier(t('comingSoon'));
  }

  @override
  Widget build(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    String t(String key) => _strings[key]?[lang] ?? _strings[key]?['en'] ?? key;

    final items = <Widget>[
      ...generateSection(
        items: [
          ListItem.switchItem(
            leading: const Icon(Icons.lan_outlined),
            title: Text(t('enable')),
            subtitle: Text(t('enableDesc')),
            delegate: SwitchDelegate(
              value: false,
              onChanged: (_) => _notifyComingSoon(t),
            ),
          ),
        ],
      ),
      ...generateSection(
        title: t('status'),
        items: [
          ListItem(
            leading: const Icon(Icons.info_outline),
            title: Text(t('statusValue')),
            subtitle: Text('${t('nodeId')}: --   ·   ${t('managedIps')}: --'),
          ),
        ],
      ),
      ...generateSection(
        title: t('networks'),
        items: [
          ListItem(
            leading: const Icon(Icons.add_circle_outline),
            title: Text(t('joinNetwork')),
            subtitle: Text(t('joinNetworkDesc')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _notifyComingSoon(t),
          ),
          ListItem(
            leading: const Icon(Icons.cloud_off_outlined),
            title: Text(t('noNetworks')),
          ),
        ],
      ),
      ...generateSection(
        title: t('settings'),
        items: [
          ListItem(
            leading: const Icon(Icons.public_outlined),
            title: Text(t('planet')),
            subtitle: Text(t('planetDesc')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _notifyComingSoon(t),
          ),
          ListItem.switchItem(
            leading: const Icon(Icons.dns_outlined),
            title: Text(t('allowDns')),
            subtitle: Text(t('allowDnsDesc')),
            delegate: SwitchDelegate(
              value: false,
              onChanged: (_) => _notifyComingSoon(t),
            ),
          ),
        ],
      ),
    ];

    return generateListView(items);
  }
}
