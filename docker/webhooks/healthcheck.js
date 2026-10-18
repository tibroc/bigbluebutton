'use strict';

// Healthy when the hooks API accepts connections (modules."../out/webhooks/index.js".config.api.port,
// opened once the modules have started). A TCP connect, not a request to /bigbluebutton/api/hooks/ping:
// the API logs every request it receives.
const net = require('net');

const PORT = 3005;
const TIMEOUT_MS = 2000;

const socket = net.connect({ host: '127.0.0.1', port: PORT });
socket.setTimeout(TIMEOUT_MS);
socket.once('connect', () => { socket.destroy(); process.exit(0); });
socket.once('timeout', () => { socket.destroy(); console.error(`port ${PORT}: timeout`); process.exit(1); });
socket.once('error', (error) => { console.error(`port ${PORT}: ${error.code || error.message}`); process.exit(1); });
