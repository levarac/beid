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

// Logging services
import { SessionManager } from './services/session-manager.js';
import { RSSILogger } from './services/rssi-logger.js';
import { EdgeLogger } from './services/edge-logger.js';
import { NodeLogger } from './services/node-logger.js';
import { GraphSnapshotService } from './services/graph-snapshot.js';
import { StatsLogger } from './services/stats-logger.js';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;
const LOG_DIR = process.env.LOG_DIR || './logs';

// Middleware
app.use(cors());
app.use(express.json());

// Initialize core services
const rssiStore = new RSSIStore();
const trilaterationService = new TrilaterationService();

// Initialize logging services
const sessionManager = new SessionManager();
const rssiLogger = new RSSILogger(LOG_DIR, sessionManager);
const edgeLogger = new EdgeLogger(LOG_DIR, sessionManager);
const nodeLogger = new NodeLogger(LOG_DIR, sessionManager);
const graphSnapshot = new GraphSnapshotService(LOG_DIR, sessionManager);
const statsLogger = new StatsLogger(LOG_DIR, sessionManager);

// Start a new session
sessionManager.startSession();

// Create HTTP server
const server = createServer(app);

// Initialize WebSocket server with all loggers
const wss = new WebSocketServer({ server, path: '/ws' });
const wsService = new WebSocketService(wss, rssiStore, trilaterationService, {
  rssiLogger,
  edgeLogger,
  nodeLogger,
  sessionManager
});

// Get log providers for periodic logging
const logProviders = {
  rssiStore,
  edgeLogger,
  nodeLogger
};

// Start periodic graph snapshots (every 30 seconds)
graphSnapshot.startPeriodicSnapshots(30000, logProviders);

// Start periodic stats logging (every 10 seconds)
statsLogger.startPeriodicLogging(10000, logProviders);

// Routes
app.use('/api/rssi', rssiRouter(rssiStore, wsService));
app.use('/api/sensing', sensingRouter);
app.use('/api/logs', logsRouter({
  rssiLogger,
  edgeLogger,
  nodeLogger,
  graphSnapshot,
  statsLogger,
  sessionManager
}));

// Health check
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    session: sessionManager.getCurrentSession(),
    activeUsers: rssiStore.getActiveUserCount(),
    trilaterationEnabled: rssiStore.getActiveUserCount() >= 3,
    graph: {
      nodes: nodeLogger.getActiveNodeCount(),
      edges: edgeLogger.getEdgeCount(),
      mutualEdges: edgeLogger.getMutualEdgeCount()
    },
    logging: {
      rssi: rssiLogger.getStats(),
      edge: edgeLogger.getStats(),
      node: nodeLogger.getStats(),
      snapshot: graphSnapshot.getStats(),
      stats: statsLogger.getStats()
    }
  });
});

// Session management endpoints
app.post('/api/session/start', (req, res) => {
  const session = sessionManager.startSession();

  // Rotate all log files for new session
  rssiLogger.rotateLog();
  edgeLogger.rotateLog();
  nodeLogger.rotateLog();
  statsLogger.rotateLog();

  res.json({ session });
});

app.post('/api/session/end', (req, res) => {
  const session = sessionManager.endSession();
  res.json({ session });
});

app.get('/api/session/current', (req, res) => {
  res.json({ session: sessionManager.getCurrentSession() });
});

app.get('/api/session/history', (req, res) => {
  res.json({ sessions: sessionManager.getHistory() });
});

// Graph data endpoints
app.get('/api/graph/current', (req, res) => {
  const snapshot = graphSnapshot.takeSnapshot(logProviders);
  res.json(snapshot);
});

app.get('/api/graph/stats', (req, res) => {
  const stats = statsLogger.getCurrentStats(logProviders);
  res.json(stats);
});

app.get('/api/graph/edges', (req, res) => {
  const edges = edgeLogger.getCurrentEdges();
  res.json({ edges, count: edges.length });
});

app.get('/api/graph/nodes', (req, res) => {
  const nodes = nodeLogger.getAllNodesData();
  res.json({ nodes, count: nodes.length });
});

// Manual snapshot trigger
app.post('/api/graph/snapshot', (req, res) => {
  const snapshot = graphSnapshot.takeSnapshot(logProviders);
  res.json({ success: true, snapshot });
});

// Start position calculation loop
const POSITION_UPDATE_INTERVAL = 5000; // 5 seconds
setInterval(() => {
  wsService.broadcastPositions();
}, POSITION_UPDATE_INTERVAL);

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('Shutting down...');

  sessionManager.endSession();
  graphSnapshot.destroy();
  statsLogger.destroy();
  edgeLogger.destroy();
  nodeLogger.destroy();
  rssiLogger.destroy();
  rssiStore.destroy();

  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});

// Start server
server.listen(PORT, () => {
  console.log(`Beid Backend running on port ${PORT}`);
  console.log(`WebSocket server available at ws://localhost:${PORT}/ws`);
  console.log(`Session ID: ${sessionManager.getSessionId()}`);
  console.log(`Log directory: ${LOG_DIR}`);
});
