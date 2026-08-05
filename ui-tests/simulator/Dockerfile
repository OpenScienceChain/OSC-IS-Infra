FROM node:20-alpine

WORKDIR /app
COPY server.mjs ./server.mjs

USER node
EXPOSE 3100
CMD ["node", "server.mjs"]
