import fs from 'fs';
import path from 'path';

/**
 * Graph statistics logger - logs periodic graph stats to CSV
 */
export class StatsLogger {
  constructor(logDir = './logs', sessionManager = null) {
    this.logDir = logDir;
    this.sessionManager = sessionManager;
    this.currentLogFile = null;
    this.writeStream = null;
    this.isEnabled = true;
    this.rowCount = 0;
    this.statsInterval = null;

    // Ensure log directory exists
    if (!fs.existsSync(this.logDir)) {
      fs.mkdirSync(this.logDir, { recursive: true });
    }

    this._startNewLogFile();
  }

  /**
   * Start a new log file
   */
  _startNewLogFile() {
    if (this.writeStream) {
      this.writeStream.end();
    }

    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').split('T')[0];
    const filename = `graph_stats_${timestamp}_${Date.now()}.csv`;
    this.currentLogFile = path.join(this.logDir, filename);

    this.writeStream = fs.createWriteStream(this.currentLogFile, { flags: 'a' });

    // Write CSV header
    const headers = [
      'timestamp',
      'session_id',
      'node_count',
      'edge_count',
      'mutual_edge_count',
      'density',
      'avg_rssi',
      'avg_distance',
      'avg_degree',
      'max_degree',
      'min_degree',
      'connected_components',
      'is_fully_connected'
    ];
    this.writeStream.write(headers.join(',') + '\n');
    this.rowCount = 0;

    console.log(`Stats Logger: Started new log file: ${this.currentLogFile}`);
  }

  /**
   * Start periodic stats logging
   * @param {number} intervalMs - Interval in milliseconds
   * @param {object} providers - Data providers { rssiStore, edgeLogger, nodeLogger }
   */
  startPeriodicLogging(intervalMs, providers) {
    if (this.statsInterval) {
      clearInterval(this.statsInterval);
    }

    this.statsInterval = setInterval(() => {
      this.logStats(providers);
    }, intervalMs);

    console.log(`Stats Logger: Started periodic logging every ${intervalMs}ms`);
  }

  /**
   * Stop periodic logging
   */
  stopPeriodicLogging() {
    if (this.statsInterval) {
      clearInterval(this.statsInterval);
      this.statsInterval = null;
    }
    console.log('Stats Logger: Stopped periodic logging');
  }

  /**
   * Log current graph stats
   * @param {object} providers - Data providers
   */
  logStats(providers) {
    if (!this.isEnabled || !this.writeStream) return;

    const { rssiStore, edgeLogger, nodeLogger } = providers;
    const stats = this._calculateStats(rssiStore, edgeLogger, nodeLogger);

    const now = new Date().toISOString();
    const sessionId = this.sessionManager?.getSessionId() ?? 'no-session';

    const row = [
      now,
      sessionId,
      stats.nodeCount,
      stats.edgeCount,
      stats.mutualEdgeCount,
      stats.density.toFixed(4),
      stats.avgRssi !== null ? stats.avgRssi.toFixed(2) : '',
      stats.avgDistance !== null ? stats.avgDistance.toFixed(3) : '',
      stats.avgDegree.toFixed(2),
      stats.maxDegree,
      stats.minDegree,
      stats.connectedComponents,
      stats.isFullyConnected
    ].join(',');

    this.writeStream.write(row + '\n');
    this.rowCount++;
  }

