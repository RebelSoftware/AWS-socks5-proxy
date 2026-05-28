FROM node:18-alpine

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm install

# Copy application
COPY proxy.js .

# Create non-root user
RUN addgroup -g 1001 -S proxy && \
    adduser -S proxy -u 1001 -G proxy && \
    chown -R proxy:proxy /app

USER proxy

# Expose proxy port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080 || exit 1

# Run the proxy
CMD ["node", "proxy.js"]