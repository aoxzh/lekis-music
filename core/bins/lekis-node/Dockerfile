# Lekis NAS 节点镜像（NOD-01）。目标：多架构（amd64 / arm64），镜像 ≤ 30MB。
# 构建：在 core/ 目录下执行  docker build -f bins/lekis-node/Dockerfile -t lekis-node .

FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY . .
RUN cargo build --release -p lekis-node

FROM alpine:3
RUN adduser -D -H -u 1000 lekis && mkdir -p /data /cache && chown lekis /data /cache
COPY --from=build /src/target/release/lekis-node /usr/local/bin/lekis-node
USER lekis
ENV LEKIS_DATA_DIR=/data LEKIS_CACHE_DIR=/cache LEKIS_BIND=0.0.0.0:4533
EXPOSE 4533
VOLUME ["/data", "/cache"]
# 音乐目录以只读方式挂载，例如：-v /volume1/music:/music:ro
ENTRYPOINT ["/usr/local/bin/lekis-node"]
