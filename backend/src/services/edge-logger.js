import fs from 'fs';
import path from 'path';

/**
 * Edge event logger - tracks edge establishment and dissolution in the graph
 */
export class EdgeLogger {
  constructor(logDir = './logs', sessionManager = null) {
    this.logDir = logDir;
    this.sessionManager = sessionManager;
    this.currentLogFile = null;
    this.writeStream = null;
    this.isEnabled = true;
    this.eventCount = 0;

    // Track current edges: "nodeA:nodeB" -> { rssiAtoB, rssiBtoA, establishedAt, mutual }
    this.currentEdges = new Map();

    // Configuration
    this.edgeTimeoutMs = 10000; // Edge dissolves after 10 seconds of no updates

    // Ensure log directory exists
    if (!fs.existsSync(this.logDir)) {
      fs.mkdirSync(this.logDir, { recursive: true });
    }

    this._startNewLogFile();

    // Periodic check for dissolved edges
    this.cleanupInterval = setInterval(() => {
      this._checkDissolvedEdges();
    }, 5000);
  }

  /**
   * Start a new log file
   */
  _startNewLogFile() {
    if (this.writeStream) {
      this.writeStream.end();
    }

    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').split('T')[0];
    const filename = `edge_events_${timestamp}_${Date.now()}.csv`;
    this.currentLogFile = path.join(this.logDir, filename);

    this.writeStream = fs.createWriteStream(this.currentLogFile, { flags: 'a' });

    // Write CSV header
    const headers = [
      'timestamp',
      'session_id',
      'event_type',
      'node_a',
      'node_b',
      'rssi_a_to_b',
      'rssi_b_to_a',
      'rssi_avg',
      'distance_estimate',
      'mutual',
      'edge_duration_ms'
    ];
    this.writeStream.write(headers.join(',') + '\n');
    this.eventCount = 0;

    console.log(`Edge Logger: Started new log file: ${this.currentLogFile}`);
  }

  /**
   * Get canonical edge key (sorted node IDs)
   * @param {string} nodeA
   * @param {string} nodeB
   * @returns {string}
   */
  _getEdgeKey(nodeA, nodeB) {
    return [nodeA, nodeB].sort().join(':');
  }

  /**
   * Update edge state based on detection report
   * @param {string} reporterId - Node that reported detection
   * @param {string} detectedId - Node that was detected
   * @param {number} rssi - RSSI value
   * @param {object} rssiStore - Reference to RSSI store for checking reverse direction
   */
  updateEdge(reporterId, detectedId, rssi, rssiStore = null) {
    const key = this._getEdgeKey(reporterId, detectedId);
    const now = Date.now();
    const isNodeAReporter = [reporterId, detectedId].sort()[0] === reporterId;

    // Check reverse direction
    let reverseRssi = null;
    if (rssiStore) {
      const reverseData = rssiStore.getUserRSSIData(detectedId);
      if (reverseData && reverseData.has(reporterId)) {
        reverseRssi = reverseData.get(reporterId).rssi;
      }
    }

    const existingEdge = this.currentEdges.get(key);

    if (!existingEdge) {
      // New edge
      const newEdge = {
        nodeA: [reporterId, detectedId].sort()[0],
        nodeB: [reporterId, detectedId].sort()[1],
        rssiAtoB: isNodeAReporter ? rssi : reverseRssi,
        rssiBtoA: isNodeAReporter ? reverseRssi : rssi,
        establishedAt: now,
        lastUpdate: now,
        mutual: reverseRssi !== null
      };

      this.currentEdges.set(key, newEdge);
      this._logEvent('edge_established', newEdge, null);
    } else {
      // Update existing edge
      const previousMutual = existingEdge.mutual;

      if (isNodeAReporter) {
        existingEdge.rssiAtoB = rssi;
        if (reverseRssi !== null) existingEdge.rssiBtoA = reverseRssi;
      } else {
        existingEdge.rssiBtoA = rssi;
        if (reverseRssi !== null) existingEdge.rssiAtoB = reverseRssi;
      }

      existingEdge.lastUpdate = now;
      existingEdge.mutual = existingEdge.rssiAtoB !== null && existingEdge.rssiBtoA !== null;

      // Log if mutual state changed
      if (existingEdge.mutual !== previousMutual) {
        this._logEvent('edge_updated', existingEdge, null);
      }
    }
  }

