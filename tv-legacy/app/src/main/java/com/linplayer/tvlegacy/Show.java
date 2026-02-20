package com.linplayer.tvlegacy;

public final class Show {
    public final String id;
    public final String title;
    public final String overview;
    public final String posterUrl;
    public final String backdropUrl;
    public final String year;
    public final String genres;
    public final String rating;

    public Show(String id, String title, String overview) {
        this(id, title, overview, "", "", "", "", "");
    }

    public Show(
            String id,
            String title,
            String overview,
            String posterUrl,
            String backdropUrl,
            String year,
            String genres,
            String rating) {
        this.id = id != null ? id : "";
        this.title = title != null ? title : "";
        this.overview = overview != null ? overview : "";
        this.posterUrl = posterUrl != null ? posterUrl : "";
        this.backdropUrl = backdropUrl != null ? backdropUrl : "";
        this.year = year != null ? year : "";
        this.genres = genres != null ? genres : "";
        this.rating = rating != null ? rating : "";
    }
}
