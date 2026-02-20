package com.linplayer.tvlegacy;

import android.content.Intent;
import android.os.Bundle;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.TextView;
import android.widget.Toast;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import com.linplayer.tvlegacy.backend.Backends;
import com.linplayer.tvlegacy.backend.Callback;

public final class EpisodeDetailActivity extends AppCompatActivity {
    static final String EXTRA_SHOW_ID = "show_id";
    static final String EXTRA_EPISODE_INDEX = "episode_index";

    private String showId;
    private int episodeIndex;
    private String showTitle = "Unknown show";
    private Show show;
    private Episode episode;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_episode_detail);

        showId = getIntent().getStringExtra(EXTRA_SHOW_ID);
        episodeIndex = getIntent().getIntExtra(EXTRA_EPISODE_INDEX, 1);

        if (showId == null || showId.trim().isEmpty()) {
            Toast.makeText(this, "Missing show id", Toast.LENGTH_LONG).show();
            finish();
            return;
        }

        TextView titleText = findViewById(R.id.episode_title);
        TextView metaText = findViewById(R.id.episode_meta);
        TextView descText = findViewById(R.id.episode_desc);
        ImageView thumbView = findViewById(R.id.episode_thumb);

        titleText.setText("Loading...");
        metaText.setText("EP " + episodeIndex);
        descText.setText("");

        Button backBtn = findViewById(R.id.btn_back);
        backBtn.setOnClickListener(v -> finish());

        Button playBtn = findViewById(R.id.btn_play);
        playBtn.setOnClickListener(
                v -> {
                    Episode current = episode;
                    if (current == null
                            || current.mediaUrl == null
                            || current.mediaUrl.trim().isEmpty()) {
                        Toast.makeText(this, "Missing media url", Toast.LENGTH_LONG).show();
                        return;
                    }
                    Intent i = new Intent(this, PlayerActivity.class);
                    i.putExtra(PlayerActivity.EXTRA_TITLE, showTitle + " · " + current.title);
                    i.putExtra(PlayerActivity.EXTRA_URL, current.mediaUrl);
                    startActivity(i);
                });

        Backends.media(this)
                .getShow(
                        showId,
                        new Callback<Show>() {
                            @Override
                            public void onSuccess(Show show) {
                                if (isFinishing() || isDestroyed()) return;
                                EpisodeDetailActivity.this.show = show;
                                showTitle = show != null ? show.title : "Unknown show";
                                metaText.setText(showTitle + " · EP " + episodeIndex);
                                if (episode == null && show != null) {
                                    ImageLoader.load(thumbView, show.backdropUrl, dpToPx(1280));
                                }
                            }

                            @Override
                            public void onError(Throwable error) {
                                if (isFinishing() || isDestroyed()) return;
                                showTitle = "Unknown show";
                                metaText.setText(showTitle + " · EP " + episodeIndex);
                            }
                        });

        Backends.media(this)
                .getEpisode(
                        showId,
                        episodeIndex,
                        new Callback<Episode>() {
                            @Override
                            public void onSuccess(Episode v) {
                                if (isFinishing() || isDestroyed()) return;
                                episode = v;
                                if (v != null && v.title != null && !v.title.trim().isEmpty()) {
                                    titleText.setText(v.title);
                                } else {
                                    titleText.setText("Episode " + episodeIndex);
                                }

                                metaText.setText(buildEpisodeMeta(showTitle, v, episodeIndex));

                                String desc = v != null ? v.overview : "";
                                if (desc == null || desc.trim().isEmpty()) desc = "No overview";
                                descText.setText(desc);

                                String thumb = v != null ? v.thumbUrl : "";
                                if ((thumb == null || thumb.trim().isEmpty()) && show != null) {
                                    thumb = show.backdropUrl;
                                }
                                ImageLoader.load(thumbView, thumb, dpToPx(1280));
                            }

                            @Override
                            public void onError(Throwable error) {
                                if (isFinishing() || isDestroyed()) return;
                                episode = null;
                                titleText.setText("Episode " + episodeIndex);
                                descText.setText(
                                        "Load episode failed: " + String.valueOf(error.getMessage()));
                            }
                        });
    }

    private int dpToPx(int dp) {
        float density = getResources().getDisplayMetrics().density;
        return Math.round(dp * density);
    }

    private static String buildEpisodeMeta(String showTitle, Episode episode, int index) {
        String st = showTitle != null ? showTitle.trim() : "";
        StringBuilder sb = new StringBuilder();
        if (!st.isEmpty()) sb.append(st);

        int season = episode != null ? episode.seasonNumber : 0;
        int ep = episode != null ? episode.episodeNumber : 0;
        if (season > 0 && ep > 0) {
            if (sb.length() > 0) sb.append(" · ");
            sb.append("S").append(season).append("E").append(ep);
        } else {
            if (sb.length() > 0) sb.append(" · ");
            sb.append("EP ").append(index);
        }
        return sb.toString();
    }
}
