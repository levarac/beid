import fs from 'fs';
import path from 'path';

/**
 * RSSI data logger - saves all incoming RSSI data to CSV files
 */
export class RSSILogger {
  constructor(logDir = './logs') {
    this.logDir = logDir;
    this.currentLogFile = null;
    this.writeStream = null;
    this.isEnabled = true;
    this.rowCount = 0;

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

    // Write CSV header
    this.writeStream.write('timestamp,reporter_id,detected_id,rssi,heading\n');
    this.rowCount = 0;

    console.log(`RSSI Logger: Started new log file: ${this.currentLogFile}`);
  }

  /**
   * Log RSSI report from a user
   * @param {string} reporterId - The user who reported the data
   * @param {Array<{userId: string, rssi: number, timestamp: string}>} detectedUsers - Detected users
   * @param {number|null} heading - Compass heading
   */
  logRSSIReport(reporterId, detectedUsers, heading = null) {
    if (!this.isEnabled || !this.writeStream) return;

    const now = new Date().toISOString();

    for (const detected of detectedUsers) {
      const row = [
        now,
        reporterId,
        detected.userId,
        detected.rssi,
        heading ?? ''
      ].join(',');

      this.writeStream.write(row + '\n');
      this.rowCount++;
    }
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
      .filter(f => f.endsWith('.csv'))
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
      files: this.getLogFiles().length
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
