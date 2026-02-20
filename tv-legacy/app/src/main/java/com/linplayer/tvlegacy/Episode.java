package com.linplayer.tvlegacy;

public final class Episode {
    public final String id;
    public final int index;
    public final String title;
    public final String mediaUrl;
    public final int seasonNumber;
    public final int episodeNumber;
    public final String overview;
    public final String thumbUrl;

    public Episode(String id, int index, String title, String mediaUrl) {
        this(id, index, title, mediaUrl, 0, 0, "", "");
    }

    public Episode(
            String id,
            int index,
            String title,
            String mediaUrl,
            int seasonNumber,
            int episodeNumber,
            String overview,
            String thumbUrl) {
        this.id = id != null ? id : "";
        this.index = index;
        this.title = title != null ? title : "";
        this.mediaUrl = mediaUrl != null ? mediaUrl : "";
        this.seasonNumber = seasonNumber;
        this.episodeNumber = episodeNumber;
        this.overview = overview != null ? overview : "";
        this.thumbUrl = thumbUrl != null ? thumbUrl : "";
    }
}
