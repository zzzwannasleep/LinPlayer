# 弹幕代理镜像。从**仓库根目录**构建(需要根 Cargo.toml/Cargo.lock):
#   docker build -f crates/danmaku-proxy/Dockerfile -t linplayer-danmaku-proxy .
#
# ★ 故意写成"一把梭"而不是「先拷清单编依赖、再拷源码」那种分层加速写法。
#   分层写法要手工把每个 workspace 成员的 Cargo.toml 逐个 COPY 进来,加一个 crate
#   就得记得改这里 —— 忘了改的表现是**镜像还能构建成功**,只是用的是过期的依赖树。
#   这个服务一天构建不了几次,拿可靠性换那几分钟不划算。
#   真正的加速交给 buildx 的层缓存(见 .github/workflows/danmaku-proxy.yml)。
#
# ★ 用仓库里**真实的 Cargo.lock**(不删、不重新解析)—— 镜像里的依赖版本
#   和本地 `cargo test` 跑过的那套必须是同一套,否则"本地全绿线上炸"没法查。

FROM rust:1-slim-bookworm AS build
WORKDIR /src
# 上下文已由根目录的 .dockerignore 削到只剩清单 + 本 crate 源码。
COPY . .
RUN cargo build --release -p linplayer-danmaku-proxy

FROM debian:bookworm-slim
# ca-certificates:reqwest 走 rustls + webpki-roots,根证书本来就编进二进制了,
#   装它纯粹是为了让容器里手动 curl 上游排障时也能用。
# curl:HEALTHCHECK 要有个能跑的命令,顺带给排障用。
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -r -u 10001 -m app
COPY --from=build /src/target/release/linplayer-danmaku-proxy /usr/local/bin/
USER app
# 容器里必须绑 0.0.0.0(容器网络本身就是隔离层);对外暴露与否由宿主机的
# `-p 127.0.0.1:8787:8787` 决定 —— compose 里已经这么写了,别改成 `-p 8787:8787`。
ENV DATA_DIR=/data PORT=8787 BIND=0.0.0.0
VOLUME ["/data"]
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/healthz" || exit 1
ENTRYPOINT ["/usr/local/bin/linplayer-danmaku-proxy"]
