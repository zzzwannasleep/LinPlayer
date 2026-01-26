// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.content.SharedPreferences;
import androidx.annotation.NonNull;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.LoadControl;

/** LinPlayer-specific buffering policy for ExoPlayer. */
public final class LinPlayerBuffering {
  private LinPlayerBuffering() {}

  private static final String SHARED_PREFERENCES_NAME = "FlutterSharedPreferences";
  private static final String KEY_PREFIX = "flutter.";
  // Must match shared_preferences_android's DOUBLE_PREFIX constant.
  private static final String DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu";

  private static final int MB = 1024 * 1024;

  private static final int DEFAULT_TOTAL_MB = 500;
  private static final double DEFAULT_BACK_RATIO = 0.05;
  private static final double MAX_BACK_RATIO = 0.30;

  private static final String KEY_TOTAL_MB = KEY_PREFIX + "mpvCacheSizeMb_v1";
  private static final String KEY_PRESET = KEY_PREFIX + "playbackBufferPreset_v1";
  private static final String KEY_BACK_RATIO = KEY_PREFIX + "playbackBufferBackRatio_v1";

  @NonNull
  public static LoadControl createLoadControl(@NonNull Context context) {
    final SharedPreferences prefs =
        context.getSharedPreferences(SHARED_PREFERENCES_NAME, Context.MODE_PRIVATE);

    final int totalMb = clampInt(readFlutterInt(prefs, KEY_TOTAL_MB, DEFAULT_TOTAL_MB), 200, 2048);
    final String presetId = readFlutterString(prefs, KEY_PRESET, "seekFast");
    final double defaultRatio = defaultBackRatioForPreset(presetId);
    final double backRatio = clampDouble(readFlutterDouble(prefs, KEY_BACK_RATIO, defaultRatio), 0.0, MAX_BACK_RATIO);

    final int targetMb = Math.min(totalMb, exoTargetMaxMb());
    final int targetBytes = targetMb * MB;
    final int backMb = clampInt(Math.round((float) (targetMb * backRatio)), 0, targetMb);

    final BufferDurations durations = bufferDurationsForPreset(presetId, backRatio);

    return new DefaultLoadControl.Builder()
        .setPrioritizeTimeOverSizeThresholds(false)
        .setTargetBufferBytes(targetBytes)
        // Rough mapping: treat 1MB ~= 1 second at ~8Mbps average bitrate.
        .setBackBuffer(backMb * 1000, /* retainBackBufferFromKeyframe= */ true)
        .setBufferDurationsMs(
            durations.minBufferMs,
            durations.maxBufferMs,
            durations.bufferForPlaybackMs,
            durations.bufferForPlaybackAfterRebufferMs)
        .build();
  }

  private static int exoTargetMaxMb() {
    // Safety: ExoPlayer buffering is memory-intensive. Cap it relative to heap size.
    // We use a conservative fraction (25%) and clamp to a sane range.
    final long maxBytes = Runtime.getRuntime().maxMemory();
    if (maxBytes <= 0) return 256;
    final int heapMb = (int) (maxBytes / MB);
    final int capMb = Math.round(heapMb * 0.25f);
    return clampInt(capMb, 64, 512);
  }

  private static final class BufferDurations {
    final int minBufferMs;
    final int maxBufferMs;
    final int bufferForPlaybackMs;
    final int bufferForPlaybackAfterRebufferMs;

    BufferDurations(
        int minBufferMs, int maxBufferMs, int bufferForPlaybackMs, int bufferForPlaybackAfterRebufferMs) {
      this.minBufferMs = minBufferMs;
      this.maxBufferMs = maxBufferMs;
      this.bufferForPlaybackMs = bufferForPlaybackMs;
      this.bufferForPlaybackAfterRebufferMs = bufferForPlaybackAfterRebufferMs;
    }
  }

  @NonNull
  private static BufferDurations bufferDurationsForPreset(@NonNull String presetId, double backRatio) {
    final String p = presetId.trim();
    if (p.equals("seekFast")) {
      return new BufferDurations(
          /* minBufferMs= */ 8_000,
          /* maxBufferMs= */ 600_000,
          /* bufferForPlaybackMs= */ 250,
          /* bufferForPlaybackAfterRebufferMs= */ 750);
    }
    if (p.equals("stable")) {
      return new BufferDurations(
          /* minBufferMs= */ 30_000,
          /* maxBufferMs= */ 600_000,
          /* bufferForPlaybackMs= */ 1_500,
          /* bufferForPlaybackAfterRebufferMs= */ 2_500);
    }
    if (p.equals("custom")) {
      if (backRatio <= 0.10) {
        return bufferDurationsForPreset("seekFast", backRatio);
      }
      if (backRatio >= 0.22) {
        return bufferDurationsForPreset("stable", backRatio);
      }
      return bufferDurationsForPreset("balanced", backRatio);
    }
    // balanced (default)
    return new BufferDurations(
        /* minBufferMs= */ 15_000,
        /* maxBufferMs= */ 600_000,
        /* bufferForPlaybackMs= */ 500,
        /* bufferForPlaybackAfterRebufferMs= */ 1_000);
  }

  private static double defaultBackRatioForPreset(@NonNull String presetId) {
    final String p = presetId.trim();
    if (p.equals("balanced")) return 0.15;
    if (p.equals("stable")) return 0.25;
    return DEFAULT_BACK_RATIO;
  }

  private static int clampInt(int v, int min, int max) {
    return Math.max(min, Math.min(max, v));
  }

  private static double clampDouble(double v, double min, double max) {
    return Math.max(min, Math.min(max, v));
  }

  private static int readFlutterInt(@NonNull SharedPreferences prefs, @NonNull String key, int fallback) {
    try {
      return (int) prefs.getLong(key, (long) fallback);
    } catch (ClassCastException e) {
      // Some builds may store ints as strings; try parsing.
      final String s = prefs.getString(key, null);
      if (s != null) {
        try {
          return Integer.parseInt(s);
        } catch (NumberFormatException ignored) {}
      }
      return fallback;
    }
  }

  @NonNull
  private static String readFlutterString(
      @NonNull SharedPreferences prefs, @NonNull String key, @NonNull String fallback) {
    final String s = prefs.getString(key, null);
    return s == null ? fallback : s;
  }

  private static double readFlutterDouble(
      @NonNull SharedPreferences prefs, @NonNull String key, double fallback) {
    final String s = prefs.getString(key, null);
    if (s == null) return fallback;
    final String raw = s.startsWith(DOUBLE_PREFIX) ? s.substring(DOUBLE_PREFIX.length()) : s;
    try {
      return Double.parseDouble(raw);
    } catch (NumberFormatException ignored) {
      return fallback;
    }
  }
}