  /**
   * Check for dissolved edges (timeout)
   */
  _checkDissolvedEdges() {
    const now = Date.now();

    for (const [key, edge] of this.currentEdges.entries()) {
      if (now - edge.lastUpdate > this.edgeTimeoutMs) {
        const duration = edge.lastUpdate - edge.establishedAt;
        this._logEvent('edge_dissolved', edge, duration);
        this.currentEdges.delete(key);
      }
    }
  }

  /**
   * Log an edge event
   * @param {string} eventType - Event type
   * @param {object} edge - Edge data
   * @param {number|null} duration - Edge duration (for dissolved events)
   */
  _logEvent(eventType, edge, duration) {
    if (!this.isEnabled || !this.writeStream) return;

    const now = new Date().toISOString();
    const sessionId = this.sessionManager?.getSessionId() ?? 'no-session';

    const rssiAvg = (edge.rssiAtoB !== null && edge.rssiBtoA !== null)
      ? ((edge.rssiAtoB + edge.rssiBtoA) / 2).toFixed(1)
      : (edge.rssiAtoB ?? edge.rssiBtoA ?? '');

    const distanceEstimate = rssiAvg ? this._rssiToDistance(parseFloat(rssiAvg)).toFixed(3) : '';

    const row = [
      now,
      sessionId,
      eventType,
      edge.nodeA,
      edge.nodeB,
      edge.rssiAtoB ?? '',
      edge.rssiBtoA ?? '',
      rssiAvg,
      distanceEstimate,
      edge.mutual,
      duration ?? ''
    ].join(',');

    this.writeStream.write(row + '\n');
    this.eventCount++;
  }

  /**
   * Convert RSSI to distance
   * @param {number} rssi
   * @returns {number}
   */
  _rssiToDistance(rssi) {
    const txPower = -59;
    const n = 2.5;
    return Math.pow(10, (txPower - rssi) / (10 * n));
  }

  /**
   * Force remove an edge (e.g., when node disconnects)
   * @param {string} nodeId - Node that disconnected
   */
  removeNodeEdges(nodeId) {
    const now = Date.now();

    for (const [key, edge] of this.currentEdges.entries()) {
      if (edge.nodeA === nodeId || edge.nodeB === nodeId) {
        const duration = now - edge.establishedAt;
        this._logEvent('edge_dissolved', edge, duration);
        this.currentEdges.delete(key);
      }
    }
  }

  /**
   * Get current edge count
   * @returns {number}
   */
  getEdgeCount() {
    return this.currentEdges.size;
  }

  /**
   * Get mutual edge count
   * @returns {number}
   */
  getMutualEdgeCount() {
    let count = 0;
    for (const edge of this.currentEdges.values()) {
      if (edge.mutual) count++;
    }
    return count;
  }

  /**
   * Get all current edges
   * @returns {Array}
   */
  getCurrentEdges() {
    return Array.from(this.currentEdges.values());
  }

  /**
   * Get all log files
   * @returns {Array}
   */
  getLogFiles() {
    if (!fs.existsSync(this.logDir)) {
      return [];
    }

    return fs.readdirSync(this.logDir)
      .filter(f => f.startsWith('edge_events_') && f.endsWith('.csv'))
      .map(filename => {
        const filePath = path.join(this.logDir, filename);
        const stats = fs.statSync(filePath);
        return {
          filename,
          path: filePath,
          size: stats.size,
          created: stats.birthtime
        };
      })
      .sort((a, b) => b.created - a.created);
  }

  /**
   * Get log file content
   * @param {string} filename
   * @returns {string|null}
   */
  getLogContent(filename) {
    const filePath = path.join(this.logDir, filename);
    if (!fs.existsSync(filePath)) {
      return null;
    }
    return fs.readFileSync(filePath, 'utf-8');
  }

  /**
   * Get stats
   * @returns {object}
   */
  getStats() {
    return {
      enabled: this.isEnabled,
      currentFile: this.currentLogFile,
      eventCount: this.eventCount,
      currentEdges: this.currentEdges.size,
      mutualEdges: this.getMutualEdgeCount()
    };
  }

  /**
   * Enable/disable logging
   * @param {boolean} enabled
   */
  setEnabled(enabled) {
    this.isEnabled = enabled;
    console.log(`Edge Logger: ${enabled ? 'Enabled' : 'Disabled'}`);
  }

  /**
   * Rotate log file
   */
  rotateLog() {
    this._startNewLogFile();
  }

  /**
   * Cleanup
   */
  destroy() {
    clearInterval(this.cleanupInterval);
    if (this.writeStream) {
      this.writeStream.end();
      this.writeStream = null;
    }
  }
}
