#include <metal_stdlib>
using namespace metal;

struct FlowParams {
    uint count;
    uint bins;
    uint step;
    uint baseSeed;
    float radius;
    float lifDecay;
    float lifThreshold;
    float lifReset;
    float radialBias;
    float spikeKick;
    float gainSpikeKickScale;
    float noiseStdPos;
    float noiseStdDir;
    float maxSpeed;
    float energyAlpha;
    float energyFloor;
    float energySpikeGain;
    float energyGainBias;
    float energyCap;
    float finalWeightPower;
    uint gainsCount;
    uint threadsPerGroup;
    uint groupCount;
    // Weighted-aggregator parameters (used by training fast path only)
    uint aggEnabled;
    float aggSigmaR;
    float aggSigmaE;
    float aggAlpha;
    float aggBeta;
    float aggGamma;
    float aggTau;
    // Perf: when 0, do not write per-particle completion record buffers (only counters/aggregates).
    uint recordCompletions;
    // Perf: when 0, do not accumulate groupHistogram/histogram (bins output).
    uint recordHistogram;
};

static inline uint mix32(uint v) {
    uint z = v;
    z ^= z >> 16;
    z *= 0x85ebca6b;
    z ^= z >> 13;
    z *= 0xc2b2ae35;
    z ^= z >> 16;
    return z;
}

static inline float rand01(int id, uint step, uint salt, uint baseSeed) {
    uint x = uint(id);
    x *= 0x9E3779B9;
    x += step * 0x85ebca6b;
    x += salt + baseSeed;
    x = mix32(x);
    return float(x) / 4294967295.0f;
}

static inline float randUniform(int id, uint step, uint salt, uint baseSeed, float minVal, float maxVal) {
    return minVal + (maxVal - minVal) * rand01(id, step, salt, baseSeed);
}

static inline int binIndex(float theta, uint bins) {
    float twoPi = 6.283185307179586f;
    float t = theta;
    while (t < 0) { t += twoPi; }
    while (t >= twoPi) { t -= twoPi; }
    float x = t / twoPi;
    int idx = int(floor(x * float(bins)));
    return clamp(idx, 0, int(bins - 1));
}

