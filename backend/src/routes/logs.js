import { Router } from 'express';

/**
 * Extended Logs API router
 * @param {object} loggers - All logging services
 */
export function logsRouter(loggers) {
  const router = Router();
  const { rssiLogger, edgeLogger, nodeLogger, graphSnapshot, statsLogger, sessionManager } = loggers;

  /**
   * GET /api/logs
   * List all log files from all loggers
   */
  router.get('/', (req, res) => {
    res.json({
      session: sessionManager?.getCurrentSession() ?? null,
      rssi: {
        enabled: rssiLogger.isEnabled,
        currentFile: rssiLogger.currentLogFile,
        stats: rssiLogger.getStats(),
        files: rssiLogger.getLogFiles().map(f => ({
          filename: f.filename,
          size: f.size,
          sizeFormatted: formatBytes(f.size),
          rows: f.rows,
          created: f.created.toISOString()
        }))
      },
      edges: {
        enabled: edgeLogger.isEnabled,
        stats: edgeLogger.getStats(),
        files: edgeLogger.getLogFiles().map(f => ({
          filename: f.filename,
          size: f.size,
          sizeFormatted: formatBytes(f.size),
          created: f.created.toISOString()
        }))
      },
      nodes: {
        enabled: nodeLogger.isEnabled,
        stats: nodeLogger.getStats(),
        files: nodeLogger.getLogFiles().map(f => ({
          filename: f.filename,
          size: f.size,
          sizeFormatted: formatBytes(f.size),
          created: f.created.toISOString()
        }))
      },
      stats: {
        enabled: statsLogger.isEnabled,
        stats: statsLogger.getStats(),
        files: statsLogger.getLogFiles().map(f => ({
          filename: f.filename,
          size: f.size,
          sizeFormatted: formatBytes(f.size),
          created: f.created.toISOString()
        }))
      },
      snapshots: {
        stats: graphSnapshot.getStats(),
        files: graphSnapshot.getSnapshotFiles().map(f => ({
          filename: f.filename,
          size: f.size,
          sizeFormatted: formatBytes(f.size),
          created: f.created.toISOString()
        }))
      }
    });
  });

  // ===============================
  // RSSI Logs
  // ===============================

  /**
   * GET /api/logs/rssi
   * List RSSI log files
   */
  router.get('/rssi', (req, res) => {
    const files = rssiLogger.getLogFiles();
    const stats = rssiLogger.getStats();

    res.json({
      enabled: stats.enabled,
      currentFile: stats.currentFile,
      currentRowCount: stats.rowCount,
      files: files.map(f => ({
        filename: f.filename,
        size: f.size,
        sizeFormatted: formatBytes(f.size),
        rows: f.rows,
        created: f.created.toISOString()
      }))
    });
  });

  /**
   * GET /api/logs/rssi/:filename
   * Download a specific RSSI log file
   */
  router.get('/rssi/:filename', (req, res) => {
    const { filename } = req.params;
    if (!validateFilename(filename)) {
      return res.status(400).json({ error: 'Invalid filename' });
    }

    const content = rssiLogger.getLogContent(filename);
    if (!content) {
      return res.status(404).json({ error: 'File not found' });
    }

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.send(content);
  });

  // ===============================
  // Edge Logs
  // ===============================

  /**
   * GET /api/logs/edges
   * List edge event log files
   */
  router.get('/edges', (req, res) => {
    const files = edgeLogger.getLogFiles();
    const stats = edgeLogger.getStats();

    res.json({
      enabled: stats.enabled,
      currentEdges: stats.currentEdges,
      mutualEdges: stats.mutualEdges,
      eventCount: stats.eventCount,
      files: files.map(f => ({
        filename: f.filename,
        size: f.size,
        sizeFormatted: formatBytes(f.size),
        created: f.created.toISOString()
      }))
    });
  });

  /**
   * GET /api/logs/edges/:filename
   * Download a specific edge event log file
   */
  router.get('/edges/:filename', (req, res) => {
    const { filename } = req.params;
    if (!validateFilename(filename)) {
      return res.status(400).json({ error: 'Invalid filename' });
    }

    const content = edgeLogger.getLogContent(filename);
    if (!content) {
      return res.status(404).json({ error: 'File not found' });
    }

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.send(content);
  });

  // ===============================
  // Node Logs
  // ===============================

  /**
   * GET /api/logs/nodes
   * List node event log files
   */
  router.get('/nodes', (req, res) => {
    const files = nodeLogger.getLogFiles();
    const stats = nodeLogger.getStats();

    res.json({
      enabled: stats.enabled,
      activeNodes: stats.activeNodes,
      eventCount: stats.eventCount,
      files: files.map(f => ({
        filename: f.filename,
        size: f.size,
        sizeFormatted: formatBytes(f.size),
        created: f.created.toISOString()
      }))
    });
  });

  /**
   * GET /api/logs/nodes/:filename
   * Download a specific node event log file
   */
  router.get('/nodes/:filename', (req, res) => {
    const { filename } = req.params;
    if (!validateFilename(filename)) {
      return res.status(400).json({ error: 'Invalid filename' });
    }

    const content = nodeLogger.getLogContent(filename);
    if (!content) {
      return res.status(404).json({ error: 'File not found' });
    }

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.send(content);
  });

  // ===============================
  // Stats Logs
  // ===============================

  /**
   * GET /api/logs/stats
   * List stats log files
   */
  router.get('/stats', (req, res) => {
    const files = statsLogger.getLogFiles();
    const stats = statsLogger.getStats();

    res.json({
      enabled: stats.enabled,
      rowCount: stats.rowCount,
      periodicActive: stats.periodicActive,
      files: files.map(f => ({
        filename: f.filename,
        size: f.size,
        sizeFormatted: formatBytes(f.size),
        created: f.created.toISOString()
      }))
    });
  });

  /**
   * GET /api/logs/stats/:filename
   * Download a specific stats log file
   */
  router.get('/stats/:filename', (req, res) => {
    const { filename } = req.params;
    if (!validateFilename(filename)) {
      return res.status(400).json({ error: 'Invalid filename' });
    }

    const content = statsLogger.getLogContent(filename);
    if (!content) {
      return res.status(404).json({ error: 'File not found' });
    }

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.send(content);
  });

  // ===============================
  // Snapshots
  // ===============================

  /**
   * GET /api/logs/snapshots
   * List snapshot files
   */
  router.get('/snapshots', (req, res) => {
    const files = graphSnapshot.getSnapshotFiles();
    const stats = graphSnapshot.getStats();

    res.json({
      enabled: stats.enabled,
      snapshotCount: stats.snapshotCount,
      periodicActive: stats.periodicActive,
      files: files.map(f => ({
        filename: f.filename,
        size: f.size,
        sizeFormatted: formatBytes(f.size),
        created: f.created.toISOString()
      }))
    });
  });

  /**
   * GET /api/logs/snapshots/latest
   * Get the latest snapshot
   */
  router.get('/snapshots/latest', (req, res) => {
    const snapshot = graphSnapshot.getLatestSnapshot();
    if (!snapshot) {
      return res.status(404).json({ error: 'No snapshots available' });
    }
    res.json(snapshot);
  });

  /**
   * GET /api/logs/snapshots/:filename
   * Download a specific snapshot file
   */
  router.get('/snapshots/:filename', (req, res) => {
    const { filename } = req.params;
    if (!validateFilename(filename)) {
      return res.status(400).json({ error: 'Invalid filename' });
    }

    const snapshot = graphSnapshot.getSnapshot(filename);
    if (!snapshot) {
      return res.status(404).json({ error: 'File not found' });
    }

    res.json(snapshot);
  });

  // ===============================
  // Control Endpoints
  // ===============================

  /**
   * POST /api/logs/rotate
   * Rotate all log files
   */
  router.post('/rotate', (req, res) => {
    rssiLogger.rotateLog();
    edgeLogger.rotateLog();
    nodeLogger.rotateLog();
    statsLogger.rotateLog();
    graphSnapshot.rotateLogFile();

    res.json({
      message: 'All logs rotated',
      files: {
        rssi: rssiLogger.getCurrentLogFile(),
        edges: edgeLogger.currentLogFile,
        nodes: nodeLogger.currentLogFile,
        stats: statsLogger.currentLogFile,
        snapshots: graphSnapshot.currentLogFile
      }
    });
  });

  /**
   * POST /api/logs/enable
   * Enable all logging
   */
  router.post('/enable', (req, res) => {
    rssiLogger.setEnabled(true);
    edgeLogger.setEnabled(true);
    nodeLogger.setEnabled(true);
    statsLogger.setEnabled(true);
    graphSnapshot.setEnabled(true);

    res.json({ enabled: true, all: true });
  });

  /**
   * POST /api/logs/disable
   * Disable all logging
   */
  router.post('/disable', (req, res) => {
    rssiLogger.setEnabled(false);
    edgeLogger.setEnabled(false);
    nodeLogger.setEnabled(false);
    statsLogger.setEnabled(false);
    graphSnapshot.setEnabled(false);

    res.json({ enabled: false, all: true });
  });

  /**
   * POST /api/logs/cleanup
   * Clean up old snapshots
   */
  router.post('/cleanup', (req, res) => {
    const { keepCount = 100 } = req.body;
    const deleted = graphSnapshot.cleanupOldSnapshots(keepCount);

    res.json({ deleted, keepCount });
  });

  // ===============================
  // Legacy support (backwards compatibility)
  // ===============================

  /**
   * GET /api/logs/:filename (legacy - tries RSSI logs first)
   */
  router.get('/:filename', (req, res) => {
    const { filename } = req.params;
    if (!validateFilename(filename)) {
      return res.status(400).json({ error: 'Invalid filename' });
    }

    // Try RSSI logger first
    let content = rssiLogger.getLogContent(filename);
    if (content) {
      res.setHeader('Content-Type', 'text/csv');
      res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
      return res.send(content);
    }

    // Try edge logger
    content = edgeLogger.getLogContent(filename);
    if (content) {
      res.setHeader('Content-Type', 'text/csv');
      res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
      return res.send(content);
    }

    // Try node logger
    content = nodeLogger.getLogContent(filename);
    if (content) {
      res.setHeader('Content-Type', 'text/csv');
      res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
      return res.send(content);
    }

    // Try stats logger
    content = statsLogger.getLogContent(filename);
    if (content) {
      res.setHeader('Content-Type', 'text/csv');
      res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
      return res.send(content);
    }

    return res.status(404).json({ error: 'File not found' });
  });

  return router;
}

/**
 * Validate filename to prevent path traversal
 */
function validateFilename(filename) {
  return !filename.includes('..') && !filename.includes('/') && !filename.includes('\\');
}

/**
 * Format bytes to human readable string
 */
function formatBytes(bytes) {
  if (bytes === 0) return '0 Bytes';
  const k = 1024;
  const sizes = ['Bytes', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}
