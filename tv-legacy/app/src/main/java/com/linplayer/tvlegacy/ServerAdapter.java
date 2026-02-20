package com.linplayer.tvlegacy;

import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.recyclerview.widget.RecyclerView;
import com.linplayer.tvlegacy.servers.ServerConfig;
import java.util.ArrayList;
import java.util.List;

final class ServerAdapter extends RecyclerView.Adapter<ServerAdapter.Vh> {
    interface Listener {
        void onServerClicked(ServerConfig server);

        void onServerLongClicked(ServerConfig server);
    }

    private static final int VIEW_BAR = 0;
    private static final int VIEW_BOX = 1;

    private final List<ServerConfig> servers = new ArrayList<>();
    private final Listener listener;
    private boolean gridMode;
    private String activeId = "";

    ServerAdapter(Listener listener) {
        this.listener = listener;
    }

    void setGridMode(boolean gridMode) {
        if (this.gridMode == gridMode) return;
        this.gridMode = gridMode;
        notifyDataSetChanged();
    }

    void setData(List<ServerConfig> list, String activeId) {
        this.activeId = activeId != null ? activeId : "";
        servers.clear();
        if (list != null) servers.addAll(list);
        notifyDataSetChanged();
    }

    @Override
    public int getItemViewType(int position) {
        return gridMode ? VIEW_BOX : VIEW_BAR;
    }

    @NonNull
    @Override
    public Vh onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
        int layout = viewType == VIEW_BOX ? R.layout.item_server_box : R.layout.item_server_bar;
        View v = LayoutInflater.from(parent.getContext()).inflate(layout, parent, false);
        return new Vh(v);
    }

    @Override
    public void onBindViewHolder(@NonNull Vh holder, int position) {
        ServerConfig c = servers.get(position);
        boolean active = c != null && c.id != null && c.id.equals(activeId);
        String name = c != null ? c.effectiveName() : "Server";
        holder.name.setText((active ? "✓ " : "") + name);

        String type = c != null ? typeLabel(c.type) : "";
        String baseUrl = c != null ? safe(c.baseUrl) : "";
        String meta = gridMode ? type : (type + (baseUrl.isEmpty() ? "" : " · " + baseUrl));
        holder.meta.setText(meta);

        String remark = c != null ? safe(c.remark) : "";
        if (remark.isEmpty()) {
            holder.remark.setVisibility(View.GONE);
        } else {
            holder.remark.setVisibility(View.VISIBLE);
            holder.remark.setText(remark);
        }

        holder.itemView.setOnClickListener(v -> listener.onServerClicked(c));
        holder.itemView.setOnLongClickListener(
                v -> {
                    listener.onServerLongClicked(c);
                    return true;
                });
    }

    @Override
    public int getItemCount() {
        return servers.size();
    }

    static final class Vh extends RecyclerView.ViewHolder {
        final TextView name;
        final TextView meta;
        final TextView remark;

        Vh(@NonNull View itemView) {
            super(itemView);
            name = itemView.findViewById(R.id.server_name);
            meta = itemView.findViewById(R.id.server_meta);
            remark = itemView.findViewById(R.id.server_remark);
        }
    }

    private static String typeLabel(String type) {
        String t = safe(type).toLowerCase();
        if ("emby".equals(t)) return "Emby";
        if ("jellyfin".equals(t)) return "Jellyfin";
        if ("plex".equals(t)) return "Plex";
        if ("webdav".equals(t)) return "WebDAV";
        return t.isEmpty() ? "Server" : t;
    }

    private static String safe(String s) {
        return s != null ? s.trim() : "";
    }
}

