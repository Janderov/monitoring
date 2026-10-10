# The hub image. Built from the repository root:
#   docker build -f hub/deploy/Dockerfile -t monitor-hub .
FROM swift:6.0-noble AS build
RUN apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY app app
COPY hub hub
ARG HUB_VERSION=dev
RUN sed -i "s/static let current = \"dev\"/static let current = \"${HUB_VERSION}\"/" hub/Sources/HubCore/Version.swift
RUN cd hub && swift build -c release --product monitor-hub --static-swift-stdlib \
    && cp "$(swift build -c release --show-bin-path)/monitor-hub" /monitor-hub

FROM swift:6.0-noble-slim
RUN apt-get update -qq && apt-get install -y -qq libsqlite3-0 ca-certificates tzdata >/dev/null \
    && rm -rf /var/lib/apt/lists/* && useradd --system --uid 10001 --home /opt/monitor-hub hub
COPY --from=build /monitor-hub /usr/local/bin/monitor-hub
COPY db/migrations /opt/monitor-hub/migrations
ENV HUB_MIGRATIONS=/opt/monitor-hub/migrations TZ=Europe/Moscow
USER hub
ENTRYPOINT ["/usr/local/bin/monitor-hub"]
CMD ["run"]
