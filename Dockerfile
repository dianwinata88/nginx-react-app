# Build stage
FROM node:20-alpine AS build
WORKDIR /app
COPY app/package.json app/package-lock.json ./
RUN npm ci
COPY app/ ./
RUN npm run build

# Serve stage — nginx 1.30.x
FROM nginx:1.30.5-alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx/templates/default.conf.template /etc/nginx/templates/default.conf.template
COPY docker/write-config.sh /docker-entrypoint.d/40-write-config.sh
RUN chmod +x /docker-entrypoint.d/40-write-config.sh

ENV NODE_ID=unknown
EXPOSE 80
