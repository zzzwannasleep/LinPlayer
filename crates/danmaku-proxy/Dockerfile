# 两段式构建:服务器上不用装 Rust 工具链,`docker build` 一条命令搞定。
# 从**仓库根目录**构建(需要 workspace 的 Cargo.toml):
#   docker build -f crates/danmaku-proxy/Dockerfile -t linplayer-danmaku-proxy .

FROM rust:1-slim-bookworm AS build
WORKDIR /src
# 只拷这个 crate 需要的东西。整个仓库拷进来会把安卓/桌面那些巨大的目录也拉进构建上下文。
COPY Cargo.toml Cargo.lock ./
COPY crates/danmaku-proxy ./crates/danmaku-proxy
# workspace 的 members 里还列着别的 crate,建一批空壳让 cargo 能解析 workspace,
# 但只真正编译我们要的这一个(-p)。比改 workspace 结构干净。
RUN set -eux; \
    for m in crates/core crates/mpv apps/desktop apps/android; do \
      mkdir -p "$m/src"; \
      printf '[package]\nname="stub-%s"\nversion="0.0.0"\nedition="2021"\n[lib]\npath="src/lib.rs"\n' \
        "$(echo "$m" | tr '/' '-')" > "$m/Cargo.toml"; \
      : > "$m/src/lib.rs"; \
    done; \
    rm -f Cargo.lock
RUN cargo build --release -p linplayer-danmaku-proxy

# rustls + webpki-roots:根证书编进二进制,运行镜像连 ca-certificates 都不需要。
FROM debian:bookworm-slim
RUN useradd -r -u 10001 -m app
COPY --from=build /src/target/release/linplayer-danmaku-proxy /usr/local/bin/
USER app
ENV DATA_DIR=/data PORT=8787 BIND=0.0.0.0
VOLUME ["/data"]
EXPOSE 8787
# 容器里必须绑 0.0.0.0(容器网络就是隔离层),对外仍然只由宿主机的 -p 127.0.0.1:… 决定。
ENTRYPOINT ["/usr/local/bin/linplayer-danmaku-proxy"]
