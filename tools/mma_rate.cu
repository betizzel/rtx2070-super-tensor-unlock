// SM75 tensor issue-rate probe: FP16 inputs with FP32 vs FP16 accumulation.
// mma.sync m16n8k8 is the native Turing HMMA shape. The FP16-accumulate run is
// the control (never rate-limited); FP32-accumulate is what GeForce halves.
#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

#define CK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
    fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e)); exit(1); } } while (0)

constexpr int CHAINS = 8;  // independent accumulators per warp to hide latency

__global__ void mma_f32(int iters, float *sink) {
    unsigned a0 = 0x3c003c00u ^ threadIdx.x, a1 = 0x3c003c00u, b0 = 0x3c003c00u;
    float c[CHAINS][4] = {};
    for (int i = 0; i < iters; i++) {
#pragma unroll
        for (int k = 0; k < CHAINS; k++)
            asm volatile("mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32 "
                         "{%0,%1,%2,%3}, {%4,%5}, {%6}, {%0,%1,%2,%3};"
                         : "+f"(c[k][0]), "+f"(c[k][1]), "+f"(c[k][2]), "+f"(c[k][3])
                         : "r"(a0), "r"(a1), "r"(b0));
    }
    float s = 0;
    for (int k = 0; k < CHAINS; k++) s += c[k][0] + c[k][1] + c[k][2] + c[k][3];
    if (s == 1234.5f) sink[0] = s;
}

__global__ void mma_f16(int iters, float *sink) {
    unsigned a0 = 0x3c003c00u ^ threadIdx.x, a1 = 0x3c003c00u, b0 = 0x3c003c00u;
    unsigned c[CHAINS][2] = {};
    for (int i = 0; i < iters; i++) {
#pragma unroll
        for (int k = 0; k < CHAINS; k++)
            asm volatile("mma.sync.aligned.m16n8k8.row.col.f16.f16.f16.f16 "
                         "{%0,%1}, {%2,%3}, {%4}, {%0,%1};"
                         : "+r"(c[k][0]), "+r"(c[k][1])
                         : "r"(a0), "r"(a1), "r"(b0));
    }
    unsigned s = 0;
    for (int k = 0; k < CHAINS; k++) s ^= c[k][0] ^ c[k][1];
    if (s == 0x12345678u) sink[0] = (float)s;
}

template <typename K>
static double run(K kernel, int blocks, int threads, int iters, float *sink) {
    cudaEvent_t t0, t1;
    CK(cudaEventCreate(&t0)); CK(cudaEventCreate(&t1));
    kernel<<<blocks, threads>>>(iters / 10, sink);  // warm-up / clock ramp
    CK(cudaDeviceSynchronize());
    double best = 0;
    for (int rep = 0; rep < 5; rep++) {
        CK(cudaEventRecord(t0));
        kernel<<<blocks, threads>>>(iters, sink);
        CK(cudaEventRecord(t1));
        CK(cudaEventSynchronize(t1));
        float ms; CK(cudaEventElapsedTime(&ms, t0, t1));
        double flop = 2.0 * 16 * 8 * 8 * CHAINS * (double)iters * blocks * (threads / 32);
        double tf = flop / (ms * 1e-3) / 1e12;
        if (tf > best) best = tf;
    }
    return best;
}

int main(int argc, char **argv) {
    int iters = argc > 1 ? atoi(argv[1]) : 20000;
    cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, 0));
    if (p.major != 7 || p.minor != 5) { fprintf(stderr, "not sm_75: %s\n", p.name); return 1; }
    float *sink; CK(cudaMalloc(&sink, 4));
    int blocks = p.multiProcessorCount * 4, threads = 256;
    double f16 = run(mma_f16, blocks, threads, iters, sink);
    double f32 = run(mma_f32, blocks, threads, iters, sink);
    int clk_khz = 0; CK(cudaDeviceGetAttribute(&clk_khz, cudaDevAttrClockRate, 0));
    printf("gpu=%s sms=%d iters=%d\n", p.name, p.multiProcessorCount, iters);
    printf("fp16->fp16 (control): %.2f TFLOPS\n", f16);
    printf("fp16->fp32 (target) : %.2f TFLOPS\n", f32);
    printf("ratio fp32acc/fp16acc: %.3f  (~0.5 = locked half rate, ~1.0 = unlocked)\n", f32 / f16);
    return 0;
}
