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
    float noiseStdPos;
    float noiseStdDir;
    float maxSpeed;
    float energyAlpha;
    float energyFloor;
    float finalWeightPower;
    uint gainsCount;
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

#define FLOW_TG_BINS 256

kernel void flow_step(
    device const int *ids [[buffer(0)]],
    device float *posX [[buffer(1)]],
    device float *posY [[buffer(2)]],
    device float *velX [[buffer(3)]],
    device float *velY [[buffer(4)]],
    device float *energy [[buffer(5)]],
    device float *V [[buffer(6)]],
    device atomic_float *histogram [[buffer(7)]],
    device int *projectedBin [[buffer(8)]],
    device uchar *spikedOut [[buffer(9)]],
    device uchar *alive [[buffer(10)]],
    device const float *gains [[buffer(11)]],
    constant FlowParams &p [[buffer(12)]],
    uint gid [[thread_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    uint3 tgs [[threads_per_threadgroup]]
) {
    bool inRange = gid < p.count;
    const bool useLocal = p.bins <= FLOW_TG_BINS;
    threadgroup atomic_float localHist[FLOW_TG_BINS];
    if (useLocal) {
        uint tgSize = tgs.x;
        for (uint i = tid; i < FLOW_TG_BINS; i += tgSize) {
            atomic_store_explicit(&localHist[i], 0.0f, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (!useLocal && !inRange) { return; }
    bool active = inRange && (alive[gid] != 0);
    if (inRange && !active) {
        projectedBin[gid] = -1;
        spikedOut[gid] = 0;
        alive[gid] = 0;
    }

    int id = 0;
    float px = 0.0f;
    float py = 0.0f;
    float vx = 0.0f;
    float vy = 0.0f;
    float e = 0.0f;
    float v = 0.0f;
    if (active) {
        id = ids[gid];
        px = posX[gid];
        py = posY[gid];
        vx = velX[gid];
        vy = velY[gid];
        e = energy[gid];
        v = V[gid];
    }

    float energyNorm = clamp(e / float(p.bins), 0.0f, 1.0f);
    float noiseDrive = (rand01(id, p.step, 1, p.baseSeed) - 0.5f) * 0.1f;
    float vUpdated = p.lifDecay * v + energyNorm + noiseDrive;
    bool spiked = false;
    if (active) {
        if (vUpdated >= p.lifThreshold) {
            v = p.lifReset;
            spiked = true;
        } else {
            v = max(0.0f, vUpdated);
        }
    }

    float len = sqrt(max(0.0f, px * px + py * py));
    float dirX = 0.0f;
    float dirY = 0.0f;
    if (active) {
        if (len > 0.0f) {
            dirX = px / len;
            dirY = py / len;
        } else {
            float ang = randUniform(id, p.step, 2, p.baseSeed, 0.0f, 6.283185307179586f);
            dirX = cos(ang);
            dirY = sin(ang);
        }
    }

    if (active) {
        vx += p.radialBias * dirX;
        vy += p.radialBias * dirY;
    }

    if (active && spiked) {
        float jitterAng = randUniform(id, p.step, 3, p.baseSeed, -3.141592653589793f, 3.141592653589793f) * p.noiseStdDir;
        float rotX = cos(jitterAng);
        float rotY = sin(jitterAng);
        float kickX = dirX * rotX - dirY * rotY;
        float kickY = dirX * rotY + dirY * rotX;
        vx += p.spikeKick * kickX;
        vy += p.spikeKick * kickY;
    }

    if (active) {
        float noiseAng = randUniform(id, p.step, 4, p.baseSeed, -3.141592653589793f, 3.141592653589793f);
        vx += cos(noiseAng) * p.noiseStdPos;
        vy += sin(noiseAng) * p.noiseStdPos;
    }

    float speed = sqrt(max(0.0f, vx * vx + vy * vy));
    if (active && speed > p.maxSpeed && speed > 0.0f) {
        float scale = p.maxSpeed / speed;
        vx *= scale;
        vy *= scale;
    }

    if (active) {
        px += vx;
        py += vy;
    }

    e *= p.energyAlpha;
    bool aliveFlag = active;
    int proj = -1;

    if (active) {
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
                if (useLocal) {
                    atomic_fetch_add_explicit(&localHist[b], contrib, memory_order_relaxed);
                } else {
                    atomic_fetch_add_explicit(&histogram[b], contrib, memory_order_relaxed);
                }
                aliveFlag = false;
            }
        }
    }

    if (active) {
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

    if (useLocal) {
        threadgroup_barrier(mem_flags::mem_threadgroup);
        uint tgSize = tgs.x;
        for (uint i = tid; i < p.bins; i += tgSize) {
            float vHist = atomic_load_explicit(&localHist[i], memory_order_relaxed);
            if (vHist != 0.0f) {
                atomic_fetch_add_explicit(&histogram[i], vHist, memory_order_relaxed);
            }
        }
    }
}

kernel void flow_project_final(
    device const float *posX [[buffer(0)]],
    device const float *posY [[buffer(1)]],
    device const float *energy [[buffer(2)]],
    device atomic_float *histogram [[buffer(3)]],
    device const uchar *alive [[buffer(4)]],
    device const float *gains [[buffer(5)]],
    constant FlowParams &p [[buffer(6)]],
    uint gid [[thread_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    uint3 tgs [[threads_per_threadgroup]]
) {
    if (gid >= p.count) { return; }
    const bool useLocal = p.bins <= FLOW_TG_BINS;
    threadgroup atomic_float localHist[FLOW_TG_BINS];
    if (useLocal) {
        uint tgSize = tgs.x;
        for (uint i = tid; i < FLOW_TG_BINS; i += tgSize) {
            atomic_store_explicit(&localHist[i], 0.0f, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (!useLocal && !inRange) { return; }
    bool active = inRange && (alive[gid] != 0);
    if (active) {
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
        if (useLocal) {
            atomic_fetch_add_explicit(&localHist[b], contrib, memory_order_relaxed);
        } else {
            atomic_fetch_add_explicit(&histogram[b], contrib, memory_order_relaxed);
        }
    }

    if (useLocal) {
        threadgroup_barrier(mem_flags::mem_threadgroup);
        uint tgSize = tgs.x;
        for (uint i = tid; i < p.bins; i += tgSize) {
            float vHist = atomic_load_explicit(&localHist[i], memory_order_relaxed);
            if (vHist != 0.0f) {
                atomic_fetch_add_explicit(&histogram[i], vHist, memory_order_relaxed);
            }
        }
    }
}
