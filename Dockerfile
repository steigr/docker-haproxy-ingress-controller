FROM docker.io/library/alpine:3.7 AS zlib-builder
RUN apk add --no-cache curl libc-dev gcc make perl linux-headers readline-dev upx
RUN mkdir /usr/src

RUN curl -sL https://zlib.net/zlib-1.2.11.tar.gz | tar zxC /usr/src
RUN cd /usr/src/zlib-1.2.11/ \
 && ./configure --static --prefix=/usr \
 && make install

FROM docker.io/library/alpine:3.7 AS pcre2-builder
RUN apk add --no-cache curl libc-dev gcc make perl linux-headers readline-dev upx
RUN mkdir /usr/src

RUN curl -sL https://github.com/luvit/pcre2/archive/master.tar.gz | tar zxC /usr/src
RUN cd /usr/src/pcre2-master/ \
 && ./configure --enable-static --prefix=/usr --enable-jit --enable-pcre2-16 --enable-pcre2-32 \
 && make install \
 && strip /usr/lib/libpcre2-8.so.0

FROM docker.io/library/alpine:3.7 AS openssl-builder
RUN apk add --no-cache curl libc-dev gcc make perl linux-headers readline-dev upx
RUN mkdir /usr/src

COPY --from=zlib-builder /usr /usr
RUN curl -sL https://github.com/openssl/openssl/archive/master.tar.gz | tar zxC /usr/src
RUN cd /usr/src/openssl-master/ \
 && grep TLS1_3_VERSION_DRAFT include/openssl/tls1.h  | grep draft | awk -F"draft " '{print $2}' | awk -F')' '{print $1}' | sort -n | tail -1 | xargs printf 'TLS v1.3 Draft %s\n' \
 && ./Configure no-tls13downgrade no-weak-ssl-ciphers  no-shared no-threads linux-x86_64 --prefix=/usr && perl configdata.pm --dump \
 && make install_sw

FROM docker.io/library/alpine:3.7 AS lua-builder
RUN apk add --no-cache curl libc-dev gcc make perl linux-headers readline-dev upx
RUN mkdir /usr/src

COPY --from=zlib-builder /usr /usr
RUN curl -sL http://www.lua.org/ftp/lua-5.3.4.tar.gz | tar zxC /usr/src
RUN cd /usr/src/lua-5.3.4/ \
 && make linux install INSTALL_TOP=/usr

FROM docker.io/library/alpine:3.7 AS haproxy-builder
RUN apk add --no-cache curl libc-dev gcc make perl linux-headers readline-dev upx
RUN mkdir /usr/src

COPY --from=zlib-builder /usr /usr
COPY --from=lua-builder /usr /usr
COPY --from=pcre2-builder /usr /usr
COPY --from=openssl-builder /usr /usr

RUN curl -sL http://www.haproxy.org/download/1.8/src/haproxy-1.8.8.tar.gz | tar zxC /usr/src
RUN cd /usr/src/haproxy-1.8.8/ \
 && make TARGET=linux2628 \
         USE_OPENSSL=1 SSL_INC=/usr/include SSL_LIB=/usr/lib \
         USE_PCRE2_JIT=1 PCRE2_INC=/usr/include PCRE2_LIB=/usr/lib \
         USE_ZLIB=1 ZLIB_LIB=/usr/lib ZLIB_INC=/usr/include \
         USE_LUA=1 LUA_LIB=/usr/lib LUA_INC=/usr/include \
 && strip haproxy \
 && ls -lash haproxy \
 && ldd haproxy \
 && ./haproxy -vv \
 && cp haproxy /haproxy

FROM docker.io/library/golang:1.10.2 AS haproxy-ingress-controller-builder

RUN  go get -d github.com/jcmoraisjr/haproxy-ingress/pkg \
 &&  cd /go/src/github.com/jcmoraisjr/haproxy-ingress \
 &&  make build

FROM docker.io/library/alpine:3.7 AS haproxy-ingress-controller-compressor
RUN apk add --no-cache curl libc-dev gcc make perl linux-headers readline-dev upx
COPY --from=haproxy-ingress-controller-builder /go/src/github.com/jcmoraisjr/haproxy-ingress/rootfs/ /go/src/github.com/jcmoraisjr/haproxy-ingress/rootfs/
WORKDIR /go/src/github.com/jcmoraisjr/haproxy-ingress/rootfs/
ARG  UPX_ARGS=-6
ENV  UPX_ARGS=${UPX_ARGS}
RUN  upx ${UPX_ARGS} haproxy-ingress-controller
RUN  sed -e 's|bind\ \*:443\(.*\)$|bind\ \*:443\1 allow-0rtt|' -i /go/src/github.com/jcmoraisjr/haproxy-ingress/rootfs/etc/haproxy/template/haproxy.tmpl
RUN  mkdir bin \
 &&  mv start.sh bin/controller

FROM docker.io/library/alpine:3.7 AS haproxy-ingress-controller
RUN apk --no-cache add socat openssl tini
COPY --from=haproxy-builder /haproxy /usr/bin/haproxy
COPY --from=haproxy-builder /usr/lib/libpcre2-8.so.0 /usr/lib/libpcre2-8.so.0
COPY --from=haproxy-ingress-controller-compressor /go/src/github.com/jcmoraisjr/haproxy-ingress/rootfs/ /

ENTRYPOINT ["tini", "--","controller"]
