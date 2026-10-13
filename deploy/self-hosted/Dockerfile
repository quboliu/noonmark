FROM scratch
COPY --from=noonmark-runtime / /
COPY --from=noonmark-bin --chmod=0555 /noonmark /usr/local/bin/noonmark
COPY --from=noonmark-web --chmod=0555 / /opt/noonmark/web/
USER 65532:65532
WORKDIR /data
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["/usr/local/bin/noonmark", "healthcheck", "--url", "http://127.0.0.1:8080"]
ENTRYPOINT ["/usr/local/bin/noonmark"]
CMD ["serve", "--data-dir", "/data", "--web-dir", "/opt/noonmark/web", "--listen", "0.0.0.0:8080"]
