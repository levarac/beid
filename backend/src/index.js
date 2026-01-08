import express from 'express';
import cors from 'cors';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import dotenv from 'dotenv';

import { rssiRouter } from './routes/rssi.js';
import { sensingRouter } from './routes/sensing.js';
import { logsRouter } from './routes/logs.js';
import { WebSocketService } from './services/websocket.js';
import { TrilaterationService } from './services/trilateration.js';
import { RSSIStore } from './services/rssi-store.js';
import { RSSILogger } from './services/rssi-logger.js';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(express.json());

// Initialize services
const rssiStore = new RSSIStore();
const trilaterationService = new TrilaterationService();
const rssiLogger = new RSSILogger('./logs');

// Create HTTP server
const server = createServer(app);

// Initialize WebSocket server
const wss = new WebSocketServer({ server, path: '/ws' });
const wsService = new WebSocketService(wss, rssiStore, trilaterationService, rssiLogger);

// Routes
app.use('/api/rssi', rssiRouter(rssiStore, wsService));
app.use('/api/sensing', sensingRouter);
app.use('/api/logs', logsRouter(rssiLogger));

// Health check
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    activeUsers: rssiStore.getActiveUserCount(),
    trilaterationEnabled: rssiStore.getActiveUserCount() >= 3,
    logger: rssiLogger.getStats()
  });
});

// Start position calculation loop
const POSITION_UPDATE_INTERVAL = 5000; // 5 seconds
setInterval(() => {
  wsService.broadcastPositions();
}, POSITION_UPDATE_INTERVAL);

// Start server
server.listen(PORT, () => {
  console.log(`Beid Backend running on port ${PORT}`);
  console.log(`WebSocket server available at ws://localhost:${PORT}/ws`);
});
