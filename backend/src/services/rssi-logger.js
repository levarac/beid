import fs from 'fs';
import path from 'path';

/**
 * Extended RSSI data logger - saves all incoming RSSI data to CSV files
 * with additional fields for graph construction
 */
export class RSSILogger {
  constructor(logDir = './logs', sessionManager = null) {
    this.logDir = logDir;
    this.sessionManager = sessionManager;
    this.currentLogFile = null;
    this.writeStream = null;
    this.isEnabled = true;
    this.rowCount = 0;
    this.reportSeq = 0;

    // Track mutual detection state
    this.mutualDetectionState = new Map(); // "nodeA:nodeB" -> boolean

    // Ensure log directory exists
    if (!fs.existsSync(this.logDir)) {
      fs.mkdirSync(this.logDir, { recursive: true });
    }

    // Start a new log file
    this._startNewLogFile();
  }

  /**
   * Start a new log file with timestamp
   */
  _startNewLogFile() {
    if (this.writeStream) {
      this.writeStream.end();
    }

    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').split('T')[0];
    const filename = `rssi_log_${timestamp}_${Date.now()}.csv`;
    this.currentLogFile = path.join(this.logDir, filename);

    this.writeStream = fs.createWriteStream(this.currentLogFile, { flags: 'a' });

    // Write extended CSV header
    const headers = [
      'timestamp',
      'session_id',
      'report_seq',
      'reporter_id',
      'detected_id',
      'resolved_display_id',
      'rssi',
      'heading',
      'distance_estimate',
      'tx_power',
      'signal_quality',
      'is_mutual',
      'is_same_event',
      'event_code'
    ];
    this.writeStream.write(headers.join(',') + '\n');
    this.rowCount = 0;
    this.reportSeq = 0;

    console.log(`RSSI Logger: Started new log file: ${this.currentLogFile}`);
  }

  /**
   * Log RSSI report from a user with extended fields
   * @param {string} reporterId - The user who reported the data
   * @param {Array<{userId: string, rssi: number, timestamp: string}>} detectedUsers - Detected users
   * @param {number|null} heading - Compass heading
   * @param {object} options - Additional options
   */
  logRSSIReport(reporterId, detectedUsers, heading = null, options = {}) {
    if (!this.isEnabled || !this.writeStream) return;

    const now = new Date().toISOString();
    const sessionId = this.sessionManager?.getSessionId() ?? 'no-session';
    this.reportSeq++;

    const {
      txPower = -59,  // Default reference power
      rssiStore = null,
      eventCode = null
    } = options;

    for (const detected of detectedUsers) {
      // Calculate distance estimate
      const distanceEstimate = this._rssiToDistance(detected.rssi, txPower);

      // Check if mutual detection exists
      const isMutual = this._checkMutualDetection(reporterId, detected.userId, rssiStore);

      // Calculate signal quality (placeholder - could be enhanced with historical data)
      const signalQuality = this._calculateSignalQuality(detected.rssi);

      // Check if same event (resolvedDisplayId is only set when in same event)
      const isSameEvent = detected.isResolved === true || detected.resolvedDisplayId != null;

      const row = [
        now,
        sessionId,
        this.reportSeq,
        reporterId,
        detected.userId,
        detected.resolvedDisplayId ?? '',
        detected.rssi,
        heading ?? '',
        distanceEstimate.toFixed(3),
        txPower,
        signalQuality.toFixed(2),
        isMutual,
        isSameEvent,
        eventCode ?? ''
      ].join(',');

      this.writeStream.write(row + '\n');
      this.rowCount++;
    }
  }

  /**
   * Convert RSSI to distance using log-distance path loss model
   * @param {number} rssi - RSSI value in dBm
   * @param {number} txPower - Reference RSSI at 1 meter
   * @returns {number} - Estimated distance in meters
   */
  _rssiToDistance(rssi, txPower = -59) {
    const n = 2.5; // Path loss exponent
    return Math.pow(10, (txPower - rssi) / (10 * n));
  }

