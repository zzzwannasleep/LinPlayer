package com.linplayer.tvlegacy;

import android.content.Context;
import com.google.android.exoplayer2.ext.okhttp.OkHttpDataSource;
import com.google.android.exoplayer2.upstream.DataSource;
import com.google.android.exoplayer2.upstream.DefaultDataSource;
import okhttp3.OkHttpClient;

final class ExoNetwork {
    private ExoNetwork() {}

    static DataSource.Factory dataSourceFactory(Context context) {
        OkHttpClient client = NetworkClients.okHttp(context);
        return dataSourceFactory(context, client);
    }

    static DataSource.Factory dataSourceFactory(Context context, OkHttpClient client) {
        OkHttpClient c = client != null ? client : NetworkClients.okHttp(context);
        OkHttpDataSource.Factory okHttpFactory = new OkHttpDataSource.Factory(c);
        return new DefaultDataSource.Factory(context, okHttpFactory);
    }
}
