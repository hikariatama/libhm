# Native Swift tests require macOS/Xcode; run the existing portable release suite here.
FROM python:3.15-alpine@sha256:0f9552bb28711333da16915ec146f5e6bb44a7fdac9ced15dc17c2e0206346dd AS test
WORKDIR /tests
COPY scripts/publish-draft.py scripts/test_publish_draft.py scripts/release-notes.md ./scripts/
COPY ci/run-tests.py ./ci/run-tests.py
RUN --network=none python ci/run-tests.py

FROM scratch AS test-report
COPY --from=test /report /

FROM nginx:1.31.9-alpine@sha256:fb4658584bd9a916ffb6f6e365f97c25cfdb2923801f551ea08356e695f14ff7
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY landing/ /usr/share/nginx/html/
EXPOSE 80
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 CMD wget -q --spider http://127.0.0.1/ || exit 1
