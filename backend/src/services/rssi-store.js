/**
 * In-memory store for RSSI data from all active users
 */
export class RSSIStore {
  constructor() {
    // Map<userId, { detectedUsers: Map<targetId, { rssi, timestamp }>, lastUpdate: Date }>
    this.userRSSIData = new Map();

    // Auto-cleanup old data every 10 seconds
    this.cleanupInterval = setInterval(() => {
      this.cleanupOldData();
    }, 10000);
  }

  /**
   * Store RSSI report from a user
   * @param {string} userId - The reporting user's ID
   * @param {Array<{userId: string, rssi: number, timestamp: string}>} detectedUsers - Detected users and their RSSI values
   */
  storeRSSIReport(userId, detectedUsers) {
    const userData = {
      detectedUsers: new Map(),
      lastUpdate: new Date()
    };

    for (const detected of detectedUsers) {
      userData.detectedUsers.set(detected.userId, {
        rssi: detected.rssi,
        timestamp: new Date(detected.timestamp)
      });
    }

    this.userRSSIData.set(userId, userData);
  }

  /**
   * Get RSSI value between two users (average of both directions if available)
   * @param {string} userA - First user ID
   * @param {string} userB - Second user ID
   * @returns {number|null} - Average RSSI or null if not available
   */
  getRSSIBetween(userA, userB) {
    const rssiValues = [];

    // A -> B
    const aData = this.userRSSIData.get(userA);
    if (aData && aData.detectedUsers.has(userB)) {
      rssiValues.push(aData.detectedUsers.get(userB).rssi);
    }

    // B -> A
    const bData = this.userRSSIData.get(userB);
    if (bData && bData.detectedUsers.has(userA)) {
      rssiValues.push(bData.detectedUsers.get(userA).rssi);
    }

    if (rssiValues.length === 0) return null;
    return rssiValues.reduce((a, b) => a + b, 0) / rssiValues.length;
  }

  /**
   * Get all active user IDs
   * @returns {string[]} - Array of active user IDs
   */
  getActiveUserIds() {
    return Array.from(this.userRSSIData.keys());
  }

  /**
   * Get count of active users
   * @returns {number} - Number of active users
   */
  getActiveUserCount() {
    return this.userRSSIData.size;
  }

  /**
   * Build distance matrix from RSSI data
   * @returns {{userIds: string[], distances: number[][]}} - Distance matrix
   */
  buildDistanceMatrix() {
    const userIds = this.getActiveUserIds();
    const n = userIds.length;
    const distances = [];

    for (let i = 0; i < n; i++) {
      distances[i] = [];
      for (let j = 0; j < n; j++) {
        if (i === j) {
          distances[i][j] = 0;
        } else {
          const rssi = this.getRSSIBetween(userIds[i], userIds[j]);
          distances[i][j] = rssi !== null ? this.rssiToDistance(rssi) : Infinity;
        }
      }
    }

    return { userIds, distances };
  }

  /**
   * Convert RSSI to distance using log-distance path loss model
   * @param {number} rssi - RSSI value in dBm
   * @returns {number} - Estimated distance (normalized 0-1)
   */
  rssiToDistance(rssi) {
    // Parameters for log-distance path loss model
    const txPower = -59; // Reference RSSI at 1 meter
    const n = 2.5; // Path loss exponent (2-4, higher for more obstacles)

    // Calculate distance in meters
    const distanceMeters = Math.pow(10, (txPower - rssi) / (10 * n));

    // Normalize to 0-1 range (assuming max range of ~20 meters)
    const maxRange = 20;
    return Math.min(distanceMeters / maxRange, 1);
  }

  /**
   * Remove data older than 30 seconds
   */
  cleanupOldData() {
    const now = new Date();
    const maxAge = 30000; // 30 seconds

    for (const [userId, data] of this.userRSSIData.entries()) {
      if (now - data.lastUpdate > maxAge) {
        this.userRSSIData.delete(userId);
      }
    }
  }

  /**
   * Remove a specific user from the store
   * @param {string} userId - User ID to remove
   */
  removeUser(userId) {
    this.userRSSIData.delete(userId);
  }

  /**
   * Get raw RSSI data for a specific user (for fallback mode)
   * @param {string} userId - User ID
   * @returns {Map<string, {rssi: number, timestamp: Date}>|null} - Detected users map or null
   */
  getUserRSSIData(userId) {
    const data = this.userRSSIData.get(userId);
    return data ? data.detectedUsers : null;
  }

  /**
   * Cleanup resources
   */
  destroy() {
    clearInterval(this.cleanupInterval);
  }
}
