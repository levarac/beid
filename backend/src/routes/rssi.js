import express from 'express';

/**
 * RSSI data collection routes
 * @param {import('../services/rssi-store.js').RSSIStore} rssiStore
 * @param {import('../services/websocket.js').WebSocketService} wsService
 */
export function rssiRouter(rssiStore, wsService) {
  const router = express.Router();

  /**
   * POST /api/rssi/report
   * Receive RSSI data from a client
   */
  router.post('/report', (req, res) => {
    const { userId, detectedUsers } = req.body;

    // Validate request
    if (!userId || typeof userId !== 'string') {
      return res.status(400).json({
        success: false,
        error: 'userId is required and must be a string'
      });
    }

    if (!Array.isArray(detectedUsers)) {
      return res.status(400).json({
        success: false,
        error: 'detectedUsers must be an array'
      });
    }

    // Validate each detected user entry
    for (const detected of detectedUsers) {
      if (!detected.userId || typeof detected.rssi !== 'number') {
        return res.status(400).json({
          success: false,
          error: 'Each detected user must have userId and rssi (number)'
        });
      }
    }

    // Store RSSI data
    rssiStore.storeRSSIReport(userId, detectedUsers);

    const activeUsers = rssiStore.getActiveUserCount();

    res.json({
      success: true,
      activeUsers,
      trilaterationEnabled: activeUsers >= 3
    });
  });

  /**
   * GET /api/rssi/stats
   * Get current RSSI collection statistics
   */
  router.get('/stats', (req, res) => {
    const stats = {
      activeUsers: rssiStore.getActiveUserCount(),
      userIds: rssiStore.getActiveUserIds(),
      trilaterationEnabled: rssiStore.getActiveUserCount() >= 3,
      wsStats: wsService.getStats()
    };

    res.json(stats);
  });

  /**
   * GET /api/rssi/distance-matrix
   * Get current distance matrix (for debugging)
   */
  router.get('/distance-matrix', (req, res) => {
    const matrix = rssiStore.buildDistanceMatrix();
    res.json(matrix);
  });

  return router;
}
