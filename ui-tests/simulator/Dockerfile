FROM node:20-alpine@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293

WORKDIR /app
COPY server.mjs ./server.mjs

USER node
EXPOSE 3100
CMD ["node", "server.mjs"]
