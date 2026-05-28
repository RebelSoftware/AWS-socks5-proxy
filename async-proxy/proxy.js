#!/usr/bin/env node

const http = require('http');
const net = require('net');
const url = require('url');
const axios = require('axios');
const { SocksClient } = require('socks');

// Configuration from environment variables
const ORCHESTRATOR_URL = process.env.ORCHESTRATOR_URL || 'http://localhost:5000';
const LISTEN_HOST = process.env.LISTEN_HOST || '0.0.0.0';
const LISTEN_PORT = parseInt(process.env.LISTEN_PORT) || 8080;
const CHECK_INTERVAL = parseInt(process.env.CHECK_INTERVAL) || 30;
const LOG_LEVEL = (process.env.LOG_LEVEL || 'info').toLowerCase();

// SOCKS5 authentication
const PROXY_USER = process.env.PROXY_USER || '';
const PROXY_PASSWORD = process.env.PROXY_PASSWORD || '';
const REQUIRE_AUTH = (process.env.REQUIRE_AUTH || 'false').toLowerCase() === 'true';

// Build SOCKS5 proxy options with optional auth
function getSocksProxyOptions(host, port) {
    const opts = {
        host: host,
        port: port,
        type: 5
    };
    if (REQUIRE_AUTH && PROXY_USER && PROXY_PASSWORD) {
        opts.userId = PROXY_USER;
        opts.password = PROXY_PASSWORD;
    }
    return opts;
}

// Simple logger
const logger = {
    error: (...args) => console.error(new Date().toISOString(), '- ERROR -', ...args),
    warn: (...args) => console.warn(new Date().toISOString(), '- WARN -', ...args),
    info: (...args) => console.log(new Date().toISOString(), '- INFO -', ...args),
    debug: (...args) => {
        if (LOG_LEVEL === 'debug') {
            console.log(new Date().toISOString(), '- DEBUG -', ...args);
        }
    }
};

class DynamicProxy {
    constructor(orchestratorUrl, options = {}) {
        this.orchestratorUrl = orchestratorUrl;
        this.checkInterval = options.checkInterval || 30;
        this.currentEndpoint = null;
        this.running = true;
        this.activeConnections = 0;
        this.totalRequests = 0;
    }

    async start() {
        logger.info(`Starting proxy, monitoring ${this.orchestratorUrl}`);
        logger.info(`Check interval: ${this.checkInterval}s`);
        
        // Get initial endpoint
        const success = await this.updateEndpoint();
        if (!success) {
            logger.warn('Failed to get initial endpoint, will retry');
        }
        
        // Start update loop
        this.startUpdateLoop();
    }

    async updateEndpoint() {
        try {
            logger.debug('Checking orchestrator for endpoint updates');
            
            const response = await axios.get(`${this.orchestratorUrl}/status`, {
                timeout: 5000,
                validateStatus: status => status === 200
            });
            
            if (response.data && response.data.remote_ip) {
                const newIp = response.data.remote_ip;
                const newPort = response.data.socks5_port || 1080;
                
                if (!this.currentEndpoint || 
                    newIp !== this.currentEndpoint.host || 
                    newPort !== this.currentEndpoint.port) {
                    
                    logger.info(`Upstream changed: ${JSON.stringify(this.currentEndpoint)} -> ${newIp}:${newPort}`);
                    this.currentEndpoint = { host: newIp, port: newPort };
                    return true;
                } else {
                    logger.debug('Endpoint unchanged');
                }
            } else {
                logger.warn('Orchestrator returned invalid data');
            }
        } catch (err) {
            if (err.code === 'ECONNREFUSED') {
                logger.error(`Cannot connect to orchestrator at ${this.orchestratorUrl}`);
            } else if (err.code === 'ETIMEDOUT') {
                logger.error('Orchestrator request timed out');
            } else {
                logger.error('Error updating endpoint:', err.message);
            }
        }
        return false;
    }

    startUpdateLoop() {
        this.updateInterval = setInterval(async () => {
            try {
                await this.updateEndpoint();
            } catch (err) {
                logger.error('Error in update loop:', err.message);
            }
        }, this.checkInterval * 1000);
    }

