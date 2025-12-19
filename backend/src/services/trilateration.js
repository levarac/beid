/**
 * Trilateration service using MDS (Multidimensional Scaling)
 * Calculates 2D positions from distance matrix
 */
export class TrilaterationService {
  /**
   * Calculate 2D positions from distance matrix using Classical MDS
   * @param {{userIds: string[], distances: number[][]}} distanceMatrix - Distance matrix
   * @returns {{userId: string, x: number, y: number}[]|null} - 2D positions or null if calculation fails
   */
  calculatePositions(distanceMatrix) {
    const { userIds, distances } = distanceMatrix;
    const n = userIds.length;

    if (n < 3) {
      return null; // Need at least 3 points for 2D positioning
    }

    // Check for Infinity values (missing connections)
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) {
        if (distances[i][j] === Infinity) {
          // Replace Infinity with estimated value based on other distances
          distances[i][j] = this.estimateMissingDistance(distances, i, j);
        }
      }
    }

    try {
      // Step 1: Square the distance matrix
      const D2 = distances.map(row => row.map(d => d * d));

      // Step 2: Double centering to get Gram matrix B
      const B = this.doubleCentering(D2);

      // Step 3: Eigenvalue decomposition
      const { eigenvalues, eigenvectors } = this.eigenDecomposition(B);

      // Step 4: Extract 2D coordinates using top 2 eigenvalues
      const positions = [];
      for (let i = 0; i < n; i++) {
        positions.push({
          userId: userIds[i],
          x: eigenvectors[i][0] * Math.sqrt(Math.max(0, eigenvalues[0])),
          y: eigenvectors[i][1] * Math.sqrt(Math.max(0, eigenvalues[1]))
        });
      }

      // Normalize positions to fit within unit circle
      return this.normalizePositions(positions);
    } catch (error) {
      console.error('Trilateration calculation failed:', error);
      return null;
    }
  }

  /**
   * Double centering transformation: B = -0.5 * J * D^2 * J
   * where J = I - (1/n) * 1 * 1^T (centering matrix)
   */
  doubleCentering(D2) {
    const n = D2.length;
    const B = [];

    // Calculate row means, column means, and grand mean
    const rowMeans = [];
    const colMeans = [];
    let grandMean = 0;

    for (let i = 0; i < n; i++) {
      let rowSum = 0;
      for (let j = 0; j < n; j++) {
        rowSum += D2[i][j];
      }
      rowMeans[i] = rowSum / n;
      grandMean += rowSum;
    }
    grandMean /= (n * n);

    for (let j = 0; j < n; j++) {
      let colSum = 0;
      for (let i = 0; i < n; i++) {
        colSum += D2[i][j];
      }
      colMeans[j] = colSum / n;
    }

    // Apply double centering: B_ij = -0.5 * (D2_ij - rowMean_i - colMean_j + grandMean)
    for (let i = 0; i < n; i++) {
      B[i] = [];
      for (let j = 0; j < n; j++) {
        B[i][j] = -0.5 * (D2[i][j] - rowMeans[i] - colMeans[j] + grandMean);
      }
    }

    return B;
  }

  /**
   * Simple power iteration for eigenvalue decomposition (first 2 eigenvalues/vectors)
   * For production, consider using a proper linear algebra library
   */
  eigenDecomposition(B) {
    const n = B.length;
    const numIterations = 100;
    const tolerance = 1e-10;

    const eigenvalues = [];
    const eigenvectors = [];

    // Create a copy of B to deflate
    const A = B.map(row => [...row]);

    for (let k = 0; k < 2; k++) {
      // Initialize random vector
      let v = new Array(n).fill(0).map(() => Math.random() - 0.5);
      let lambda = 0;

      // Power iteration
      for (let iter = 0; iter < numIterations; iter++) {
        // Multiply A * v
        const Av = new Array(n).fill(0);
        for (let i = 0; i < n; i++) {
          for (let j = 0; j < n; j++) {
            Av[i] += A[i][j] * v[j];
          }
        }

        // Calculate eigenvalue (Rayleigh quotient)
        let vAv = 0;
        let vv = 0;
        for (let i = 0; i < n; i++) {
          vAv += v[i] * Av[i];
          vv += v[i] * v[i];
        }
        const newLambda = vAv / vv;

        // Normalize
        const norm = Math.sqrt(Av.reduce((sum, x) => sum + x * x, 0));
        if (norm < tolerance) break;

        v = Av.map(x => x / norm);

        if (Math.abs(newLambda - lambda) < tolerance) break;
        lambda = newLambda;
      }

      eigenvalues.push(lambda);

      // Store eigenvector components for each user
      for (let i = 0; i < n; i++) {
        if (!eigenvectors[i]) eigenvectors[i] = [];
        eigenvectors[i][k] = v[i];
      }

      // Deflate matrix: A = A - lambda * v * v^T
      for (let i = 0; i < n; i++) {
        for (let j = 0; j < n; j++) {
          A[i][j] -= lambda * v[i] * v[j];
        }
      }
    }

    return { eigenvalues, eigenvectors };
  }

  /**
   * Normalize positions to fit within unit circle
   */
  normalizePositions(positions) {
    if (positions.length === 0) return positions;

    // Find max distance from origin
    let maxDist = 0;
    for (const pos of positions) {
      const dist = Math.sqrt(pos.x * pos.x + pos.y * pos.y);
      if (dist > maxDist) maxDist = dist;
    }

    if (maxDist < 1e-10) return positions;

    // Scale to unit circle
    return positions.map(pos => ({
      userId: pos.userId,
      x: pos.x / maxDist,
      y: pos.y / maxDist
    }));
  }

  /**
   * Calculate relative angles from a viewer's perspective
   * @param {{userId: string, x: number, y: number}[]} positions - 2D positions
   * @param {string} viewerUserId - The viewer's user ID
   * @returns {{targetUserId: string, angle: number, distance: number}[]} - Relative positions
   */
  calculateRelativeAngles(positions, viewerUserId) {
    const viewer = positions.find(p => p.userId === viewerUserId);
    if (!viewer) return [];

    return positions
      .filter(p => p.userId !== viewerUserId)
      .map(target => {
        const dx = target.x - viewer.x;
        const dy = target.y - viewer.y;
        const distance = Math.sqrt(dx * dx + dy * dy);

        // Calculate angle (0 = right, 90 = up, counterclockwise)
        let angle = Math.atan2(dy, dx) * (180 / Math.PI);
        if (angle < 0) angle += 360;

        return {
          targetUserId: target.userId,
          angle: angle,
          distance: Math.min(distance, 1) // Clamp to 1
        };
      });
  }

  /**
   * Estimate missing distance based on available data
   */
  estimateMissingDistance(distances, i, j) {
    const n = distances.length;
    let sum = 0;
    let count = 0;

    // Try to find a path through other nodes
    for (let k = 0; k < n; k++) {
      if (k !== i && k !== j) {
        if (distances[i][k] !== Infinity && distances[k][j] !== Infinity) {
          sum += distances[i][k] + distances[k][j];
          count++;
        }
      }
    }

    if (count > 0) {
      return sum / count; // Average of shortest paths through other nodes
    }

    // Fallback: use maximum known distance
    let maxDist = 0;
    for (let a = 0; a < n; a++) {
      for (let b = 0; b < n; b++) {
        if (distances[a][b] !== Infinity && distances[a][b] > maxDist) {
          maxDist = distances[a][b];
        }
      }
    }
    return maxDist > 0 ? maxDist * 1.5 : 1;
  }
}