  /**
   * Calculate signal quality score (0-1)
   * @param {number} rssi - RSSI value
   * @returns {number} - Quality score
   */
  _calculateSignalQuality(rssi) {
    // Simple quality based on RSSI strength
    // -40 dBm = excellent (1.0), -100 dBm = poor (0.0)
    const normalized = Math.max(0, Math.min(1, (rssi + 100) / 60));
    return normalized;
  }

  /**
   * Check if mutual detection exists between two nodes
   * @param {string} nodeA - First node ID
   * @param {string} nodeB - Second node ID
   * @param {object} rssiStore - RSSI store reference
   * @returns {boolean} - Whether mutual detection exists
   */
  _checkMutualDetection(nodeA, nodeB, rssiStore) {
    if (!rssiStore) return false;

    // Check if nodeB has also detected nodeA
    const nodeAData = rssiStore.getUserRSSIData(nodeA);
    const nodeBData = rssiStore.getUserRSSIData(nodeB);

    const aDetectsB = nodeAData?.has(nodeB) ?? false;
    const bDetectsA = nodeBData?.has(nodeA) ?? false;

    return aDetectsB && bDetectsA;
  }

  /**
   * Update mutual detection state
   * @param {string} nodeA - First node
   * @param {string} nodeB - Second node
   * @param {boolean} isMutual - Whether detection is mutual
   */
  updateMutualState(nodeA, nodeB, isMutual) {
    const key = [nodeA, nodeB].sort().join(':');
    this.mutualDetectionState.set(key, isMutual);
  }

  /**
   * Get mutual detection state
   * @param {string} nodeA - First node
   * @param {string} nodeB - Second node
   * @returns {boolean} - Mutual state
   */
  getMutualState(nodeA, nodeB) {
    const key = [nodeA, nodeB].sort().join(':');
    return this.mutualDetectionState.get(key) ?? false;
  }

  /**
   * Get current log file path
   * @returns {string|null}
   */
  getCurrentLogFile() {
    return this.currentLogFile;
  }

  /**
   * Get all log files
   * @returns {Array<{filename: string, path: string, size: number, created: Date}>}
   */
  getLogFiles() {
    if (!fs.existsSync(this.logDir)) {
      return [];
    }

    const files = fs.readdirSync(this.logDir)
      .filter(f => f.startsWith('rssi_log_') && f.endsWith('.csv'))
      .map(filename => {
        const filePath = path.join(this.logDir, filename);
        const stats = fs.statSync(filePath);
        return {
          filename,
          path: filePath,
          size: stats.size,
          created: stats.birthtime,
          rows: this._countRows(filePath)
        };
      })
      .sort((a, b) => b.created - a.created);

    return files;
  }

  /**
   * Count rows in a CSV file (excluding header)
   */
  _countRows(filePath) {
    try {
      const content = fs.readFileSync(filePath, 'utf-8');
      return content.split('\n').length - 2; // Subtract header and trailing newline
    } catch {
      return 0;
    }
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
   * Delete a log file
   * @param {string} filename
   * @returns {boolean}
   */
  deleteLogFile(filename) {
    const filePath = path.join(this.logDir, filename);
    if (!fs.existsSync(filePath)) {
      return false;
    }

    // Don't delete current active log
    if (filePath === this.currentLogFile) {
      return false;
    }

    fs.unlinkSync(filePath);
    return true;
  }

  /**
   * Delete all log files except current
   */
  clearOldLogs() {
    const files = this.getLogFiles();
    let deleted = 0;

    for (const file of files) {
      if (file.path !== this.currentLogFile) {
        fs.unlinkSync(file.path);
        deleted++;
      }
    }

    return deleted;
  }

  /**
   * Get current stats
   */
  getStats() {
    return {
      enabled: this.isEnabled,
      currentFile: this.currentLogFile,
      rowCount: this.rowCount,
      reportSeq: this.reportSeq,
      files: this.getLogFiles().length,
      mutualPairs: this.mutualDetectionState.size
    };
  }

  /**
   * Enable/disable logging
   */
  setEnabled(enabled) {
    this.isEnabled = enabled;
    console.log(`RSSI Logger: ${enabled ? 'Enabled' : 'Disabled'}`);
  }

  /**
   * Start a fresh log file
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
