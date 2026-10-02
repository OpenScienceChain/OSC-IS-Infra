FROM busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0
COPY --chown=65534:65534 site /srv
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["busybox", "httpd", "-f", "-p", "8080", "-h", "/srv"]
