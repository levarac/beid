import fs from 'fs';
import path from 'path';

/**
 * Graph snapshot service - captures and saves graph state at intervals
 */
export class GraphSnapshotService {
  constructor(logDir = './logs', sessionManager = null) {
    this.logDir = logDir;
    this.sessionManager = sessionManager;
    this.snapshotDir = path.join(logDir, 'snapshots');
    this.isEnabled = true;
    this.snapshotCount = 0;
    this.snapshotInterval = null;
    this.currentLogFile = null;
    this.writeStream = null;

    // Ensure snapshot directory exists
    if (!fs.existsSync(this.snapshotDir)) {
      fs.mkdirSync(this.snapshotDir, { recursive: true });
    }

    // Initialize log file for this session
    this._initLogFile();
  }

  /**
   * Initialize or rotate log file
   */
  _initLogFile() {
    const date = new Date().toISOString().split('T')[0];
    const sessionId = this.sessionManager?.getSessionId() ?? 'no-session';
    this.currentLogFile = path.join(this.snapshotDir, `snapshots_${date}_${sessionId}.jsonl`);

    // Close existing stream if any
    if (this.writeStream) {
      this.writeStream.end();
    }

    // Create append stream
    this.writeStream = fs.createWriteStream(this.currentLogFile, { flags: 'a' });
    console.log(`Graph Snapshot: Using log file ${this.currentLogFile}`);
  }

  /**
   * Start periodic snapshots
   * @param {number} intervalMs - Interval in milliseconds
   * @param {object} providers - Data providers { rssiStore, edgeLogger, nodeLogger }
   */
  startPeriodicSnapshots(intervalMs, providers) {
    if (this.snapshotInterval) {
      clearInterval(this.snapshotInterval);
    }

    this.snapshotInterval = setInterval(() => {
      this.takeSnapshot(providers);
    }, intervalMs);

    console.log(`Graph Snapshot: Started periodic snapshots every ${intervalMs}ms`);
  }

  /**
   * Stop periodic snapshots
   */
  stopPeriodicSnapshots() {
    if (this.snapshotInterval) {
      clearInterval(this.snapshotInterval);
      this.snapshotInterval = null;
    }
    console.log('Graph Snapshot: Stopped periodic snapshots');
  }

  /**
   * Take a snapshot of current graph state
   * @param {object} providers - Data providers { rssiStore, edgeLogger, nodeLogger }
   * @returns {object} - Snapshot data
   */
  takeSnapshot(providers) {
    if (!this.isEnabled) return null;

    const { rssiStore, edgeLogger, nodeLogger } = providers;

    const snapshot = this._buildSnapshot(rssiStore, edgeLogger, nodeLogger);

    // Save to file
    this._saveSnapshot(snapshot);

    this.snapshotCount++;
    return snapshot;
  }