    async handleRequest(clientReq, clientRes) {
        this.totalRequests++;
        
        if (!this.currentEndpoint) {
            logger.error('No SOCKS5 endpoint available');
            clientRes.writeHead(503, { 'Content-Type': 'text/plain' });
            clientRes.end('Proxy not ready - no upstream endpoint');
            return;
        }

        logger.info(`${clientReq.method} ${clientReq.url}`);
        
        try {
            const targetUrl = new URL(clientReq.url);
            const targetHost = targetUrl.hostname;
            const targetPort = targetUrl.port || (targetUrl.protocol === 'https:' ? 443 : 80);

            logger.debug(`Connecting via SOCKS5 ${this.currentEndpoint.host}:${this.currentEndpoint.port} to ${targetHost}:${targetPort}`);

            // Create SOCKS5 connection (with optional auth)
            const { socket: proxySocket } = await SocksClient.createConnection({
                proxy: getSocksProxyOptions(this.currentEndpoint.host, this.currentEndpoint.port),
                command: 'connect',
                destination: {
                    host: targetHost,
                    port: targetPort
                },
                timeout: 30000
            });

            this.activeConnections++;

            // Build raw HTTP request and send through SOCKS5 tunnel
            const requestLine = `${clientReq.method} ${targetUrl.pathname}${targetUrl.search} HTTP/1.1\r\n`;
            let rawRequest = requestLine;
            for (const [key, value] of Object.entries(this.filterHeaders(clientReq.headers))) {
                rawRequest += `${key}: ${value}\r\n`;
            }
            rawRequest += 'Connection: close\r\n\r\n';
            proxySocket.write(rawRequest);

            // Pipe client body (if any) — use {end:false} so proxySocket stays open for response
            const hasBody = clientReq.method !== 'GET' && clientReq.method !== 'HEAD';
            if (hasBody) {
                clientReq.pipe(proxySocket, { end: false });
            }

            // Parse the HTTP response from the tunnel and forward to client
            let responseBuffer = Buffer.alloc(0);
            let headersParsed = false;

            proxySocket.on('data', (chunk) => {
                responseBuffer = Buffer.concat([responseBuffer, chunk]);

                if (!headersParsed) {
                    // Look for the end of headers
                    const headerEnd = responseBuffer.indexOf('\r\n\r\n');
                    if (headerEnd !== -1) {
                        headersParsed = true;

                        // Parse status line
                        const headerSection = responseBuffer.subarray(0, headerEnd).toString();
                        const statusLine = headerSection.split('\r\n')[0];
                        const statusCode = parseInt(statusLine.split(' ')[1], 10);
                        const statusMessage = statusLine.split(' ').slice(2).join(' ');

                        // Parse headers
                        const headerLines = headerSection.split('\r\n').slice(1);
                        const headers = {};
                        for (const line of headerLines) {
                            const sep = line.indexOf(':');
                            if (sep !== -1) {
                                const key = line.substring(0, sep).trim();
                                const val = line.substring(sep + 1).trim();
                                headers[key] = val;
                            }
                        }

                        // Send response head to client
                        clientRes.writeHead(statusCode, statusMessage, headers);

                        // Forward any remaining data as body
                        const bodyStart = headerEnd + 4;
                        if (bodyStart < responseBuffer.length) {
                            clientRes.write(responseBuffer.subarray(bodyStart));
                        }
                    }
                } else {
                    // Forward body chunks
                    clientRes.write(chunk);
                }
            });

            proxySocket.on('end', () => {
                clientRes.end();
                cleanup();
            });

            proxySocket.on('error', (err) => {
                logger.error('SOCKS5 tunnel error:', err.message);
                if (!clientRes.headersSent) {
                    clientRes.writeHead(502, { 'Content-Type': 'text/plain' });
                    clientRes.end(`Bad Gateway: ${err.message}`);
                }
                cleanup();
            });

            clientReq.on('error', () => cleanup());

            const cleanup = () => {
                this.activeConnections--;
                try { proxySocket.destroy(); } catch (e) {}
                try { clientReq.destroy(); } catch (e) {}
            };

            proxySocket.on('close', cleanup);
            clientReq.on('close', cleanup);
            proxySocket.on('close', cleanup);
            clientReq.on('close', cleanup);

        } catch (err) {
            logger.error('Request handling error:', err.message);
            if (!clientRes.headersSent) {
                clientRes.writeHead(502, { 'Content-Type': 'text/plain' });
            }
            clientRes.end(`Bad Gateway: ${err.message}`);
        }
    }

