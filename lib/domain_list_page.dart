import 'package:flutter/material.dart';

import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'player_screen.dart';

class DomainListPage extends StatelessWidget {
  const DomainListPage({super.key, required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final domains = appState.domains;
        return Scaffold(
          appBar: AppBar(
            title: const Text('可用线路'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: appState.isLoading ? null : () => appState.refreshDomains(),
                tooltip: '刷新线路',
              ),
              IconButton(
                icon: const Icon(Icons.logout),
                onPressed: appState.isLoading ? null : () => appState.logout(),
                tooltip: '退出登录',
              ),
            ],
          ),
          body: appState.isLoading
              ? const Center(child: CircularProgressIndicator())
              : domains.isEmpty
                  ? const Center(child: Text('暂无线路，点击右上角刷新重试'))
                  : ListView.builder(
                      itemCount: domains.length,
                      itemBuilder: (context, index) {
                        final DomainInfo d = domains[index];
                        return ListTile(
                          leading: const Icon(Icons.cloud),
                          title: Text(d.name.isNotEmpty ? d.name : d.url),
                          subtitle: Text(d.url),
                          onTap: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('已选择：${d.url}')),
                            );
                          },
                        );
                      },
                    ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlayerScreen()),
              );
            },
            icon: const Icon(Icons.play_circle),
            label: const Text('本地播放器'),
          ),
        );
      },
    );
  }
}