kernel void flow_step(
    device const int *ids [[buffer(0)]],
    device float *posX [[buffer(1)]],
    device float *posY [[buffer(2)]],
    device float *velX [[buffer(3)]],
    device float *velY [[buffer(4)]],
    device float *energy [[buffer(5)]],
    device float *V [[buffer(6)]],
    device atomic_float *histogram [[buffer(7)]],
    device atomic_float *groupHistogram [[buffer(8)]],
    device int *projectedBin [[buffer(9)]],
    device uchar *spikedOut [[buffer(10)]],
    device uchar *alive [[buffer(11)]],
    device const float *gains [[buffer(12)]],
    constant FlowParams &p [[buffer(13)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= p.count) { return; }

    bool active = alive[gid] != 0;
    if (!active) {
        projectedBin[gid] = -1;
        spikedOut[gid] = 0;
        alive[gid] = 0;
        return;
    }

    int id = ids[gid];
    float px = posX[gid];
    float py = posY[gid];
    float vx = velX[gid];
    float vy = velY[gid];
    float e = energy[gid];
    float v = V[gid];

    float energyNorm = clamp(e / float(p.bins), 0.0f, 1.0f);
    float noiseDrive = (rand01(id, p.step, 1, p.baseSeed) - 0.5f) * 0.1f;
    float vUpdated = p.lifDecay * v + energyNorm + noiseDrive;
    bool spiked = false;
    if (vUpdated >= p.lifThreshold) {
        v = p.lifReset;
        spiked = true;
    } else {
        v = max(0.0f, vUpdated);
    }

    float len = sqrt(max(0.0f, px * px + py * py));
    float dirX = 0.0f;
    float dirY = 0.0f;
    if (len > 0.0f) {
        dirX = px / len;
        dirY = py / len;
    } else {
        float ang = randUniform(id, p.step, 2, p.baseSeed, 0.0f, 6.283185307179586f);
        dirX = cos(ang);
        dirY = sin(ang);
    }
    float gainFactor = 1.0f;
    if (p.gainsCount == p.bins) {
        float thetaGain = atan2(py, px);
        int gainBin = binIndex(thetaGain, p.bins);
        gainFactor = max(0.0f, gains[gainBin]);
    }

    vx += p.radialBias * dirX;
    vy += p.radialBias * dirY;

    float spikeKick = p.spikeKick;
    if (p.gainSpikeKickScale > 0.0f && p.gainsCount == p.bins) {
        float kickScale = 1.0f + p.gainSpikeKickScale * (gainFactor - 1.0f);
        kickScale = max(0.0f, kickScale);
        spikeKick *= kickScale;
    }

    if (spiked) {
        float jitterAng = randUniform(id, p.step, 3, p.baseSeed, -3.141592653589793f, 3.141592653589793f) * p.noiseStdDir;
        float rotX = cos(jitterAng);
        float rotY = sin(jitterAng);
        float kickX = dirX * rotX - dirY * rotY;
        float kickY = dirX * rotY + dirY * rotX;
        vx += spikeKick * kickX;
        vy += spikeKick * kickY;
    }

    float noiseAng = randUniform(id, p.step, 4, p.baseSeed, -3.141592653589793f, 3.141592653589793f);
    vx += cos(noiseAng) * p.noiseStdPos;
    vy += sin(noiseAng) * p.noiseStdPos;

    float speed = sqrt(max(0.0f, vx * vx + vy * vy));
    if (speed > p.maxSpeed && speed > 0.0f) {
        float scale = p.maxSpeed / speed;
        vx *= scale;
        vy *= scale;
    }

    px += vx;
    py += vy;


    e *= p.energyAlpha;
    if (p.energyGainBias > 0.0f && p.gainsCount == p.bins) {
        float extra = p.energyGainBias * (gainFactor - 1.0f);
        e += extra;
    }
    if (spiked && p.energySpikeGain > 0.0f) {
        e += p.energySpikeGain * gainFactor;
    }
    if (p.energyCap > 0.0f) {
        e = min(e, p.energyCap);
    }
    bool aliveFlag = true;
    int proj = -1;

    if (e < p.energyFloor) {
        aliveFlag = false;
    } else {
        float r = sqrt(max(0.0f, px * px + py * py));
        if (r >= p.radius) {
            float theta = atan2(py, px);
            int b = binIndex(theta, p.bins);
            proj = b;
            float g = (p.gainsCount == p.bins) ? gains[b] : 1.0f;
            float contrib = g * max(0.0f, e);
            uint groupId = p.threadsPerGroup > 0 ? (gid / p.threadsPerGroup) : 0;
            uint idx = groupId * p.bins + uint(b);
            atomic_fetch_add_explicit(&groupHistogram[idx], contrib, memory_order_relaxed);
            aliveFlag = false;
        }
    }

    posX[gid] = px;
    posY[gid] = py;
    velX[gid] = vx;
    velY[gid] = vy;
    energy[gid] = e;
    V[gid] = v;
    projectedBin[gid] = proj;
    spikedOut[gid] = spiked ? 1 : 0;
    alive[gid] = aliveFlag ? 1 : 0;
}

// Training fast path: records per-particle completion data and per-group counters (spikes/steps/completions)
kernel void flow_step_train(
    device const int *ids [[buffer(0)]],
    device float *posX [[buffer(1)]],
    device float *posY [[buffer(2)]],
    device float *velX [[buffer(3)]],
    device float *velY [[buffer(4)]],
    device float *energy [[buffer(5)]],
    device float *V [[buffer(6)]],
    device atomic_float *histogram [[buffer(7)]],
    device atomic_float *groupHistogram [[buffer(8)]],
    device uchar *alive [[buffer(9)]],
    device const float *gains [[buffer(10)]],
    device const int *initialBinByIndex [[buffer(11)]],
    device uchar *completionWritten [[buffer(12)]],
    device int *completionID [[buffer(13)]],
    device int *completionBin [[buffer(14)]],
    device float *completionPosX [[buffer(15)]],
    device float *completionPosY [[buffer(16)]],
    device float *completionEnergy [[buffer(17)]],
    device uchar *completionSpiked [[buffer(18)]],
    device int *completionInitialBin [[buffer(19)]],
    device atomic_uint *groupSpikeCounts [[buffer(20)]],
    device atomic_uint *groupStepCounts [[buffer(21)]],
    device atomic_uint *groupCompletionCounts [[buffer(22)]],
    device atomic_float *groupWeightedSum [[buffer(23)]],
    device atomic_float *groupWeightSum [[buffer(24)]],
    device const float *targetsRaw [[buffer(25)]],
    device atomic_float *groupRadialMissSum [[buffer(26)]],
    device atomic_float *groupBoundaryLossSum [[buffer(27)]],
    constant FlowParams &p [[buffer(28)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= p.count) { return; }

    bool active = alive[gid] != 0;
    if (!active) {
        alive[gid] = 0;
        return;
    }

    uint groupId = p.threadsPerGroup > 0 ? (gid / p.threadsPerGroup) : 0;
    atomic_fetch_add_explicit(&groupStepCounts[groupId], 1u, memory_order_relaxed);

    int id = ids[gid];
    float px = posX[gid];
    float py = posY[gid];
    float vx = velX[gid];
    float vy = velY[gid];
    float e = energy[gid];
    float v = V[gid];

    float energyNorm = clamp(e / float(p.bins), 0.0f, 1.0f);
    float noiseDrive = (rand01(id, p.step, 1, p.baseSeed) - 0.5f) * 0.1f;
    float vUpdated = p.lifDecay * v + energyNorm + noiseDrive;
    bool spiked = false;
    if (vUpdated >= p.lifThreshold) {
        v = p.lifReset;
        spiked = true;
    } else {
        v = max(0.0f, vUpdated);
    }

    if (spiked) {
        atomic_fetch_add_explicit(&groupSpikeCounts[groupId], 1u, memory_order_relaxed);
    }

    float len = sqrt(max(0.0f, px * px + py * py));
    float dirX = 0.0f;
    float dirY = 0.0f;
    if (len > 0.0f) {
        dirX = px / len;
        dirY = py / len;
    } else {
        float ang = randUniform(id, p.step, 2, p.baseSeed, 0.0f, 6.283185307179586f);
        dirX = cos(ang);
        dirY = sin(ang);
    }
    float gainFactor = 1.0f;
    if (p.gainsCount == p.bins) {
        float thetaGain = atan2(py, px);
        int gainBin = binIndex(thetaGain, p.bins);
        gainFactor = max(0.0f, gains[gainBin]);
    }

    vx += p.radialBias * dirX;
    vy += p.radialBias * dirY;

    float spikeKick = p.spikeKick;
    if (p.gainSpikeKickScale > 0.0f && p.gainsCount == p.bins) {
        float kickScale = 1.0f + p.gainSpikeKickScale * (gainFactor - 1.0f);
        kickScale = max(0.0f, kickScale);
        spikeKick *= kickScale;
    }

    if (spiked) {
        float jitterAng = randUniform(id, p.step, 3, p.baseSeed, -3.141592653589793f, 3.141592653589793f) * p.noiseStdDir;
        float rotX = cos(jitterAng);
        float rotY = sin(jitterAng);
        float kickX = dirX * rotX - dirY * rotY;
        float kickY = dirX * rotY + dirY * rotX;
        vx += spikeKick * kickX;
        vy += spikeKick * kickY;
    }

    float noiseAng = randUniform(id, p.step, 4, p.baseSeed, -3.141592653589793f, 3.141592653589793f);
    vx += cos(noiseAng) * p.noiseStdPos;
    vy += sin(noiseAng) * p.noiseStdPos;

    float speed = sqrt(max(0.0f, vx * vx + vy * vy));
    if (speed > p.maxSpeed && speed > 0.0f) {
        float scale = p.maxSpeed / speed;
        vx *= scale;
        vy *= scale;
    }

    px += vx;
    py += vy;

    e *= p.energyAlpha;
    if (p.energyGainBias > 0.0f && p.gainsCount == p.bins) {
        float extra = p.energyGainBias * (gainFactor - 1.0f);
        e += extra;
    }
    if (spiked && p.energySpikeGain > 0.0f) {
        e += p.energySpikeGain * gainFactor;
    }
    if (p.energyCap > 0.0f) {
        e = min(e, p.energyCap);
    }

    bool aliveFlag = true;

    if (e < p.energyFloor) {
        aliveFlag = false;
    } else {
        float r = sqrt(max(0.0f, px * px + py * py));
        if (r >= p.radius) {
            float theta = atan2(py, px);
            int b = binIndex(theta, p.bins);

            atomic_fetch_add_explicit(&groupCompletionCounts[groupId], 1u, memory_order_relaxed);

            // Optional per-particle completion record (can be disabled to reduce memory traffic).
            if (p.recordCompletions != 0) {
                // Record completion exactly once per particle index.
                if (completionWritten[gid] == 0) {
                    completionWritten[gid] = 1;
                    completionID[gid] = id;
                    completionBin[gid] = b;
                    completionPosX[gid] = px;
                    completionPosY[gid] = py;
                    completionEnergy[gid] = e;
                    completionSpiked[gid] = spiked ? 1 : 0;
                    completionInitialBin[gid] = initialBinByIndex[gid];
                }
            }

            float g = (p.gainsCount == p.bins) ? gains[b] : 1.0f;
            float eAdj = g * max(0.0f, e);

            uint idx = groupId * p.bins + uint(b);

            // Raw histogram contribution (for diagnostics/parity with FlowRouter.run)
            if (p.recordHistogram != 0) {
                atomic_fetch_add_explicit(&groupHistogram[idx], eAdj, memory_order_relaxed);
            }

            // Scalar metrics accumulation (GPU): meanRadialMiss and boundaryLoss
            {
                float absMiss = fabs(r - p.radius);
                atomic_fetch_add_explicit(&groupRadialMissSum[groupId], absMiss, memory_order_relaxed);

                // Matches LossFunctions.boundaryLoss eps default.
                const float boundaryEps = 0.01f;
                float excess = absMiss - boundaryEps;
                if (excess > 0.0f) {
                    atomic_fetch_add_explicit(&groupBoundaryLossSum[groupId], excess, memory_order_relaxed);
                }
            }

            // Weighted yHat accumulation (CompletionAggregator equivalent) when enabled
            if (p.aggEnabled != 0) {
                const float eps = 1e-8f;

                float rDist = fabs(r - p.radius);
                float wDist = exp(-rDist / max(p.aggSigmaR, eps));

                float t = targetsRaw[b];
                float eDist = fabs(eAdj - t);
                float wEnergy = exp(-eDist / max(p.aggSigmaE, eps));

                float wAlign = 1.0f;
                int initialBin = initialBinByIndex[gid];
                if (initialBin >= 0) {
                    int diff = abs(initialBin - b);
                    int wrapped = min(diff, int(p.bins) - diff);
                    float angDist = (float(wrapped) / max(1.0f, float(p.bins))) * 6.283185307179586f;
                    wAlign = exp(-angDist / max(p.aggTau, eps));
                }

                float w = pow(wDist, p.aggAlpha) * pow(wEnergy, p.aggBeta) * pow(wAlign, p.aggGamma);

                atomic_fetch_add_explicit(&groupWeightedSum[idx], w * eAdj, memory_order_relaxed);
                atomic_fetch_add_explicit(&groupWeightSum[idx], w, memory_order_relaxed);
            }

            aliveFlag = false;
        }
    }

    posX[gid] = px;
    posY[gid] = py;
    velX[gid] = vx;
    velY[gid] = vy;
    energy[gid] = e;
    V[gid] = v;
    alive[gid] = aliveFlag ? 1 : 0;
}

kernel void flow_project_final(
    device const float *posX [[buffer(0)]],
    device const float *posY [[buffer(1)]],
    device const float *energy [[buffer(2)]],
    device atomic_float *histogram [[buffer(3)]],
    device atomic_float *groupHistogram [[buffer(4)]],
    device const uchar *alive [[buffer(5)]],
    device const float *gains [[buffer(6)]],
    constant FlowParams &p [[buffer(7)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= p.count) { return; }
    if (alive[gid] == 0) { return; }

    float px = posX[gid];
    float py = posY[gid];
    float e = energy[gid];
    float theta = atan2(py, px);
    int b = binIndex(theta, p.bins);
    float g = (p.gainsCount == p.bins) ? gains[b] : 1.0f;
    float r = sqrt(max(0.0f, px * px + py * py));
    float ratio = clamp(r / max(p.radius, 1e-6f), 0.0f, 1.0f);
    float weight = pow(ratio, p.finalWeightPower);
    float contrib = g * max(0.0f, e) * weight;
    uint groupId = p.threadsPerGroup > 0 ? (gid / p.threadsPerGroup) : 0;
    uint idx = groupId * p.bins + uint(b);
    atomic_fetch_add_explicit(&groupHistogram[idx], contrib, memory_order_relaxed);
}

kernel void flow_reduce_hist(
    device atomic_float *histogram [[buffer(0)]],
    device atomic_float *groupHistogram [[buffer(1)]],
    constant FlowParams &p [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= p.bins) { return; }
    float sum = 0.0f;
    uint offset = gid;
    for (uint g = 0; g < p.groupCount; g++) {
        sum += atomic_load_explicit(&groupHistogram[offset], memory_order_relaxed);
        offset += p.bins;
    }
    if (sum != 0.0f) {
        atomic_fetch_add_explicit(&histogram[gid], sum, memory_order_relaxed);
    }
}

kernel void flow_finalize_weighted_yhat(
    device const atomic_float *sumWE [[buffer(0)]],
    device const atomic_float *sumW [[buffer(1)]],
    device float *yHat [[buffer(2)]],
    constant FlowParams &p [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= p.bins) { return; }
    const float eps = 1e-8f;
    float we = atomic_load_explicit(&sumWE[gid], memory_order_relaxed);
    float w = atomic_load_explicit(&sumW[gid], memory_order_relaxed);
    yHat[gid] = (w > eps) ? (we / w) : 0.0f;
}

struct FlowLearningParams {
    uint bins;
    uint wrongCount;
    uint optionCount;
    int correctIndex;          // -1 when not provided
    uint doUpdateGains;        // 0/1

    float gainLearningRate;
    float gainMin;
    float gainMax;
    float errorPower;
    float errorScale;

    float lambdaG;
    float negativeWeight;
    float negativeMargin;
};

struct FlowLearningScalars {
    float yHatMean;
    float yHatVariance;
    float yHatMin;
    float yHatMax;
    float nonzeroBins;

    float binLoss;
    float negativeLoss;
    float histogramMatchL1;
    float optionAccuracy;      // -1 when not provided

    float gainDeltaMean;
    float gainDeltaVariance;
};

static inline float gainScaleFromDiff(float diff, float errorPower, float errorScale) {
    float absDiff = fabs(diff);
    if (absDiff <= 0.0f) { return 0.0f; }
    float p = max(0.0f, errorPower - 1.0f);
    return errorScale * pow(absDiff, p);
}

kernel void flow_learning_finalize(
    device const float *yHatRaw [[buffer(0)]],
    device float *gains [[buffer(1)]],
    device const float *targetNorm [[buffer(2)]],
    device const float *wrongTargetsNorm [[buffer(3)]],
    device const float *optionTargetsRaw [[buffer(4)]],
    device FlowLearningScalars *out [[buffer(5)]],
    constant FlowLearningParams &lp [[buffer(6)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid != 0) { return; }

    const uint bins = lp.bins;
    const float eps = 1e-8f;

    // yHat stats (raw)
    float sumY = 0.0f;
    float sumYSq = 0.0f;
    float minY = INFINITY;
    float maxY = 0.0f;
    float nonzero = 0.0f;
    for (uint b = 0; b < bins; b++) {
        float v = yHatRaw[b];
        sumY += v;
        sumYSq += v * v;
        minY = min(minY, v);
        maxY = max(maxY, v);
        if (v > 0.0f) { nonzero += 1.0f; }
    }
    if (bins == 0) {
        minY = 0.0f;
        maxY = 0.0f;
    } else if (!isfinite(minY)) {
        // e.g. bins>0 but all values were NaN/Inf
        minY = 0.0f;
    }

    float meanY = bins > 0 ? (sumY / float(bins)) : 0.0f;
    float varY = bins > 0 ? (sumYSq / float(bins) - meanY * meanY) : 0.0f;
    varY = max(0.0f, varY);

    // Normalize yHat for loss computations (match Swift normalizeBins: if sum<=0, return original)
    float invSumY = (sumY > 0.0f) ? (1.0f / max(sumY, eps)) : 1.0f;

    // Bin loss + histogram match (L1 over normalized bins)
    float lossBins = 0.0f;
    float l1 = 0.0f;
    float regTerm = 0.0f;

    for (uint b = 0; b < bins; b++) {
        float yN = yHatRaw[b] * invSumY;
        float tN = targetNorm[b];
        float diff = yN - tN;
        lossBins += diff * diff;
        l1 += fabs(diff);

        float g = gains[b];
        regTerm += g * g;
    }

    float binLoss = lossBins + lp.lambdaG * regTerm;

    // Negative margin loss (normalized)
    float negativeBase = 0.0f;
    if (lp.wrongCount > 0) {
        for (uint j = 0; j < lp.wrongCount; j++) {
            float sumSq = 0.0f;
            uint base = j * bins;
            for (uint b = 0; b < bins; b++) {
                float yN = yHatRaw[b] * invSumY;
                float d = yN - wrongTargetsNorm[base + b];
                sumSq += d * d;
            }
            float dist = sqrt(sumSq);
            float diff = max(0.0f, lp.negativeMargin - dist);
            negativeBase += diff * diff;
        }
        negativeBase /= float(lp.wrongCount);
    }
    float negativeLoss = negativeBase * lp.negativeWeight;

    // Option accuracy: argmin over L2(yHatRaw, optionTargetsRaw)
    float optionAcc = -1.0f;
    if (lp.optionCount > 0 && lp.correctIndex >= 0 && lp.correctIndex < int(lp.optionCount)) {
        float bestDist = INFINITY;
        int bestIdx = 0;
        for (uint j = 0; j < lp.optionCount; j++) {
            float sumSq = 0.0f;
            uint base = j * bins;
            for (uint b = 0; b < bins; b++) {
                float d = yHatRaw[b] - optionTargetsRaw[base + b];
                sumSq += d * d;
            }
            float dist = sqrt(sumSq);
            if (dist < bestDist) {
                bestDist = dist;
                bestIdx = int(j);
            }
        }
        optionAcc = (bestIdx == lp.correctIndex) ? 1.0f : 0.0f;
    }

    // Optional gains update (in-place) + delta stats (mean/variance)
    float sumDelta = 0.0f;
    float sumDeltaSq = 0.0f;

    if (lp.doUpdateGains != 0 && bins > 0) {
        // Precompute wrong distances for repulsion gating.
        // Note: fixed upper bound to keep it simple; caller must ensure wrongCount <= 8.
        float wrongDist[8];
        for (uint k = 0; k < 8; k++) { wrongDist[k] = 0.0f; }

        uint wc = min(lp.wrongCount, 8u);
        for (uint j = 0; j < wc; j++) {
            float sumSq = 0.0f;
            uint base = j * bins;
            for (uint b = 0; b < bins; b++) {
                float yN = yHatRaw[b] * invSumY;
                float d = yN - wrongTargetsNorm[base + b];
                sumSq += d * d;
            }
            wrongDist[j] = sqrt(sumSq);
        }

        float perTargetScale = (lp.negativeWeight > 0.0f && wc > 0) ? (lp.negativeWeight / float(wc)) : 0.0f;

        for (uint b = 0; b < bins; b++) {
            float oldG = gains[b];
            float yN = yHatRaw[b] * invSumY;
            float tN = targetNorm[b];
            float diff = yN - tN;
            float scale = gainScaleFromDiff(diff, lp.errorPower, lp.errorScale);

            float g = oldG - lp.gainLearningRate * (2.0f * diff * scale);
            g = clamp(g, lp.gainMin, lp.gainMax);

            // Repulsion
            if (perTargetScale > 0.0f) {
                for (uint j = 0; j < wc; j++) {
                    if (lp.negativeMargin > 0.0f && wrongDist[j] >= lp.negativeMargin) { continue; }
                    uint base = j * bins;
                    float d2 = yN - wrongTargetsNorm[base + b];
                    float scale2 = gainScaleFromDiff(d2, lp.errorPower, lp.errorScale);
                    g += lp.gainLearningRate * perTargetScale * (2.0f * d2 * scale2);
                    g = clamp(g, lp.gainMin, lp.gainMax);
                }
            }

            gains[b] = g;
            float delta = g - oldG;
            sumDelta += delta;
            sumDeltaSq += delta * delta;
        }
    }

    float deltaMean = bins > 0 ? (sumDelta / float(bins)) : 0.0f;
    float deltaVar = bins > 0 ? (sumDeltaSq / float(bins) - deltaMean * deltaMean) : 0.0f;
    deltaVar = max(0.0f, deltaVar);

    FlowLearningScalars s;
    s.yHatMean = meanY;
    s.yHatVariance = varY;
    s.yHatMin = minY;
    s.yHatMax = maxY;
    s.nonzeroBins = nonzero;
    s.binLoss = binLoss;
    s.negativeLoss = negativeLoss;
    s.histogramMatchL1 = l1;
    s.optionAccuracy = optionAcc;
    s.gainDeltaMean = deltaMean;
    s.gainDeltaVariance = deltaVar;

    out[0] = s;
}