  /**
   * Calculate graph statistics
   * @param {object} rssiStore
   * @param {object} edgeLogger
   * @param {object} nodeLogger
   * @returns {object}
   */
  _calculateStats(rssiStore, edgeLogger, nodeLogger) {
    // Get node count
    const nodeCount = nodeLogger
      ? nodeLogger.getActiveNodeCount()
      : (rssiStore?.getActiveUserCount() ?? 0);

    // Get edge data
    let edgeCount = 0;
    let mutualEdgeCount = 0;
    let rssiValues = [];
    let distances = [];
    let adjacencyList = {};

    const nodeIds = nodeLogger
      ? nodeLogger.getActiveNodeIds()
      : (rssiStore?.getActiveUserIds() ?? []);

    // Initialize adjacency list
    for (const nodeId of nodeIds) {
      adjacencyList[nodeId] = [];
    }

    if (edgeLogger) {
      const edges = edgeLogger.getCurrentEdges();
      edgeCount = edges.length;
      mutualEdgeCount = edges.filter(e => e.mutual).length;

      for (const edge of edges) {
        // RSSI values
        if (edge.rssiAtoB !== null) rssiValues.push(edge.rssiAtoB);
        if (edge.rssiBtoA !== null) rssiValues.push(edge.rssiBtoA);

        // Distance
        const avgRssi = (edge.rssiAtoB !== null && edge.rssiBtoA !== null)
          ? (edge.rssiAtoB + edge.rssiBtoA) / 2
          : (edge.rssiAtoB ?? edge.rssiBtoA);
        if (avgRssi !== null) {
          distances.push(this._rssiToDistance(avgRssi));
        }

        // Adjacency
        if (adjacencyList[edge.nodeA]) {
          adjacencyList[edge.nodeA].push(edge.nodeB);
        }
        if (adjacencyList[edge.nodeB]) {
          adjacencyList[edge.nodeB].push(edge.nodeA);
        }
      }
    } else if (rssiStore) {
      // Build from RSSI store
      for (let i = 0; i < nodeIds.length; i++) {
        for (let j = i + 1; j < nodeIds.length; j++) {
          const rssi = rssiStore.getRSSIBetween(nodeIds[i], nodeIds[j]);
          if (rssi !== null) {
            edgeCount++;
            rssiValues.push(rssi);
            distances.push(this._rssiToDistance(rssi));

            const aData = rssiStore.getUserRSSIData(nodeIds[i]);
            const bData = rssiStore.getUserRSSIData(nodeIds[j]);
            if (aData?.has(nodeIds[j]) && bData?.has(nodeIds[i])) {
              mutualEdgeCount++;
            }

            adjacencyList[nodeIds[i]].push(nodeIds[j]);
            adjacencyList[nodeIds[j]].push(nodeIds[i]);
          }
        }
      }
    }

    // Calculate density
    const maxEdges = (nodeCount * (nodeCount - 1)) / 2;
    const density = maxEdges > 0 ? edgeCount / maxEdges : 0;

    // Average RSSI
    const avgRssi = rssiValues.length > 0
      ? rssiValues.reduce((a, b) => a + b, 0) / rssiValues.length
      : null;

    // Average distance
    const avgDistance = distances.length > 0
      ? distances.reduce((a, b) => a + b, 0) / distances.length
      : null;

    // Degree statistics
    const degrees = nodeIds.map(n => adjacencyList[n]?.length ?? 0);
    const avgDegree = degrees.length > 0
      ? degrees.reduce((a, b) => a + b, 0) / degrees.length
      : 0;
    const maxDegree = Math.max(0, ...degrees);
    const minDegree = degrees.length > 0 ? Math.min(...degrees) : 0;

    // Connected components
    const connectedComponents = this._countConnectedComponents(nodeIds, adjacencyList);
    const isFullyConnected = connectedComponents === 1 && nodeCount > 0;

    return {
      nodeCount,
      edgeCount,
      mutualEdgeCount,
      density,
      avgRssi,
      avgDistance,
      avgDegree,
      maxDegree,
      minDegree,
      connectedComponents,
      isFullyConnected
    };
  }

  /**
   * Count connected components
   * @param {Array} nodes
   * @param {object} adjacencyList
   * @returns {number}
   */
  _countConnectedComponents(nodes, adjacencyList) {
    if (nodes.length === 0) return 0;

    const visited = new Set();
    let components = 0;

    for (const startNode of nodes) {
      if (visited.has(startNode)) continue;

      const queue = [startNode];
      while (queue.length > 0) {
        const node = queue.shift();
        if (visited.has(node)) continue;

        visited.add(node);

        const neighbors = adjacencyList[node] || [];
        for (const neighbor of neighbors) {
          if (!visited.has(neighbor)) {
            queue.push(neighbor);
          }
        }
      }

      components++;
    }

    return components;
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
   * Get all log files
   * @returns {Array}
   */
  getLogFiles() {
    if (!fs.existsSync(this.logDir)) {
      return [];
    }

    return fs.readdirSync(this.logDir)
      .filter(f => f.startsWith('graph_stats_') && f.endsWith('.csv'))
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
   * Get current stats summary (not logged, just computed)
   * @param {object} providers
   * @returns {object}
   */
  getCurrentStats(providers) {
    return this._calculateStats(
      providers.rssiStore,
      providers.edgeLogger,
      providers.nodeLogger
    );
  }

  /**
   * Get stats
   * @returns {object}
   */
  getStats() {
    return {
      enabled: this.isEnabled,
      currentFile: this.currentLogFile,
      rowCount: this.rowCount,
      periodicActive: this.statsInterval !== null
    };
  }

  /**
   * Enable/disable
   * @param {boolean} enabled
   */
  setEnabled(enabled) {
    this.isEnabled = enabled;
    console.log(`Stats Logger: ${enabled ? 'Enabled' : 'Disabled'}`);
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
    this.stopPeriodicLogging();
    if (this.writeStream) {
      this.writeStream.end();
      this.writeStream = null;
    }
  }
}
