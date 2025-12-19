import express from 'express';

const router = express.Router();

// In-memory store for sensing reports (for now)
const sensingReports = new Map();

/**
 * POST /api/sensing/report
 * Receive sensing report for POAP verification
 */
router.post('/report', (req, res) => {
  const { userUuid, walletAddress, partnerUuid, timestamp, rssi, signature } = req.body;

  // Validate required fields
  if (!userUuid || !walletAddress || !partnerUuid || !timestamp || rssi === undefined || !signature) {
    return res.status(400).json({
      error: 'Missing required fields'
    });
  }

  // Generate report ID
  const reportId = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

  // Store report
  const report = {
    reportId,
    userUuid,
    walletAddress,
    partnerUuid,
    timestamp,
    rssi,
    signature,
    status: 'pending',
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };

  sensingReports.set(reportId, report);

  // TODO: Implement signature verification with ethers.js
  // TODO: Implement partner report matching
  // TODO: Implement POAP API integration

  // For now, simulate async processing
  setTimeout(() => {
    const storedReport = sensingReports.get(reportId);
    if (storedReport) {
      // Check if partner has also submitted a report
      const partnerReport = findPartnerReport(storedReport);
      if (partnerReport) {
        storedReport.status = 'verified';
        partnerReport.status = 'verified';
        storedReport.updatedAt = new Date().toISOString();
        partnerReport.updatedAt = new Date().toISOString();

        // TODO: Trigger POAP issuance here
      }
    }
  }, 1000);

  res.json({
    reportId,
    status: 'pending',
    message: 'Report received, waiting for partner verification'
  });
});

/**
 * GET /api/sensing/status/:id
 * Get status of a sensing report
 */
router.get('/status/:id', (req, res) => {
  const { id } = req.params;

  const report = sensingReports.get(id);
  if (!report) {
    return res.status(404).json({
      error: 'Report not found'
    });
  }

  res.json({
    reportId: report.reportId,
    status: report.status,
    partnerAddress: report.partnerAddress,
    poapTxHash: report.poapTxHash,
    createdAt: report.createdAt,
    updatedAt: report.updatedAt
  });
});

/**
 * Find partner's report that matches the given report
 */
function findPartnerReport(report) {
  for (const [, otherReport] of sensingReports) {
    if (
      otherReport.userUuid === report.partnerUuid &&
      otherReport.partnerUuid === report.userUuid &&
      Math.abs(new Date(otherReport.timestamp) - new Date(report.timestamp)) < 5 * 60 * 1000 // 5 minutes
    ) {
      return otherReport;
    }
  }
  return null;
}

export { router as sensingRouter };
