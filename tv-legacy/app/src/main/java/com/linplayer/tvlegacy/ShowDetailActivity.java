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
import java.util.List;

public final class ShowDetailActivity extends AppCompatActivity {
    static final String EXTRA_SHOW_ID = "show_id";

    private String showId;
    private Show show;
    private Episode firstEpisode;

    private TextView titleText;
    private TextView metaText;
    private TextView overviewText;
    private ImageView posterView;
    private ImageView backdropView;
    private Button playBtn;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_show_detail);

        showId = getIntent().getStringExtra(EXTRA_SHOW_ID);

        titleText = findViewById(R.id.show_title);
        metaText = findViewById(R.id.show_meta);
        overviewText = findViewById(R.id.show_overview);
        posterView = findViewById(R.id.show_poster);
        backdropView = findViewById(R.id.show_backdrop);
        titleText.setText("Loading...");
        metaText.setText("");
        overviewText.setText("");

        Button backBtn = findViewById(R.id.btn_back);
        backBtn.setOnClickListener(v -> finish());

        Button episodesBtn = findViewById(R.id.btn_open_episodes);
        episodesBtn.setOnClickListener(
                v -> {
                    Intent i = new Intent(this, EpisodeListActivity.class);
                    i.putExtra(EpisodeListActivity.EXTRA_SHOW_ID, showId);
                    startActivity(i);
                });

        playBtn = findViewById(R.id.btn_play);
        playBtn.setOnClickListener(
                v -> {
                    Episode first = firstEpisode;
                    if (first == null) {
                        Toast.makeText(this, "Loading episodes...", Toast.LENGTH_SHORT).show();
                        return;
                    }
                    Intent i = new Intent(this, PlayerActivity.class);
                    i.putExtra(PlayerActivity.EXTRA_TITLE, (show != null ? show.title : "Show") + " · " + first.title);
                    i.putExtra(PlayerActivity.EXTRA_URL, first.mediaUrl);
                    startActivity(i);
                });

        Backends.media(this)
                .getShow(
                        showId,
                        new Callback<Show>() {
                            @Override
                            public void onSuccess(Show v) {
                                if (isFinishing() || isDestroyed()) return;
                                show = v;
                                if (v == null) {
                                    titleText.setText("Unknown show");
                                    metaText.setText("");
                                    overviewText.setText("");
                                    ImageLoader.load(posterView, "", 0);
                                    ImageLoader.load(backdropView, "", 0);
                                    return;
                                }
                                titleText.setText(v.title);
                                overviewText.setText(v.overview);
                                metaText.setText(buildMetaLine(v));
                                ImageLoader.load(posterView, v.posterUrl, dpToPx(520));
                                ImageLoader.load(backdropView, v.backdropUrl, dpToPx(1280));
                            }

                            @Override
                            public void onError(Throwable error) {
                                if (isFinishing() || isDestroyed()) return;
                                titleText.setText("Load failed");
                                metaText.setText("");
                                overviewText.setText(String.valueOf(error.getMessage()));
                            }
                        });

        Backends.media(this)
                .listEpisodes(
                        showId,
                        new Callback<List<Episode>>() {
                            @Override
                            public void onSuccess(List<Episode> episodes) {
                                if (isFinishing() || isDestroyed()) return;
                                if (episodes == null || episodes.isEmpty()) {
                                    firstEpisode = null;
                                    return;
                                }
                                firstEpisode = episodes.get(0);
                            }

                            @Override
                            public void onError(Throwable error) {
                                if (isFinishing() || isDestroyed()) return;
                                firstEpisode = null;
                            }
                        });
    }

    private int dpToPx(int dp) {
        float density = getResources().getDisplayMetrics().density;
        return Math.round(dp * density);
    }

    private static String buildMetaLine(Show show) {
        if (show == null) return "";
        StringBuilder sb = new StringBuilder();
        String year = show.year != null ? show.year.trim() : "";
        String rating = show.rating != null ? show.rating.trim() : "";
        String genres = show.genres != null ? show.genres.trim() : "";

        if (!year.isEmpty()) sb.append(year);
        if (!rating.isEmpty()) {
            if (sb.length() > 0) sb.append(" · ");
            sb.append("Rating ").append(rating);
        }
        if (!genres.isEmpty()) {
            if (sb.length() > 0) sb.append(" · ");
            sb.append(genres);
        }
        return sb.toString();
    }
}