  /**
   * Build snapshot data
   * @param {object} rssiStore
   * @param {object} edgeLogger
   * @param {object} nodeLogger
   * @returns {object}
   */
  _buildSnapshot(rssiStore, edgeLogger, nodeLogger) {
    const timestamp = new Date().toISOString();
    const sessionId = this.sessionManager?.getSessionId() ?? 'no-session';

    // Get nodes
    const nodes = nodeLogger ? nodeLogger.getActiveNodeIds() : (rssiStore?.getActiveUserIds() ?? []);

    // Get edges
    const edges = [];
    const adjacencyList = {};

    // Initialize adjacency list
    for (const node of nodes) {
      adjacencyList[node] = [];
    }

    if (edgeLogger) {
      // Use edge logger data
      for (const edge of edgeLogger.getCurrentEdges()) {
        const edgeData = {
          source: edge.nodeA,
          target: edge.nodeB,
          rssi_a_to_b: edge.rssiAtoB,
          rssi_b_to_a: edge.rssiBtoA,
          rssi_avg: (edge.rssiAtoB !== null && edge.rssiBtoA !== null)
            ? (edge.rssiAtoB + edge.rssiBtoA) / 2
            : (edge.rssiAtoB ?? edge.rssiBtoA),
          distance: this._rssiToDistance(
            (edge.rssiAtoB !== null && edge.rssiBtoA !== null)
              ? (edge.rssiAtoB + edge.rssiBtoA) / 2
              : (edge.rssiAtoB ?? edge.rssiBtoA ?? -100)
          ),
          mutual: edge.mutual,
          established_at: new Date(edge.establishedAt).toISOString(),
          last_update: new Date(edge.lastUpdate).toISOString()
        };

        edges.push(edgeData);

        // Update adjacency list
        if (adjacencyList[edge.nodeA]) {
          adjacencyList[edge.nodeA].push(edge.nodeB);
        }
        if (adjacencyList[edge.nodeB]) {
          adjacencyList[edge.nodeB].push(edge.nodeA);
        }
      }
    } else if (rssiStore) {
      // Fallback: build from RSSI store
      const userIds = rssiStore.getActiveUserIds();
      for (let i = 0; i < userIds.length; i++) {
        for (let j = i + 1; j < userIds.length; j++) {
          const rssi = rssiStore.getRSSIBetween(userIds[i], userIds[j]);
          if (rssi !== null) {
            const aData = rssiStore.getUserRSSIData(userIds[i]);
            const bData = rssiStore.getUserRSSIData(userIds[j]);

            const rssiAtoB = aData?.get(userIds[j])?.rssi ?? null;
            const rssiBtoA = bData?.get(userIds[i])?.rssi ?? null;

            edges.push({
              source: userIds[i],
              target: userIds[j],
              rssi_a_to_b: rssiAtoB,
              rssi_b_to_a: rssiBtoA,
              rssi_avg: rssi,
              distance: this._rssiToDistance(rssi),
              mutual: rssiAtoB !== null && rssiBtoA !== null
            });

            adjacencyList[userIds[i]]?.push(userIds[j]);
            adjacencyList[userIds[j]]?.push(userIds[i]);
          }
        }
      }
    }

    // Calculate graph statistics
    const stats = this._calculateGraphStats(nodes, edges, adjacencyList);

    return {
      timestamp,
      session_id: sessionId,
      snapshot_id: `${sessionId}-${this.snapshotCount}`,
      nodes,
      node_count: nodes.length,
      edges,
      edge_count: edges.length,
      mutual_edge_count: edges.filter(e => e.mutual).length,
      adjacency_list: adjacencyList,
      statistics: stats
    };
  }

  /**
   * Calculate graph statistics
   * @param {Array} nodes
   * @param {Array} edges
   * @param {object} adjacencyList
   * @returns {object}
   */
  _calculateGraphStats(nodes, edges, adjacencyList) {
    const nodeCount = nodes.length;
    const edgeCount = edges.length;
    const mutualEdgeCount = edges.filter(e => e.mutual).length;

    // Graph density: actual edges / possible edges
    const maxEdges = (nodeCount * (nodeCount - 1)) / 2;
    const density = maxEdges > 0 ? edgeCount / maxEdges : 0;

    // Average RSSI
    const rssiValues = edges.map(e => e.rssi_avg).filter(r => r !== null);
    const avgRssi = rssiValues.length > 0
      ? rssiValues.reduce((a, b) => a + b, 0) / rssiValues.length
      : null;

    // Average distance
    const distances = edges.map(e => e.distance).filter(d => d !== null && isFinite(d));
    const avgDistance = distances.length > 0
      ? distances.reduce((a, b) => a + b, 0) / distances.length
      : null;

    // Degree statistics
    const degrees = nodes.map(n => adjacencyList[n]?.length ?? 0);
    const avgDegree = degrees.length > 0
      ? degrees.reduce((a, b) => a + b, 0) / degrees.length
      : 0;
    const maxDegree = Math.max(0, ...degrees);
    const minDegree = degrees.length > 0 ? Math.min(...degrees) : 0;

    // Connected components (simple BFS)
    const connectedComponents = this._countConnectedComponents(nodes, adjacencyList);

    return {
      density: parseFloat(density.toFixed(4)),
      avg_rssi: avgRssi !== null ? parseFloat(avgRssi.toFixed(2)) : null,
      avg_distance: avgDistance !== null ? parseFloat(avgDistance.toFixed(3)) : null,
      avg_degree: parseFloat(avgDegree.toFixed(2)),
      max_degree: maxDegree,
      min_degree: minDegree,
      connected_components: connectedComponents,
      is_connected: connectedComponents === 1 && nodeCount > 0
    };
  }

