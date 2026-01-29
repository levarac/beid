/**
 * WebSocket service for real-time position updates
 * Integrated with extended logging services
 */
export class WebSocketService {
  constructor(wss, rssiStore, trilaterationService, loggers = {}) {
    this.wss = wss;
    this.rssiStore = rssiStore;
    this.trilaterationService = trilaterationService;

    // Logging services
    this.rssiLogger = loggers.rssiLogger || null;
    this.edgeLogger = loggers.edgeLogger || null;
    this.nodeLogger = loggers.nodeLogger || null;
    this.sessionManager = loggers.sessionManager || null;

    // Map<WebSocket, {userId: string, metadata: object}>
    this.clients = new Map();

    this.setupConnectionHandlers();
  }

  setupConnectionHandlers() {
    this.wss.on('connection', (ws, req) => {
      console.log('New WebSocket connection');

      ws.on('message', (data) => {
        this.handleMessage(ws, data);
      });

      ws.on('close', () => {
        this.handleDisconnect(ws);
      });

      ws.on('error', (error) => {
        console.error('WebSocket error:', error);
        this.handleDisconnect(ws);
      });
    });
  }

  handleMessage(ws, data) {
    try {
      const message = JSON.parse(data.toString());

      switch (message.type) {
        case 'register':
          this.handleRegister(ws, message.userId, message.eventCode, message.metadata);
          break;
        case 'rssi_report':
          this.handleRSSIReport(ws, message);
          break;
        case 'compass_enabled':
          this.handleCompassEnabled(ws, message);
          break;
        default:
          console.log('Unknown message type:', message.type);
      }
    } catch (error) {
      console.error('Failed to parse WebSocket message:', error);
    }
  }

  handleRegister(ws, userId, eventCode = null, metadata = {}) {
    if (!userId) {
      this.sendToClient(ws, {
        type: 'error',
        message: 'userId is required for registration'
      });
      return;
    }

    // Store client info with metadata and eventCode
    this.clients.set(ws, { userId, eventCode, metadata });

    // Log node joined event with eventCode
    if (this.nodeLogger) {
      this.nodeLogger.logNodeJoined(userId, { ...metadata, eventCode });
    }

    // Update session stats
    if (this.sessionManager) {
      this.sessionManager.updateStats({
        nodeCount: this.clients.size
      });
    }

    // Notify other clients about new user
    this.broadcastToAll({
      type: 'user_joined',
      payload: {
        userId,
        action: 'joined'
      }
    }, ws);

    // Send welcome message with current state
    this.sendToClient(ws, {
      type: 'registered',
      payload: {
        userId,
        activeUsers: this.rssiStore.getActiveUserCount(),
        trilaterationEnabled: this.rssiStore.getActiveUserCount() >= 3,
        sessionId: this.sessionManager?.getSessionId() ?? null
      }
    });

    console.log(`User ${userId} registered. Active clients: ${this.clients.size}`);
  }

  handleRSSIReport(ws, message) {
    const clientInfo = this.clients.get(ws);
    if (!clientInfo) {
      this.sendToClient(ws, {
        type: 'error',
        message: 'Client not registered. Send register message first.'
      });
      return;
    }

    const { detectedUsers, heading, eventCode } = message;
    if (!Array.isArray(detectedUsers)) {
      this.sendToClient(ws, {
        type: 'error',
        message: 'detectedUsers must be an array'
      });
      return;
    }

    // Update client's eventCode if provided (may change during session)
    if (eventCode !== undefined) {
      clientInfo.eventCode = eventCode;
    }

    // Store RSSI data with heading
    this.rssiStore.storeRSSIReport(clientInfo.userId, detectedUsers, heading ?? null);

    // Log to extended RSSI CSV file
    if (this.rssiLogger) {
      this.rssiLogger.logRSSIReport(clientInfo.userId, detectedUsers, heading, {
        rssiStore: this.rssiStore,
        eventCode: clientInfo.eventCode
      });
    }

    // Update edge logger
    if (this.edgeLogger) {
      for (const detected of detectedUsers) {
        this.edgeLogger.updateEdge(
          clientInfo.userId,
          detected.userId,
          detected.rssi,
          this.rssiStore
        );
      }
    }

    // Update node logger report count
    if (this.nodeLogger) {
      this.nodeLogger.incrementReportCount(clientInfo.userId);
    }

    // Update session stats
    if (this.sessionManager) {
      this.sessionManager.incrementReportCount();
      this.sessionManager.updateStats({
        edgeCount: this.edgeLogger?.getEdgeCount() ?? 0
      });
    }

    // Acknowledge receipt
    this.sendToClient(ws, {
      type: 'rssi_received',
      payload: {
        activeUsers: this.rssiStore.getActiveUserCount(),
        trilaterationEnabled: this.rssiStore.getActiveUserCount() >= 3,
        edgeCount: this.edgeLogger?.getEdgeCount() ?? 0,
        mutualEdgeCount: this.edgeLogger?.getMutualEdgeCount() ?? 0
      }
    });
  }

  handleCompassEnabled(ws, message) {
    const clientInfo = this.clients.get(ws);
    if (!clientInfo) {
      this.sendToClient(ws, {
        type: 'error',
        message: 'Client not registered. Send register message first.'
      });
      return;
    }

    const { enabled } = message;
    this.rssiStore.setCompassEnabled(clientInfo.userId, enabled);

    // Update node metadata
    if (this.nodeLogger) {
      this.nodeLogger.updateNodeMetadata(clientInfo.userId, { compassEnabled: enabled });
    }

    console.log(`User ${clientInfo.userId} compass ${enabled ? 'enabled' : 'disabled'}`);
  }

