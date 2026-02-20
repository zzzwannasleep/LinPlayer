package com.linplayer.tvlegacy;

import android.content.Intent;
import android.graphics.Bitmap;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.TextView;
import android.widget.Toast;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;
import com.linplayer.tvlegacy.remote.QrCodeUtil;
import com.linplayer.tvlegacy.remote.RemoteControl;
import com.linplayer.tvlegacy.remote.RemoteInfo;
import com.linplayer.tvlegacy.servers.ServerConfig;
import com.linplayer.tvlegacy.servers.ServerStore;
import java.util.List;

public final class ServersActivity extends AppCompatActivity {
    static final String EXTRA_REQUIRE_ONE = "require_one";

    private boolean requireOne;
    private boolean gridMode;

    private RecyclerView listView;
    private ServerAdapter adapter;

    private ImageView qrImage;
    private TextView qrUrlText;

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Runnable pollRunnable =
            new Runnable() {
                @Override
                public void run() {
                    refresh();
                    refreshRemoteQr();
                    if (requireOne && ServerStore.hasAny(ServersActivity.this)) {
                        goHome();
                        return;
                    }
                    mainHandler.postDelayed(this, 1000);
                }
            };

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_servers);

        requireOne = getIntent().getBooleanExtra(EXTRA_REQUIRE_ONE, false);

        Button backBtn = findViewById(R.id.btn_back);
        backBtn.setOnClickListener(v -> finish());

        Button addBtn = findViewById(R.id.btn_add_server);
        addBtn.setOnClickListener(v -> startActivity(new Intent(this, ServerEditActivity.class)));

        Button viewListBtn = findViewById(R.id.btn_view_list);
        Button viewGridBtn = findViewById(R.id.btn_view_grid);

        gridMode = "grid".equals(AppPrefs.getServerViewMode(this));
        viewListBtn.setOnClickListener(
                v -> {
                    gridMode = false;
                    AppPrefs.setServerViewMode(this, "list");
                    applyLayoutManager();
                    adapter.setGridMode(false);
                });
        viewGridBtn.setOnClickListener(
                v -> {
                    gridMode = true;
                    AppPrefs.setServerViewMode(this, "grid");
                    applyLayoutManager();
                    adapter.setGridMode(true);
                });

        listView = findViewById(R.id.server_list);
        adapter =
                new ServerAdapter(
                        new ServerAdapter.Listener() {
                            @Override
                            public void onServerClicked(ServerConfig server) {
                                if (server == null || server.id == null || server.id.trim().isEmpty())
                                    return;
                                ServerStore.setActive(ServersActivity.this, server.id);
                                refresh();
                                Toast.makeText(
                                                ServersActivity.this,
                                                "Active: " + server.effectiveName(),
                                                Toast.LENGTH_SHORT)
                                        .show();
                            }

                            @Override
                            public void onServerLongClicked(ServerConfig server) {
                                if (server == null) return;
                                Intent i = new Intent(ServersActivity.this, ServerEditActivity.class);
                                i.putExtra(ServerEditActivity.EXTRA_SERVER_ID, server.id);
                                startActivity(i);
                            }
                        });
        listView.setAdapter(adapter);
        adapter.setGridMode(gridMode);
        applyLayoutManager();

        qrImage = findViewById(R.id.qr_image);
        qrUrlText = findViewById(R.id.qr_url);
        qrUrlText.setText(getString(R.string.qr_loading));
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
        refreshRemoteQr();
        if (requireOne && ServerStore.hasAny(this)) {
            goHome();
            return;
        }
        if (requireOne) {
            mainHandler.removeCallbacks(pollRunnable);
            mainHandler.postDelayed(pollRunnable, 1000);
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        mainHandler.removeCallbacks(pollRunnable);
    }

    private void refresh() {
        List<ServerConfig> servers = ServerStore.list(this);
        String activeId = ServerStore.getActiveId(this);
        adapter.setData(servers, activeId);
    }

    private void applyLayoutManager() {
        if (listView == null) return;
        if (gridMode) {
            listView.setLayoutManager(new GridLayoutManager(this, 2));
        } else {
            listView.setLayoutManager(new LinearLayoutManager(this));
        }
    }

    private void refreshRemoteQr() {
        RemoteInfo info = RemoteControl.ensureStarted(this);
        String url = info != null ? info.firstRemoteUrl() : "";
        if (qrUrlText != null) {
            qrUrlText.setText(url.isEmpty() ? "No LAN IP" : url);
        }
        if (qrImage != null) {
            Bitmap bmp = url.isEmpty() ? null : QrCodeUtil.render(url, dpToPx(280));
            qrImage.setImageBitmap(bmp);
        }
    }

    private int dpToPx(int dp) {
        float density = getResources().getDisplayMetrics().density;
        return Math.round(dp * density);
    }

    private void goHome() {
        Intent i = new Intent(this, MainActivity.class);
        i.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(i);
        finish();
    }
}
