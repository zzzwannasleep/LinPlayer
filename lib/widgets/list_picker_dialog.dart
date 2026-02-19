import 'package:flutter/material.dart';

Future<int?> showListPickerDialog({
  required BuildContext context,
  required String title,
  required List<String> items,
  int? initialIndex,
  String searchHintText = '搜索',
  String emptyText = '无可选项',
  double width = 560,
  double height = 420,
}) async {
  if (items.isEmpty) return null;

  final controller = TextEditingController();
  final picked = await showDialog<int>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final q = controller.text.trim().toLowerCase();
          final filtered = <int>[];
          for (var i = 0; i < items.length; i++) {
            final v = items[i];
            if (q.isEmpty || v.toLowerCase().contains(q)) {
              filtered.add(i);
            }
          }

          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: searchHintText,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: height,
                    child: filtered.isEmpty
                        ? Center(child: Text(emptyText))
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final originalIndex = filtered[index];
                              final selected = originalIndex == initialIndex;
                              return ListTile(
                                dense: true,
                                title: Text(
                                  items[originalIndex],
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: selected
                                    ? const Icon(Icons.check, size: 18)
                                    : null,
                                onTap: () => Navigator.of(dialogContext)
                                    .pop(originalIndex),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
            ],
          );
        },
      );
    },
  );

  controller.dispose();
  return picked;
}