  /**
   * Count connected components using BFS
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

      // BFS
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
    if (rssi === null || rssi === undefined) return null;
    const txPower = -59;
    const n = 2.5;
    return Math.pow(10, (txPower - rssi) / (10 * n));
  }

  /**
   * Save snapshot to file (JSONL format - one JSON per line)
   * @param {object} snapshot
   */
  _saveSnapshot(snapshot) {
    if (!this.writeStream) {
      this._initLogFile();
    }

    // Write as single line JSON (JSONL format)
    const line = JSON.stringify(snapshot) + '\n';
    this.writeStream.write(line);
    console.log(`Graph Snapshot: Appended snapshot #${this.snapshotCount} to ${path.basename(this.currentLogFile)}`);
  }

  /**
   * Get all snapshot log files (JSONL format)
   * @returns {Array}
   */
  getSnapshotFiles() {
    if (!fs.existsSync(this.snapshotDir)) {
      return [];
    }

    return fs.readdirSync(this.snapshotDir)
      .filter(f => f.startsWith('snapshots_') && f.endsWith('.jsonl'))
      .map(filename => {
        const filePath = path.join(this.snapshotDir, filename);
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
   * Get all snapshots from a log file
   * @param {string} filename
   * @returns {Array|null}
   */
  getSnapshotsFromFile(filename) {
    const filePath = path.join(this.snapshotDir, filename);
    if (!fs.existsSync(filePath)) {
      return null;
    }

    try {
      const content = fs.readFileSync(filePath, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line.length > 0);
      return lines.map(line => JSON.parse(line));
    } catch {
      return null;
    }
  }

  /**
   * Get snapshot content (legacy compatibility - returns single snapshot or array)
   * @param {string} filename
   * @returns {object|Array|null}
   */
  getSnapshot(filename) {
    // Handle legacy .json files
    if (filename.endsWith('.json')) {
      const filePath = path.join(this.snapshotDir, filename);
      if (!fs.existsSync(filePath)) {
        return null;
      }
      try {
        const content = fs.readFileSync(filePath, 'utf-8');
        return JSON.parse(content);
      } catch {
        return null;
      }
    }

    // Handle new .jsonl files
    return this.getSnapshotsFromFile(filename);
  }

  /**
   * Get latest snapshot from current log file
   * @returns {object|null}
   */
  getLatestSnapshot() {
    if (!this.currentLogFile || !fs.existsSync(this.currentLogFile)) {
      const files = this.getSnapshotFiles();
      if (files.length === 0) return null;
      const snapshots = this.getSnapshotsFromFile(files[0].filename);
      return snapshots && snapshots.length > 0 ? snapshots[snapshots.length - 1] : null;
    }

    try {
      const content = fs.readFileSync(this.currentLogFile, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line.length > 0);
      if (lines.length === 0) return null;
      return JSON.parse(lines[lines.length - 1]);
    } catch {
      return null;
    }
  }

  /**
   * Delete old snapshot files, keeping only the latest N
   * @param {number} keepCount
   * @returns {number} - Number of deleted files
   */
  cleanupOldSnapshots(keepCount = 10) {
    const files = this.getSnapshotFiles();
    let deleted = 0;

    for (let i = keepCount; i < files.length; i++) {
      fs.unlinkSync(files[i].path);
      deleted++;
    }

    return deleted;
  }

  /**
   * Get stats
   * @returns {object}
   */
  getStats() {
    return {
      enabled: this.isEnabled,
      snapshotCount: this.snapshotCount,
      periodicActive: this.snapshotInterval !== null,
      snapshotDir: this.snapshotDir,
      totalFiles: this.getSnapshotFiles().length
    };
  }

  /**
   * Enable/disable
   * @param {boolean} enabled
   */
  setEnabled(enabled) {
    this.isEnabled = enabled;
    console.log(`Graph Snapshot: ${enabled ? 'Enabled' : 'Disabled'}`);
  }

  /**
   * Rotate log file (start a new file)
   */
  rotateLogFile() {
    this._initLogFile();
  }

  /**
   * Cleanup
   */
  destroy() {
    this.stopPeriodicSnapshots();
    if (this.writeStream) {
      this.writeStream.end();
      this.writeStream = null;
    }
  }
}
