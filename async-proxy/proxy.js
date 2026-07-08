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
const HEALTH_PORT = parseInt(process.env.HEALTH_PORT) || (LISTEN_PORT + 1);
const CHECK_INTERVAL = parseInt(process.env.CHECK_INTERVAL) || 30;
const LOG_LEVEL = (process.env.LOG_LEVEL || 'info').toLowerCase();

// Wake-up and idle timeout configuration
const WAKING_TIMEOUT_MS = parseInt(process.env.WAKING_TIMEOUT_MS) || 120000;  // 2 min before falling back to idle

// SOCKS5 authentication (upstream to Fargate)
const PROXY_USER = process.env.PROXY_USER || '';
const PROXY_PASSWORD = process.env.PROXY_PASSWORD || '';
const REQUIRE_AUTH = (process.env.REQUIRE_AUTH || 'false').toLowerCase() === 'true';

// Local HTTP proxy authentication (incoming from browser)
const LOCAL_PROXY_USER = process.env.LOCAL_PROXY_USER || '';
const LOCAL_PROXY_PASSWORD = process.env.LOCAL_PROXY_PASSWORD || '';
const LOCAL_REQUIRE_AUTH = (process.env.LOCAL_REQUIRE_AUTH || 'false').toLowerCase() === 'true';

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
        
        // Wake-up state machine: 'idle' | 'waking' | 'active'
        this.wakeState = 'active';
        this.lastActivityAt = Date.now();
        this.wakingTimeout = null;
        this._wakeInFlight = false;
    }

    async start() {
        logger.info(`Starting proxy, monitoring ${this.orchestratorUrl}`);
        logger.info(`Check interval: ${this.checkInterval}s`);
        
        // Get initial endpoint
        const success = await this.updateEndpoint();
        if (!success) {
            logger.warn('Failed to get initial endpoint, will retry');
            // Start idle if no endpoint — orchestrator may be waiting for wake
            this.wakeState = 'idle';
        } else {
            this.wakeState = 'active';
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
                    
                    // Transition to active — endpoint is now available
                    if (this.wakeState !== 'active') {
                        logger.info('Remote proxy endpoint acquired, entering active state');
                        this.wakeState = 'active';
                        if (this.wakingTimeout) {
                            clearTimeout(this.wakingTimeout);
                            this.wakingTimeout = null;
                        }
                        this._wakeInFlight = false;
                    }
                    return true;
                } else {
                    logger.debug('Endpoint unchanged');
                }
            } else {
                // No remote_ip — check if we need to transition to idle
                // Only go idle if we were previously active (orchestrator shut us down)
                if (this.currentEndpoint && this.wakeState === 'active') {
                    logger.warn('Orchestrator returned no endpoint — proxy may have been idled');
                    this.currentEndpoint = null;
                    this.wakeState = 'idle';
                }
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
        
        // Local proxy authentication check
        if (!this._checkLocalAuth(clientReq)) {
            this._send407(clientRes);
            return;
        }
        
        this._trackActivity();
        
        // Wake state machine — handle idle/waking before routing
        if (!this.currentEndpoint || this.wakeState !== 'active') {
            if (this.wakeState === 'idle') {
                logger.info('Request received while idle, triggering wake...');
                this.triggerWake();
                clientRes.writeHead(503, { 'Content-Type': 'text/plain', 'Retry-After': '5' });
                clientRes.end('Proxy is waking up — retry in a few seconds');
            } else if (this.wakeState === 'waking') {
                clientRes.writeHead(503, { 'Content-Type': 'text/plain', 'Retry-After': '10' });
                clientRes.end('Proxy is still starting — retry shortly');
            } else {
                clientRes.writeHead(503, { 'Content-Type': 'text/plain' });
                clientRes.end('Proxy not ready - no upstream endpoint');
            }
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
        
        // Local proxy authentication check
        if (!this._checkLocalAuth(clientReq)) {
            clientSocket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="SOCKS5 Proxy"\r\n\r\n');
            clientSocket.end();
            return;
        }
        
        this._trackActivity();
        
        // Wake state machine — handle idle/waking before routing
        if (!this.currentEndpoint || this.wakeState !== 'active') {
            if (this.wakeState === 'idle') {
                logger.info('CONNECT request received while idle, triggering wake...');
                this.triggerWake();
                clientSocket.write('HTTP/1.1 503 Service Unavailable\r\nRetry-After: 5\r\n\r\n');
                clientSocket.end();
            } else if (this.wakeState === 'waking') {
                clientSocket.write('HTTP/1.1 503 Service Unavailable\r\nRetry-After: 10\r\n\r\n');
                clientSocket.end();
            } else {
                clientSocket.write('HTTP/1.1 503 Service Unavailable\r\n\r\n');
                clientSocket.end();
            }
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

    async triggerWake() {
        /* Send wake signal to orchestrator. Only fires once per idle cycle. */
        if (this.wakeState !== 'idle' || this._wakeInFlight) return;
        
        this._wakeInFlight = true;
        logger.info('Triggering wake-up of remote proxy...');
        
        try {
            const response = await axios.post(`${this.orchestratorUrl}/wake`, {}, {
                timeout: 5000,
                validateStatus: status => status < 500
            });
            
            if (response.status === 200 || response.status === 202) {
                logger.info('Wake signal accepted, transitioning to waking state');
                this.wakeState = 'waking';
                
                // Safety timeout: if endpoint doesn't appear, return to idle
                this.wakingTimeout = setTimeout(() => {
                    if (this.wakeState === 'waking' && !this.currentEndpoint) {
                        logger.warn('Wake timeout — no endpoint appeared within timeout, returning to idle');
                        this.wakeState = 'idle';
                        this._wakeInFlight = false;
                    }
                }, WAKING_TIMEOUT_MS);
            } else if (response.status === 409) {
                // Orchestrator is in explicit stop mode — don't retry
                logger.info('Orchestrator returned explicit stop (409), staying idle');
                this.wakeState = 'idle';
                this._wakeInFlight = false;
            } else {
                logger.warn(`Unexpected wake response: ${response.status}`);
                this.wakeState = 'idle';
                this._wakeInFlight = false;
            }
        } catch (err) {
            logger.error('Wake request failed:', err.message);
            this.wakeState = 'idle';
            this._wakeInFlight = false;
        }
    }

    _checkLocalAuth(req) {
        /* Validate Proxy-Authorization header for local HTTP proxy access.
           Returns true if auth passes or local auth is disabled. */
        if (!LOCAL_REQUIRE_AUTH) return true;
        
        const authHeader = req.headers['proxy-authorization'];
        if (!authHeader) {
            logger.warn('Local auth required but no Proxy-Authorization header');
            return false;
        }
        
        // Parse Basic auth
        const parts = authHeader.split(' ');
        if (parts.length !== 2 || parts[0].toLowerCase() !== 'basic') {
            logger.warn('Local auth: unsupported scheme (expected Basic)');
            return false;
        }
        
        try {
            const decoded = Buffer.from(parts[1], 'base64').toString('utf8');
            const colon = decoded.indexOf(':');
            if (colon === -1) return false;
            const user = decoded.substring(0, colon);
            const pass = decoded.substring(colon + 1);
            
            if (user === LOCAL_PROXY_USER && pass === LOCAL_PROXY_PASSWORD) {
                return true;
            }
            logger.warn(`Local auth failed for user: ${user}`);
            return false;
        } catch (err) {
            logger.warn('Local auth: failed to decode credentials');
            return false;
        }
    }

    _send407(res) {
        /* Send HTTP 407 Proxy Authentication Required */
        if (!res.headersSent) {
            res.writeHead(407, {
                'Content-Type': 'text/plain',
                'Proxy-Authenticate': 'Basic realm="SOCKS5 Proxy"'
            });
            res.end('Proxy authentication required');
        }
    }

    _trackActivity() {
        /* Mark activity timestamp — called on each real proxy request */
        this.lastActivityAt = Date.now();
    }

    shutdown() {
        logger.info('Shutting down proxy...');
        this.running = false;
        if (this.updateInterval) {
            clearInterval(this.updateInterval);
        }
        if (this.wakingTimeout) {
            clearTimeout(this.wakingTimeout);
            this.wakingTimeout = null;
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
        const now = Date.now();
        const idleForSeconds = proxy.lastActivityAt ? Math.round((now - proxy.lastActivityAt) / 1000) : null;
        const status = {
            status: proxy.running ? 'running' : 'stopped',
            endpoint: proxy.currentEndpoint,
            activeConnections: proxy.activeConnections,
            totalRequests: proxy.totalRequests,
            wakeState: proxy.wakeState,
            lastActivityAt: proxy.lastActivityAt,
            idleForSeconds: idleForSeconds
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
    const managementPort = HEALTH_PORT;
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