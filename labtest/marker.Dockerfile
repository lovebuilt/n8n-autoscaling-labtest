# labtest marker: a tiny image that carries labtest/MARKER, so the running container shows which
# commit's files were built. Read it with: docker exec <marker container> cat /labtest/MARKER
FROM busybox:1.37
COPY labtest/MARKER /labtest/MARKER
CMD ["sh", "-c", "cat /labtest/MARKER; trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done"]
