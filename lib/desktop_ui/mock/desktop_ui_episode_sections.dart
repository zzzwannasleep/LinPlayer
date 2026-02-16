import 'dart:ui';

import 'package:flutter/material.dart';

import 'desktop_ui_shared.dart';

class DesktopEpisodeDetailPageUi extends StatelessWidget {
  const DesktopEpisodeDetailPageUi({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EpisodeHeroSection(),
        SizedBox(height: 40),
        EpisodeHorizontalList(),
        SizedBox(height: 40),
        MediaInfoPanelSection(),
      ],
    );
  }
}

class EpisodeHeroSection extends StatelessWidget {
  const EpisodeHeroSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        height: 360,
        child: Stack(
          children: [
            const Positioned.fill(
              child: UiPlaceholderImage(
                url:
                    'https://placehold.co/1400x700/111827/A9B7CF/png?text=EPISODE+HERO',
              ),
            ),
            Positioned.fill(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.18),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withValues(alpha: 0.74),
                      Colors.black.withValues(alpha: 0.5),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: const SizedBox(
                      width: 470,
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: UiPlaceholderImage(
                          url:
                              'https://placehold.co/960x540/111A2A/9CAFCA/png?text=EPISODE+SHOT',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  const Expanded(child: _EpisodeHeroInfo()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeHeroInfo extends StatelessWidget {
  const _EpisodeHeroInfo();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Placeholder Episode Main Title',
          style: TextStyle(
            color: DesktopUiTheme.textPrimary,
            fontSize: 34,
            fontWeight: FontWeight.w800,
            height: 1.12,
          ),
        ),
        SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            UiTagChip(label: 'Placeholder Tag'),
            UiTagChip(label: 'Placeholder Tag'),
            UiTagChip(label: 'Placeholder Tag'),
          ],
        ),
        SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            UiGlassButton(
              label: 'Placeholder Primary',
              highlighted: true,
              icon: Icons.play_arrow_rounded,
            ),
            UiGlassButton(label: 'Placeholder Secondary'),
            UiGlassButton(label: 'Placeholder Icon', icon: Icons.add_rounded),
          ],
        ),
        SizedBox(height: 16),
        Text(
          'Placeholder Description Placeholder Description Placeholder Description '
          'Placeholder Description Placeholder Description.',
          style: TextStyle(
            color: Color(0xFFD2D8E4),
            fontSize: 14,
            fontWeight: FontWeight.w500,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class EpisodeHorizontalList extends StatelessWidget {
  const EpisodeHorizontalList({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const UiSectionHeader(title: 'Placeholder Episode Horizontal List'),
        const SizedBox(height: 16),
        UiHorizontalScrollArea(
          children: List<Widget>.generate(
            8,
            (index) => UiEpisodeCard(index: index),
          ),
        ),
      ],
    );
  }
}

class MediaInfoPanelSection extends StatelessWidget {
  const MediaInfoPanelSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const UiSectionHeader(title: 'Placeholder Media Info Panel Section'),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = constraints.maxWidth;
            final columns = switch (maxWidth) {
              > 1200 => 4,
              > 860 => 3,
              > 560 => 2,
              _ => 1,
            };
            final itemWidth = (maxWidth - 16 * (columns - 1)) / columns;

            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: List<Widget>.generate(
                4,
                (index) => SizedBox(
                  width: itemWidth,
                  child: UiInfoCard(index: index),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
