package com.linplayer.tvlegacy;

import android.os.Bundle;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import com.linplayer.tvlegacy.servers.ServerConfig;
import com.linplayer.tvlegacy.servers.ServerStore;
import org.json.JSONException;

public final class ServerEditActivity extends AppCompatActivity {
    static final String EXTRA_SERVER_ID = "server_id";

    private String serverId;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_server_edit);

        serverId = getIntent().getStringExtra(EXTRA_SERVER_ID);
        if (serverId == null) serverId = "";

        ServerConfig existing = ServerStore.find(this, serverId);

        Button backBtn = findViewById(R.id.btn_back);
        backBtn.setOnClickListener(v -> finish());

        TextView title = findViewById(R.id.edit_title);
        title.setText(existing != null ? getString(R.string.edit_server) : getString(R.string.add_server));

        Spinner typeSpinner = findViewById(R.id.type_spinner);
        EditText baseUrlInput = findViewById(R.id.base_url_input);
        EditText apiKeyInput = findViewById(R.id.api_key_input);
        EditText usernameInput = findViewById(R.id.username_input);
        EditText passwordInput = findViewById(R.id.password_input);
        EditText displayNameInput = findViewById(R.id.display_name_input);
        EditText remarkInput = findViewById(R.id.remark_input);
        CheckBox activateCheckbox = findViewById(R.id.activate_checkbox);

        if (existing != null) {
            typeSpinner.setSelection(typeIndex(existing.type));
            baseUrlInput.setText(existing.baseUrl);
            apiKeyInput.setText(existing.apiKey);
            usernameInput.setText(existing.username);
            passwordInput.setText(existing.password);
            displayNameInput.setText(existing.displayName);
            remarkInput.setText(existing.remark);
            activateCheckbox.setChecked(true);
        } else {
            activateCheckbox.setChecked(true);
        }

        Button saveBtn = findViewById(R.id.btn_save);
        saveBtn.setOnClickListener(
                v -> {
                    String type = typeValue(typeSpinner.getSelectedItemPosition());
                    String baseUrl =
                            baseUrlInput.getText() != null ? baseUrlInput.getText().toString() : "";
                    String apiKey =
                            apiKeyInput.getText() != null ? apiKeyInput.getText().toString() : "";
                    String username =
                            usernameInput.getText() != null ? usernameInput.getText().toString() : "";
                    String password =
                            passwordInput.getText() != null ? passwordInput.getText().toString() : "";
                    String displayName =
                            displayNameInput.getText() != null
                                    ? displayNameInput.getText().toString()
                                    : "";
                    String remark =
                            remarkInput.getText() != null ? remarkInput.getText().toString() : "";

                    baseUrl = normalizeBaseUrl(baseUrl);
                    if (baseUrl.trim().isEmpty()) {
                        Toast.makeText(this, "Missing base url", Toast.LENGTH_LONG).show();
                        return;
                    }

                    if ("webdav".equals(type)) {
                        if (username.trim().isEmpty()) {
                            Toast.makeText(this, "Missing username", Toast.LENGTH_LONG).show();
                            return;
                        }
                    } else if ("plex".equals(type)) {
                        if (apiKey.trim().isEmpty()) {
                            Toast.makeText(this, "Missing token", Toast.LENGTH_LONG).show();
                            return;
                        }
                    } else {
                        if (apiKey.trim().isEmpty()) {
                            Toast.makeText(this, "Missing api key/token", Toast.LENGTH_LONG).show();
                            return;
                        }
                    }

                    boolean activate = activateCheckbox.isChecked();
                    try {
                        ServerStore.upsert(
                                this,
                                new ServerConfig(
                                        serverId,
                                        type,
                                        baseUrl,
                                        apiKey,
                                        username,
                                        password,
                                        displayName,
                                        remark),
                                activate);
                        Toast.makeText(this, "Saved", Toast.LENGTH_SHORT).show();
                        finish();
                    } catch (JSONException e) {
                        Toast.makeText(this, "Save failed: " + e.getMessage(), Toast.LENGTH_LONG)
                                .show();
                    }
                });

        Button deleteBtn = findViewById(R.id.btn_delete);
        if (existing == null) {
            deleteBtn.setEnabled(false);
            deleteBtn.setAlpha(0.4f);
        }
        deleteBtn.setOnClickListener(
                v -> {
                    if (serverId.trim().isEmpty()) return;
                    try {
                        ServerStore.delete(this, serverId);
                        Toast.makeText(this, "Deleted", Toast.LENGTH_SHORT).show();
                        finish();
                    } catch (JSONException e) {
                        Toast.makeText(this, "Delete failed: " + e.getMessage(), Toast.LENGTH_LONG)
                                .show();
                    }
                });
    }

    private static int typeIndex(String type) {
        String t = type != null ? type.trim().toLowerCase() : "";
        if ("emby".equals(t)) return 0;
        if ("jellyfin".equals(t)) return 1;
        if ("plex".equals(t)) return 2;
        if ("webdav".equals(t)) return 3;
        return 0;
    }

    private static String typeValue(int pos) {
        if (pos == 1) return "jellyfin";
        if (pos == 2) return "plex";
        if (pos == 3) return "webdav";
        return "emby";
    }

    private static String normalizeBaseUrl(String baseUrl) {
        String v = baseUrl != null ? baseUrl.trim() : "";
        if (v.isEmpty()) return "";
        if (!v.contains("://")) v = "http://" + v;
        while (v.endsWith("/")) v = v.substring(0, v.length() - 1);
        return v;
    }
}

