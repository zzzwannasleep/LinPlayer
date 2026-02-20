package com.linplayer.tvlegacy;

import android.net.Uri;
import android.os.Bundle;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.TextView;
import android.widget.Toast;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import com.google.android.exoplayer2.MediaItem;
import com.google.android.exoplayer2.SimpleExoPlayer;
import com.google.android.exoplayer2.source.DefaultMediaSourceFactory;
import com.google.android.exoplayer2.ui.PlayerView;
import com.google.android.exoplayer2.upstream.DataSource;
import com.linplayer.tvlegacy.servers.ServerConfig;
import com.linplayer.tvlegacy.servers.ServerStore;
import java.io.IOException;
import okhttp3.Credentials;
import okhttp3.Interceptor;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

public final class PlayerActivity extends AppCompatActivity {
    static final String EXTRA_URL = "url";
    static final String EXTRA_TITLE = "title";

    private SimpleExoPlayer player;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_player);

        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        Button backBtn = findViewById(R.id.btn_back);
        backBtn.setOnClickListener(v -> finish());

        String title = getIntent().getStringExtra(EXTRA_TITLE);
        String url = getIntent().getStringExtra(EXTRA_URL);

        TextView titleText = findViewById(R.id.player_title);
        if (title != null && !title.trim().isEmpty()) {
            titleText.setText(title.trim());
        }

        if (url == null || url.trim().isEmpty()) {
            Toast.makeText(this, "Missing media url", Toast.LENGTH_LONG).show();
            return;
        }

        if (AppPrefs.isProxyEnabled(this)) {
            ProxyService.start(this);
        }

        PlayerView playerView = findViewById(R.id.player_view);

        OkHttpClient playbackClient = NetworkClients.okHttp(this);
        ServerConfig active = ServerStore.getActive(this);
        if (active != null && active.isType("webdav")) {
            String base = normalizeBaseUrl(active.baseUrl);
            String play = url.trim();
            if (!base.isEmpty() && play.startsWith(base)) {
                String auth = Credentials.basic(active.username, active.password);
                playbackClient =
                        playbackClient
                                .newBuilder()
                                .addInterceptor(
                                        new Interceptor() {
                                            @Override
                                            public Response intercept(Chain chain)
                                                    throws IOException {
                                                Request r =
                                                        chain.request()
                                                                .newBuilder()
                                                                .header("Authorization", auth)
                                                                .build();
                                                return chain.proceed(r);
                                            }
                                        })
                                .build();
            }
        }

        DataSource.Factory dataSourceFactory = ExoNetwork.dataSourceFactory(this, playbackClient);
        DefaultMediaSourceFactory mediaSourceFactory = new DefaultMediaSourceFactory(dataSourceFactory);
        player =
                new SimpleExoPlayer.Builder(this)
                        .setMediaSourceFactory(mediaSourceFactory)
                        .build();
        playerView.setPlayer(player);

        MediaItem item = MediaItem.fromUri(Uri.parse(url.trim()));
        player.setMediaItem(item);
        player.prepare();
        player.play();
    }

    @Override
    protected void onStop() {
        super.onStop();
        if (player != null) {
            player.release();
            player = null;
        }
    }

    private static String normalizeBaseUrl(String baseUrl) {
        String v = baseUrl != null ? baseUrl.trim() : "";
        while (v.endsWith("/")) v = v.substring(0, v.length() - 1);
        return v;
    }
}
