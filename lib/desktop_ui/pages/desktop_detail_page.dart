import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';

import '../theme/desktop_theme_extension.dart';
import '../view_models/desktop_detail_view_model.dart';
import '../widgets/desktop_action_button_group.dart';
import '../widgets/desktop_hero_section.dart';
import '../widgets/desktop_horizontal_section.dart';
import '../widgets/desktop_media_card.dart';
import '../widgets/hover_effect_wrapper.dart';

class DesktopDetailPage extends StatefulWidget {
  const DesktopDetailPage({
    super.key,
    required this.viewModel,
    this.onOpenItem,
    this.onPlayPressed,
  });

  final DesktopDetailViewModel viewModel;
  final ValueChanged<MediaItem>? onOpenItem;
  final VoidCallback? onPlayPressed;

  @override
  State<DesktopDetailPage> createState() => _DesktopDetailPageState();
}

class _DesktopDetailPageState extends State<DesktopDetailPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.viewModel.load());
  }

  @override
  void didUpdateWidget(covariant DesktopDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.viewModel, widget.viewModel)) {
      unawaited(widget.viewModel.load(forceRefresh: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        final desktopTheme = DesktopThemeExtension.of(context);
        final vm = widget.viewModel;

        if (vm.loading && vm.error == null && vm.detail.id.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        return DecoratedBox(
          decoration: BoxDecoration(
            color: desktopTheme.surface.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: desktopTheme.border),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: DesktopHeroSection(
                    item: vm.detail,
                    access: vm.access,
                    overview: vm.detail.overview,
                    actionButtons: DesktopActionButtonGroup(
                      onPlay: widget.onPlayPressed,
                      onToggleFavorite: vm.toggleFavorite,
                      isFavorite: vm.favorite,
                    ),
                  ),
                ),
                if ((vm.error ?? '').trim().isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  SliverToBoxAdapter(
                    child: _ErrorBanner(message: vm.error!),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 28)),
                SliverToBoxAdapter(
                  child: DesktopHorizontalSection(
                    title: 'Episodes',
                    subtitle: vm.seasons.isEmpty
                        ? null
                        : 'From ${vm.seasons.length} seasons',
                    emptyLabel: 'No episodes available',
                    viewportHeight: 390,
                    children: vm.episodes
                        .map(
                          (item) => DesktopMediaCard(
                            item: item,
                            access: vm.access,
                            width: 214,
                            onTap: widget.onOpenItem == null
                                ? null
                                : () => widget.onOpenItem!(item),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 30)),
                SliverToBoxAdapter(
                  child: DesktopHorizontalSection(
                    title: 'Recommended',
                    emptyLabel: 'No recommendations yet',
                    viewportHeight: 390,
                    children: vm.similar
                        .map(
                          (item) => DesktopMediaCard(
                            item: item,
                            access: vm.access,
                            width: 214,
                            onTap: widget.onOpenItem == null
                                ? null
                                : () => widget.onOpenItem!(item),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 30)),
                SliverToBoxAdapter(
                  child: DesktopHorizontalSection(
                    title: 'Cast',
                    emptyLabel: 'No cast data',
                    viewportHeight: 184,
                    children: vm.people
                        .map(
                          (person) => _PeopleCard(
                            name: person.name,
                            role: person.role,
                            imageUrl: vm.personImageUrl(person),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x33D64646),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x66FF7777)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Color(0xFFFF9D9D)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeopleCard extends StatelessWidget {
  const _PeopleCard({
    required this.name,
    required this.role,
    required this.imageUrl,
  });

  final String name;
  final String role;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);

    return SizedBox(
      width: 210,
      child: HoverEffectWrapper(
        borderRadius: BorderRadius.circular(14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: desktopTheme.surfaceElevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: desktopTheme.border),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(14),
                ),
                child: SizedBox(
                  width: 84,
                  height: double.infinity,
                  child: _PeopleImage(url: imageUrl),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.trim().isEmpty ? 'Unknown' : name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: desktopTheme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (role.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          role,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: desktopTheme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PeopleImage extends StatelessWidget {
  const _PeopleImage({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);
    if (url != null && url!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url!,
        fit: BoxFit.cover,
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) => _PeopleImageFallback(color: desktopTheme),
      );
    }
    return _PeopleImageFallback(color: desktopTheme);
  }
}

class _PeopleImageFallback extends StatelessWidget {
  const _PeopleImageFallback({required this.color});

  final DesktopThemeExtension color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.surface,
            color.surfaceElevated,
          ],
        ),
      ),
      child: Icon(
        Icons.person_outline_rounded,
        color: color.textMuted,
      ),
    );
  }
}
