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
    constant FlowParams &p [[buffer(23)]],
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
                atomic_fetch_add_explicit(&groupCompletionCounts[groupId], 1u, memory_order_relaxed);
            }

            float g = (p.gainsCount == p.bins) ? gains[b] : 1.0f;
            float contrib = g * max(0.0f, e);
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
