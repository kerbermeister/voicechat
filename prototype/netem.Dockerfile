FROM node:22-alpine
RUN apk add --no-cache iproute2
ENTRYPOINT ["tc"]
