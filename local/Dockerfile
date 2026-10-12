FROM node:20-alpine
WORKDIR /app
COPY local/package.json local/package-lock.json ./local/
RUN cd local && npm ci --omit=dev --no-audit --no-fund
COPY . .
ENV PORT=8443
EXPOSE 8443
CMD ["node", "local/servidor.mjs"]
