package com.linplayer.tvlegacy;

import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.recyclerview.widget.RecyclerView;
import java.util.List;

final class ShowAdapter extends RecyclerView.Adapter<ShowAdapter.Vh> {
    interface Listener {
        void onShowClicked(Show show);
    }

    private final List<Show> shows;
    private final Listener listener;

    ShowAdapter(List<Show> shows, Listener listener) {
        this.shows = shows;
        this.listener = listener;
    }

    @NonNull
    @Override
    public Vh onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
        View v =
                LayoutInflater.from(parent.getContext())
                        .inflate(R.layout.item_show, parent, false);
        return new Vh(v);
    }

    @Override
    public void onBindViewHolder(@NonNull Vh holder, int position) {
        Show show = shows.get(position);
        holder.title.setText(show.title);
        ImageLoader.load(holder.poster, show.posterUrl, 640);
        holder.itemView.setOnClickListener(v -> listener.onShowClicked(show));
    }

    @Override
    public int getItemCount() {
        return shows != null ? shows.size() : 0;
    }

    static final class Vh extends RecyclerView.ViewHolder {
        final ImageView poster;
        final TextView title;

        Vh(@NonNull View itemView) {
            super(itemView);
            poster = itemView.findViewById(R.id.show_poster);
            title = itemView.findViewById(R.id.show_title);
        }
    }
}
