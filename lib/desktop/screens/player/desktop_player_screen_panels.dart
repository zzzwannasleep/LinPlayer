part of 'desktop_player_screen.dart';

class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _needsScroll = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
  }

  @override
  void didUpdateWidget(_MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller.stop();
      _controller.reset();
      _needsScroll = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _checkOverflow(BoxConstraints constraints) {
    final textPainter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout(maxWidth: double.infinity);
    _needsScroll = textPainter.width > constraints.maxWidth;
    if (_needsScroll && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!_needsScroll && _controller.isAnimating) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _checkOverflow(constraints);
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              if (!_needsScroll) return child!;
              final textPainter = TextPainter(
                text: TextSpan(text: widget.text, style: widget.style),
                textDirection: TextDirection.ltr,
              );
              textPainter.layout(maxWidth: double.infinity);
              final offset = (textPainter.width - constraints.maxWidth) *
                  _controller.value;
              return Transform.translate(
                offset: Offset(-offset, 0),
                child: child,
              );
            },
            child: Text(widget.text,
                style: widget.style, overflow: TextOverflow.ellipsis),
          ),
        );
      },
    );
  }
}

/// 选集列表（右侧面板内容，自动适配深浅色）。
class _EpisodeSelectorList extends ConsumerWidget {
  final String seriesId;
  final String currentEpisodeId;
  final String? currentMediaSourceId;

  const _EpisodeSelectorList({
    required this.seriesId,
    required this.currentEpisodeId,
    this.currentMediaSourceId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodesAsync =
        ref.watch(episodesProvider((seriesId: seriesId, seasonId: null)));
    final colors = PlayerPanelColors.resolve(context);

    return episodesAsync.when(
      data: (episodes) => DesktopSmoothScrollBuilder(
        builder: (context, controller) => ListView.builder(
          controller: controller,
          itemCount: episodes.length,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemBuilder: (context, index) {
            final episode = episodes[index];
            final isCurrent = episode.id == currentEpisodeId;
            return PanelOptionTile(
              label: '第 ${episode.indexNumber ?? index + 1} 集 · ${episode.name}',
              selected: isCurrent,
              trailing: isCurrent
                  ? Icon(Icons.play_arrow_rounded, color: colors.accent)
                  : null,
              onTap: () {
                if (!isCurrent) {
                  context.replace(
                    '/player/${episode.id}'
                    '${currentMediaSourceId != null ? '?mediaSourceId=$currentMediaSourceId' : ''}',
                  );
                }
                Navigator.pop(context);
              },
            );
          },
        ),
      ),
      loading: () => Center(
        child: CircularProgressIndicator(color: colors.accent),
      ),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text('加载失败: $error',
              style: TextStyle(color: colors.textSecondary)),
        ),
      ),
    );
  }
}

/// 跳过片头时间输入（秒），自动适配深浅色。
class _SkipTimeField extends ConsumerWidget {
  final String label;
  final StateProvider<int> provider;

  const _SkipTimeField({required this.label, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(provider);
    final colors = PlayerPanelColors.resolve(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 16, 6),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textSecondary, fontSize: 14)),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: TextFormField(
              initialValue: value.toString(),
              keyboardType: TextInputType.number,
              style: TextStyle(color: colors.text),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: colors.controlTrack,
                enabledBorder: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(PlayerPanelTokens.itemRadius),
                  borderSide: BorderSide(color: colors.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(PlayerPanelTokens.itemRadius),
                  borderSide: BorderSide(color: colors.accent),
                ),
                border: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(PlayerPanelTokens.itemRadius),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onChanged: (text) {
                final val = int.tryParse(text);
                if (val != null && val >= 0) {
                  ref.read(provider.notifier).state = val;
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
