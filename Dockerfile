FROM alpine:3.22
RUN apk add --no-cache iptables ip6tables iproute2
COPY sslh-tproxy.sh /usr/local/bin/sslh-tproxy
RUN chmod +x /usr/local/bin/sslh-tproxy
ENTRYPOINT ["/usr/local/bin/sslh-tproxy"]
CMD ["run"]