  handleDisconnect(ws) {
    const clientInfo = this.clients.get(ws);
    if (clientInfo) {
      // Log node left event
      if (this.nodeLogger) {
        this.nodeLogger.logNodeLeft(clientInfo.userId);
      }

      // Remove edges for this node
      if (this.edgeLogger) {
        this.edgeLogger.removeNodeEdges(clientInfo.userId);
      }

      // Remove from RSSI store
      this.rssiStore.removeUser(clientInfo.userId);

      // Notify other clients
      this.broadcastToAll({
        type: 'user_left',
        payload: {
          userId: clientInfo.userId,
          action: 'left'
        }
      }, ws);

      // Update session stats
      if (this.sessionManager) {
        this.sessionManager.updateStats({
          nodeCount: this.clients.size - 1,
          edgeCount: this.edgeLogger?.getEdgeCount() ?? 0
        });
      }

      console.log(`User ${clientInfo.userId} disconnected. Active clients: ${this.clients.size - 1}`);
    }

    this.clients.delete(ws);
  }

  /**
   * Broadcast position updates to all connected clients
   * Called periodically from main loop
   */
  broadcastPositions() {
    const activeUsers = this.rssiStore.getActiveUserCount();

    if (activeUsers < 3) {
      // Not enough users for trilateration, send fallback notice
      this.broadcastToAll({
        type: 'fallback_mode',
        payload: {
          reason: 'insufficient_users',
          activeUsers,
          edgeCount: this.edgeLogger?.getEdgeCount() ?? 0,
          mutualEdgeCount: this.edgeLogger?.getMutualEdgeCount() ?? 0
        }
      });
      return;
    }

    // Build distance matrix and calculate positions
    const distanceMatrix = this.rssiStore.buildDistanceMatrix();
    const positions = this.trilaterationService.calculatePositions(distanceMatrix);

    if (!positions) {
      // Calculation failed, send fallback notice
      this.broadcastToAll({
        type: 'fallback_mode',
        payload: {
          reason: 'calculation_failed',
          activeUsers,
          edgeCount: this.edgeLogger?.getEdgeCount() ?? 0,
          mutualEdgeCount: this.edgeLogger?.getMutualEdgeCount() ?? 0
        }
      });
      return;
    }

    // Send personalized position updates to each client
    for (const [ws, clientInfo] of this.clients.entries()) {
      const relativePositions = this.trilaterationService.calculateRelativeAngles(
        positions,
        clientInfo.userId
      );

      // Get viewer's heading for compass correction
      const viewerHeading = this.rssiStore.getHeading(clientInfo.userId);
      const compassEnabled = this.rssiStore.isCompassEnabled(clientInfo.userId);

      // Add RSSI data to positions and apply compass rotation if enabled
      const positionsWithRSSI = relativePositions.map(pos => {
        const rssi = this.rssiStore.getRSSIBetween(clientInfo.userId, pos.targetUserId);
        let adjustedAngle = pos.angle;

        // If compass is enabled and we have a valid heading, rotate the angle
        if (compassEnabled && viewerHeading !== null) {
          // Subtract viewer's heading to get absolute direction
          // The viewer is facing 'viewerHeading' degrees from north
          // So we need to rotate the relative positions accordingly
          adjustedAngle = (pos.angle - viewerHeading + 360) % 360;
        }

        return {
          ...pos,
          angle: adjustedAngle,
          rssi: rssi || -100 // Default to weak signal if not available
        };
      });

      this.sendToClient(ws, {
        type: 'position_update',
        payload: {
          userId: clientInfo.userId,
          positions: positionsWithRSSI,
          timestamp: new Date().toISOString(),
          compassEnabled: compassEnabled,
          graphStats: {
            nodeCount: activeUsers,
            edgeCount: this.edgeLogger?.getEdgeCount() ?? 0,
            mutualEdgeCount: this.edgeLogger?.getMutualEdgeCount() ?? 0
          }
        }
      });
    }
  }

  /**
   * Send message to a specific client
   */
  sendToClient(ws, message) {
    if (ws.readyState === 1) { // WebSocket.OPEN
      ws.send(JSON.stringify(message));
    }
  }

  /**
   * Broadcast message to all connected clients
   * @param {object} message - Message to broadcast
   * @param {WebSocket} excludeWs - Optional client to exclude
   */
  broadcastToAll(message, excludeWs = null) {
    const messageStr = JSON.stringify(message);
    for (const [ws] of this.clients.entries()) {
      if (ws !== excludeWs && ws.readyState === 1) {
        ws.send(messageStr);
      }
    }
  }

  /**
   * Get connection statistics
   */
  getStats() {
    return {
      connectedClients: this.clients.size,
      activeUsers: this.rssiStore.getActiveUserCount(),
      edgeCount: this.edgeLogger?.getEdgeCount() ?? 0,
      mutualEdgeCount: this.edgeLogger?.getMutualEdgeCount() ?? 0,
      sessionId: this.sessionManager?.getSessionId() ?? null
    };
  }

  /**
   * Get logging providers for external use
   */
  getLogProviders() {
    return {
      rssiStore: this.rssiStore,
      edgeLogger: this.edgeLogger,
      nodeLogger: this.nodeLogger
    };
  }
}
