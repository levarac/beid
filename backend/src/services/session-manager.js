import { randomBytes } from 'crypto';

/**
 * Session manager for tracking sensing sessions
 */
export class SessionManager {
  constructor() {
    this.currentSession = null;
    this.sessionHistory = [];
  }

  /**
   * Start a new session
   * @returns {object} Session info
   */
  startSession() {
    if (this.currentSession) {
      this.endSession();
    }

    this.currentSession = {
      id: this._generateSessionId(),
      startedAt: new Date().toISOString(),
      endedAt: null,
      nodeCount: 0,
      edgeCount: 0,
      reportCount: 0
    };

    console.log(`Session started: ${this.currentSession.id}`);
    return this.currentSession;
  }

  /**
   * End current session
   * @returns {object|null} Ended session info
   */
  endSession() {
    if (!this.currentSession) {
      return null;
    }

    this.currentSession.endedAt = new Date().toISOString();
    this.sessionHistory.push({ ...this.currentSession });

    const ended = this.currentSession;
    console.log(`Session ended: ${ended.id}`);

    this.currentSession = null;
    return ended;
  }

  /**
   * Get current session ID (auto-start if none)
   * @returns {string} Session ID
   */
  getSessionId() {
    if (!this.currentSession) {
      this.startSession();
    }
    return this.currentSession.id;
  }

  /**
   * Get current session info
   * @returns {object|null} Current session
   */
  getCurrentSession() {
    return this.currentSession;
  }

  /**
   * Update session stats
   * @param {object} stats - Stats to update
   */
  updateStats(stats) {
    if (!this.currentSession) return;

    if (stats.nodeCount !== undefined) {
      this.currentSession.nodeCount = stats.nodeCount;
    }
    if (stats.edgeCount !== undefined) {
      this.currentSession.edgeCount = stats.edgeCount;
    }
    if (stats.reportCount !== undefined) {
      this.currentSession.reportCount = stats.reportCount;
    }
  }

  /**
   * Increment report count
   */
  incrementReportCount() {
    if (this.currentSession) {
      this.currentSession.reportCount++;
    }
  }

  /**
   * Get session history
   * @returns {Array} Session history
   */
  getHistory() {
    return this.sessionHistory;
  }

  /**
   * Generate unique session ID
   * @returns {string} Session ID
   */
  _generateSessionId() {
    const timestamp = Date.now().toString(36);
    const random = randomBytes(4).toString('hex');
    return `${timestamp}-${random}`;
  }
}
