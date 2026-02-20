package com.linplayer.tvlegacy;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Bundle;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.content.ContextCompat;

public final class SettingsActivity extends AppCompatActivity {
    private final BroadcastReceiver statusReceiver =
            new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    if (!ProxyService.ACTION_STATUS.equals(intent.getAction())) return;
                    String status = intent.getStringExtra(ProxyService.EXTRA_STATUS);
                    if (status == null) status = "unknown";
                    TextView statusText = findViewById(R.id.status_text);
                    statusText.setText(status);
                }
            };

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_settings);

        TextView uaText = findViewById(R.id.ua_text);
        uaText.setText(NetworkConfig.userAgent());

        Button openServersBtn = findViewById(R.id.btn_open_servers);
        openServersBtn.setOnClickListener(v -> startActivity(new Intent(this, ServersActivity.class)));

        EditText subscriptionInput = findViewById(R.id.subscription_input);
        subscriptionInput.setText(AppPrefs.getSubscriptionUrl(this));

        Button saveSubBtn = findViewById(R.id.btn_save_sub);
        saveSubBtn.setOnClickListener(
                v -> {
                    String url =
                            subscriptionInput.getText() != null
                                    ? subscriptionInput.getText().toString()
                                    : "";
                    AppPrefs.setSubscriptionUrl(this, url);
                    ProxyService.applyConfig(this);
                });

        Button startBtn = findViewById(R.id.btn_start);
        Button stopBtn = findViewById(R.id.btn_stop);

        startBtn.setOnClickListener(
                v -> {
                    AppPrefs.setProxyEnabled(this, true);
                    ProxyService.start(this);
                });
        stopBtn.setOnClickListener(
                v -> {
                    AppPrefs.setProxyEnabled(this, false);
                    ProxyService.stop(this);
                });

        TextView statusText = findViewById(R.id.status_text);
        statusText.setText(AppPrefs.getLastStatus(this));
    }

    @Override
    protected void onStart() {
        super.onStart();
        IntentFilter filter = new IntentFilter(ProxyService.ACTION_STATUS);
        ContextCompat.registerReceiver(
                this, statusReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED);
    }

    @Override
    protected void onStop() {
        super.onStop();
        unregisterReceiver(statusReceiver);
    }
}
