import fs from 'fs';
import path from 'path';

/**
 * Node event logger - tracks node join/leave events in the graph
 */
export class NodeLogger {
  constructor(logDir = './logs', sessionManager = null) {
    this.logDir = logDir;
    this.sessionManager = sessionManager;
    this.currentLogFile = null;
    this.writeStream = null;
    this.isEnabled = true;
    this.eventCount = 0;

    // Track active nodes: nodeId -> { joinedAt, metadata }
    this.activeNodes = new Map();

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
    const filename = `node_events_${timestamp}_${Date.now()}.csv`;
    this.currentLogFile = path.join(this.logDir, filename);

    this.writeStream = fs.createWriteStream(this.currentLogFile, { flags: 'a' });

    // Write CSV header
    const headers = [
      'timestamp',
      'session_id',
      'event_type',
      'node_id',
      'device_type',
      'session_duration_ms',
      'total_reports',
      'metadata'
    ];
    this.writeStream.write(headers.join(',') + '\n');
    this.eventCount = 0;

    console.log(`Node Logger: Started new log file: ${this.currentLogFile}`);
  }

  /**
   * Log node joined event
   * @param {string} nodeId - Node ID
   * @param {object} metadata - Additional metadata
   */
  logNodeJoined(nodeId, metadata = {}) {
    const now = Date.now();

    // Track node
    this.activeNodes.set(nodeId, {
      joinedAt: now,
      reportCount: 0,
      metadata: metadata
    });

    this._logEvent('node_joined', nodeId, metadata, null, 0);
  }

  /**
   * Log node left event
   * @param {string} nodeId - Node ID
   */
  logNodeLeft(nodeId) {
    const nodeData = this.activeNodes.get(nodeId);
    if (!nodeData) return;

    const now = Date.now();
    const duration = now - nodeData.joinedAt;

    this._logEvent('node_left', nodeId, nodeData.metadata, duration, nodeData.reportCount);

    this.activeNodes.delete(nodeId);
  }

  /**
   * Update node metadata
   * @param {string} nodeId - Node ID
   * @param {object} metadata - New metadata
   */
  updateNodeMetadata(nodeId, metadata) {
    const nodeData = this.activeNodes.get(nodeId);
    if (nodeData) {
      nodeData.metadata = { ...nodeData.metadata, ...metadata };
      this._logEvent('node_updated', nodeId, nodeData.metadata, null, nodeData.reportCount);
    }
  }

  /**
   * Increment report count for a node
   * @param {string} nodeId - Node ID
   */
  incrementReportCount(nodeId) {
    const nodeData = this.activeNodes.get(nodeId);
    if (nodeData) {
      nodeData.reportCount++;
    }
  }

  /**
   * Log an event
   * @param {string} eventType - Event type
   * @param {string} nodeId - Node ID
   * @param {object} metadata - Metadata
   * @param {number|null} duration - Session duration
   * @param {number} reportCount - Report count
   */
  _logEvent(eventType, nodeId, metadata, duration, reportCount) {
    if (!this.isEnabled || !this.writeStream) return;

    const now = new Date().toISOString();
    const sessionId = this.sessionManager?.getSessionId() ?? 'no-session';

    // Escape metadata for CSV
    const metadataStr = JSON.stringify(metadata || {}).replace(/,/g, ';').replace(/"/g, "'");

    const row = [
      now,
      sessionId,
      eventType,
      nodeId,
      metadata.deviceType ?? 'unknown',
      duration ?? '',
      reportCount,
      metadataStr
    ].join(',');

    this.writeStream.write(row + '\n');
    this.eventCount++;
  }

  /**
   * Get active node count
   * @returns {number}
   */
  getActiveNodeCount() {
    return this.activeNodes.size;
  }

  /**
   * Get active node IDs
   * @returns {Array<string>}
   */
  getActiveNodeIds() {
    return Array.from(this.activeNodes.keys());
  }

  /**
   * Get node data
   * @param {string} nodeId
   * @returns {object|null}
   */
  getNodeData(nodeId) {
    return this.activeNodes.get(nodeId) || null;
  }

  /**
   * Get all active nodes data
   * @returns {Array}
   */
  getAllNodesData() {
    const result = [];
    for (const [nodeId, data] of this.activeNodes.entries()) {
      result.push({
        nodeId,
        joinedAt: new Date(data.joinedAt).toISOString(),
        reportCount: data.reportCount,
        metadata: data.metadata
      });
    }
    return result;
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
      .filter(f => f.startsWith('node_events_') && f.endsWith('.csv'))
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
      activeNodes: this.activeNodes.size
    };
  }

  /**
   * Enable/disable logging
   * @param {boolean} enabled
   */
  setEnabled(enabled) {
    this.isEnabled = enabled;
    console.log(`Node Logger: ${enabled ? 'Enabled' : 'Disabled'}`);
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
    if (this.writeStream) {
      this.writeStream.end();
      this.writeStream = null;
    }
  }
}
