## Dockerfile for a haskell environment
## TAG franzd-0.2.1
## https://github.com/phadej/docker-ghc/blob/master/8.8.1/xenial/slim/Dockerfile
FROM ubuntu:xenial as build

## ensure locale is set during build
ENV LANG C.UTF-8

RUN apt-get update && \
    apt-get install -y --no-install-recommends gnupg ca-certificates dirmngr curl git software-properties-common && \
    apt-add-repository -y "ppa:hvr/ghc" && \
    apt-get update && \
    apt-get install -y --no-install-recommends ghc-8.8.1 cabal-install-3.0 \
        zlib1g-dev libtinfo-dev libsqlite3-dev g++ netbase xz-utils make && \
    curl -fSL https://github.com/commercialhaskell/stack/releases/download/v2.1.3/stack-2.1.3-linux-x86_64.tar.gz -o stack.tar.gz && \
    echo "c724b207831fe5f06b087bac7e01d33e61a1c9cad6be0468f9c117d383ec5673  stack.tar.gz" | sha256sum -c - && \
    tar -xf stack.tar.gz -C /usr/local/bin --strip-components=1 && \
    /usr/local/bin/stack config set system-ghc --global true && \
    /usr/local/bin/stack config set install-ghc --global false && \
    rm -rf "$GNUPGHOME" /var/lib/apt/lists/* /stack.tar.gz

WORKDIR /tmp
RUN apt-get update && apt-get download libgmp10
RUN mv libgmp*.deb libgmp.deb

ENV PATH /root/.cabal/bin:/root/.local/bin:/opt/cabal/3.0/bin:/opt/ghc/8.8.1/bin:$PATH

COPY franz.cabal cabal.project ChangeLog.md README.md LICENSE /tmp/
COPY app /tmp/app
COPY src /tmp/src

RUN mkdir /release
RUN cabal v2-update
RUN cabal v2-install --installdir="/release" --install-method=copy

## Minimal image
FROM ubuntu:xenial
COPY --from=build /tmp/libgmp.deb /tmp
RUN dpkg -i /tmp/libgmp.deb && rm /tmp/libgmp.deb
COPY --from=build /release/ .
ENTRYPOINT ["./franzd"]
EXPOSE 1886
CMD ["/live", "/archive"]
