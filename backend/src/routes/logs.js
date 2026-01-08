import { Router } from 'express';

/**
 * Logs API router
 * @param {import('../services/rssi-logger.js').RSSILogger} rssiLogger
 */
export function logsRouter(rssiLogger) {
  const router = Router();

  /**
   * GET /api/logs
   * List all log files
   */
  router.get('/', (req, res) => {
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
   * GET /api/logs/:filename
   * Download a specific log file
   */
  router.get('/:filename', (req, res) => {
    const { filename } = req.params;

    // Security: prevent path traversal
    if (filename.includes('..') || filename.includes('/')) {
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

  /**
   * POST /api/logs/rotate
   * Start a new log file
   */
  router.post('/rotate', (req, res) => {
    rssiLogger.rotateLog();
    res.json({
      message: 'Log rotated',
      newFile: rssiLogger.getCurrentLogFile()
    });
  });

  /**
   * POST /api/logs/enable
   * Enable logging
   */
  router.post('/enable', (req, res) => {
    rssiLogger.setEnabled(true);
    res.json({ enabled: true });
  });

  /**
   * POST /api/logs/disable
   * Disable logging
   */
  router.post('/disable', (req, res) => {
    rssiLogger.setEnabled(false);
    res.json({ enabled: false });
  });

  /**
   * DELETE /api/logs/:filename
   * Delete a specific log file
   */
  router.delete('/:filename', (req, res) => {
    const { filename } = req.params;

    // Security: prevent path traversal
    if (filename.includes('..') || filename.includes('/')) {
      return res.status(400).json({ error: 'Invalid filename' });
    }

    const deleted = rssiLogger.deleteLogFile(filename);
    if (!deleted) {
      return res.status(400).json({ error: 'Cannot delete file (not found or is current log)' });
    }

    res.json({ deleted: true, filename });
  });

  /**
   * DELETE /api/logs
   * Delete all old log files (except current)
   */
  router.delete('/', (req, res) => {
    const count = rssiLogger.clearOldLogs();
    res.json({ deleted: count });
  });

  return router;
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