    async handleConnect(clientReq, clientSocket, head) {
        this.totalRequests++;
        
        if (!this.currentEndpoint) {
            logger.error('No SOCKS5 endpoint available for CONNECT');
            clientSocket.write('HTTP/1.1 503 Service Unavailable\r\n\r\n');
            clientSocket.end();
            return;
        }

        const [hostname, port] = clientReq.url.split(':');
        const targetPort = parseInt(port) || 443;
        
        logger.info(`CONNECT ${hostname}:${targetPort}`);

        try {
            logger.debug(`Creating SOCKS5 tunnel via ${this.currentEndpoint.host}:${this.currentEndpoint.port} to ${hostname}:${targetPort}`);

            const { socket: remoteSocket } = await SocksClient.createConnection({
                proxy: getSocksProxyOptions(this.currentEndpoint.host, this.currentEndpoint.port),
                command: 'connect',
                destination: {
                    host: hostname,
                    port: targetPort
                },
                timeout: 30000
            });

            this.activeConnections++;

            // Send successful connection response
            clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');

            logger.debug(`Tunnel established to ${hostname}:${targetPort}`);

            // Handle any initial data
            if (head.length > 0) {
                remoteSocket.write(head);
            }

            // Bidirectional pipe
            const cleanup = () => {
                this.activeConnections--;
                try {
                    clientSocket.destroy();
                    remoteSocket.destroy();
                } catch (e) {
                    // Ignore cleanup errors
                }
            };

            clientSocket.pipe(remoteSocket);
            remoteSocket.pipe(clientSocket);

            clientSocket.on('error', (err) => {
                logger.debug('Client socket error:', err.message);
                cleanup();
            });

            remoteSocket.on('error', (err) => {
                logger.debug('Remote socket error:', err.message);
                cleanup();
            });

            clientSocket.on('close', () => {
                logger.debug('Client socket closed');
                cleanup();
            });

            remoteSocket.on('close', () => {
                logger.debug('Remote socket closed');
                cleanup();
            });

        } catch (err) {
            logger.error('CONNECT tunnel error:', err.message);
            clientSocket.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
            clientSocket.end();
        }
    }

    filterHeaders(headers) {
        // Remove hop-by-hop headers
        const hopByHop = [
            'connection', 'keep-alive', 'proxy-authenticate',
            'proxy-authorization', 'te', 'trailers',
            'transfer-encoding', 'upgrade', 'proxy-connection'
        ];
        
        const filtered = {};
        for (const [key, value] of Object.entries(headers)) {
            if (!hopByHop.includes(key.toLowerCase())) {
                filtered[key] = value;
            }
        }
        return filtered;
    }

    shutdown() {
        logger.info('Shutting down proxy...');
        this.running = false;
        if (this.updateInterval) {
            clearInterval(this.updateInterval);
        }
    }
}

// Create proxy instance
const proxy = new DynamicProxy(ORCHESTRATOR_URL, {
    checkInterval: CHECK_INTERVAL
});

// Status endpoint
const statusServer = http.createServer((req, res) => {
    const sendJson = (data, status = 200) => {
        res.writeHead(status, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(data, null, 2));
    };

    if (req.url === '/health') {
        const status = {
            status: proxy.running ? 'running' : 'stopped',
            endpoint: proxy.currentEndpoint,
            activeConnections: proxy.activeConnections,
            totalRequests: proxy.totalRequests
        };
        sendJson(status);
    } else if (req.url === '/test-socks5') {
        // Test SOCKS5 connectivity
        (async () => {
            if (!proxy.currentEndpoint) {
                sendJson({ error: 'No SOCKS5 endpoint configured' }, 503);
                return;
            }
            
            try {
                const { socket } = await SocksClient.createConnection({
                    proxy: getSocksProxyOptions(proxy.currentEndpoint.host, proxy.currentEndpoint.port),
                    command: 'connect',
                    destination: {
                        host: 'httpbin.org',
                        port: 80
                    },
                    timeout: 10000
                });
                socket.destroy();
                sendJson({
                    success: true,
                    endpoint: proxy.currentEndpoint,
                    message: 'SOCKS5 connection established successfully'
                });
            } catch (err) {
                sendJson({
                    success: false,
                    endpoint: proxy.currentEndpoint,
                    error: err.message,
                    code: err.code || 'UNKNOWN'
                }, 502);
            }
        })();
    } else {
        res.writeHead(404);
        res.end('Not found');
    }
});

// Main proxy server
const proxyServer = http.createServer(proxy.handleRequest.bind(proxy));
proxyServer.on('connect', proxy.handleConnect.bind(proxy));

// Start servers
async function main() {
    await proxy.start();

    // Start management server on a different port
    const managementPort = LISTEN_PORT + 1;
    statusServer.listen(managementPort, LISTEN_HOST, () => {
        logger.info(`Management server listening on ${LISTEN_HOST}:${managementPort}`);
    });

    // Start proxy server
    proxyServer.listen(LISTEN_PORT, LISTEN_HOST, () => {
        logger.info(`Proxy listening on ${LISTEN_HOST}:${LISTEN_PORT}`);
    });
}

// Handle shutdown gracefully
process.on('SIGTERM', () => {
    logger.info('Received SIGTERM');
    proxy.shutdown();
    proxyServer.close();
    statusServer.close();
    process.exit(0);
});

process.on('SIGINT', () => {
    logger.info('Received SIGINT');
    proxy.shutdown();
    proxyServer.close();
    statusServer.close();
    process.exit(0);
});

process.on('uncaughtException', (err) => {
    logger.error('Uncaught exception:', err);
    proxy.shutdown();
    process.exit(1);
});

process.on('unhandledRejection', (reason) => {
    logger.error('Unhandled rejection:', reason);
});

// Start everything
main().catch((err) => {
    logger.error('Failed to start:', err);
    process.exit(1);
});