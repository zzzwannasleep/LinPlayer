// 网络重活(Rust 主场):本地预取代理 + 预加载 + CF 优选反代。SOCKS5 后续补。
//
// prefetch 与 preload 是**两件事**,名字像而已:
//   prefetch(多线程加载)= 播放中起本地代理超前拉流喂 mpv,数据落环形缓存,改播放地址;
//   preload (预加载)    = 播放前在详情页把头/尾两段跑热,数据读完即丢,不改任何地址。
pub mod cf;
pub mod prefetch;
pub mod preload;
