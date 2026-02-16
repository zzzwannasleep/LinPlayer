import 'dart:ui';

import 'package:flutter/material.dart';

import 'desktop_ui_shared.dart';

class DesktopSeriesDetailPageUi extends StatelessWidget {
  const DesktopSeriesDetailPageUi({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HeroSection(),
        SizedBox(height: 40),
        EpisodePreviewRow(),
        SizedBox(height: 40),
        SeasonRow(),
        SizedBox(height: 40),
        CastRow(),
        SizedBox(height: 40),
        SimilarRow(),
        SizedBox(height: 40),
        ExternalLinkRow(),
      ],
    );
  }
}

class HeroSection extends StatelessWidget {
  const HeroSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        height: 430,
        child: Stack(
          children: [
            const Positioned.fill(
              child: UiPlaceholderImage(
                url:
                    'https://placehold.co/1400x700/0F172A/90A3C2/png?text=HERO+BACKGROUND',
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
                      Colors.black.withValues(alpha: 0.45),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: const SizedBox(
                      width: 250,
                      child: AspectRatio(
                        aspectRatio: 2 / 3,
                        child: UiPlaceholderImage(
                          url:
                              'https://placehold.co/500x750/111B2E/B3C3D9/png?text=MAIN+POSTER',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 26),
                  const Expanded(child: _HeroInfo()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroInfo extends StatelessWidget {
  const _HeroInfo();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          'Placeholder Series Main Title',
          style: TextStyle(
            color: DesktopUiTheme.textPrimary,
            fontSize: 40,
            fontWeight: FontWeight.w800,
            height: 1.08,
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
            UiTagChip(label: 'Placeholder Tag'),
          ],
        ),
        SizedBox(height: 18),
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
            UiGlassButton(
                label: 'Placeholder Icon', icon: Icons.favorite_border),
          ],
        ),
        SizedBox(height: 18),
        Text(
          'Placeholder Description Placeholder Description Placeholder Description '
          'Placeholder Description Placeholder Description Placeholder Description.',
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

class EpisodePreviewRow extends StatelessWidget {
  const EpisodePreviewRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const UiSectionHeader(title: 'Placeholder Episode Preview'),
        const SizedBox(height: 16),
        UiHorizontalScrollArea(
          children: List<Widget>.generate(
            7,
            (index) => UiEpisodeCard(index: index),
          ),
        ),
      ],
    );
  }
}

class SeasonRow extends StatelessWidget {
  const SeasonRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const UiSectionHeader(title: 'Placeholder Season Row'),
        const SizedBox(height: 16),
        UiHorizontalScrollArea(
          children: List<Widget>.generate(
            6,
            (index) => UiSeasonCard(index: index),
          ),
        ),
      ],
    );
  }
}

class CastRow extends StatelessWidget {
  const CastRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const UiSectionHeader(title: 'Placeholder Cast Row'),
        const SizedBox(height: 16),
        UiHorizontalScrollArea(
          children: List<Widget>.generate(
            10,
            (index) => UiCastCard(index: index),
          ),
        ),
      ],
    );
  }
}

class SimilarRow extends StatelessWidget {
  const SimilarRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const UiSectionHeader(title: 'Placeholder Similar Row'),
        const SizedBox(height: 16),
        UiHorizontalScrollArea(
          children: List<Widget>.generate(
            7,
            (index) => UiPosterCard(index: index),
          ),
        ),
      ],
    );
  }
}

class ExternalLinkRow extends StatelessWidget {
  const ExternalLinkRow({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UiSectionHeader(title: 'Placeholder External Link Row'),
        SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            UiGlassButton(label: 'Placeholder Link 01'),
            UiGlassButton(label: 'Placeholder Link 02'),
            UiGlassButton(label: 'Placeholder Link 03'),
            UiGlassButton(label: 'Placeholder Link 04'),
            UiGlassButton(label: 'Placeholder Link 05'),
          ],
        ),
      ],
    );
  }
}
