# CPU Build Guide for a Ternary 8B Q2_0 Model on Snapdragon X Elite (Windows ARM64)

**A reproducible CPU build guide for the ARM community**

Date: 2026-07-12<br>
Hardware: Snapdragon X Elite (X1E80100, 12-core Oryon), 64 GB unified memory, Windows 11 ARM64<br>
Status: Complete and validated. The exact recipe below is the configure of the build used in production on the author's machine; the binary reports `version: 1 (a5527fc), built with Clang 22.1.8 for Windows ARM64` and loads the ternary Q2_0 GGUF directly.

A companion GPU repo covers the same model on the Adreno GPU via Vulkan. This guide is the CPU baseline that repo benchmarks against.

---

## 1. What you are building and why

The subject model is a ternary-weight 8B model (weights in {-1, 0, +1}), shipped as a GGUF in a custom `Q2_0` format (ggml tensor type 42, ~2 GB on disk). Two facts drive this build:

1. **Mainline llama.cpp cannot load the model.** Type 42 is beyond mainline's `GGML_TYPE_COUNT = 42`; the load fails with `tensor 'output.weight' has invalid ggml type 42`. You need the specialized llama.cpp fork that adds Q2_0 support. Obtain the public fork URL and branch name from the model card or upstream release notes.
2. **The CPU ternary kernel is the fastest way to run this model on this chip today.** The fork has optimized CPU kernels for Q2_0 (the ternary matmul is integer/bit-packed work the Oryon cores do well). Measured decode: 14.4 tok/s CPU vs 12.6 tok/s on the Adreno Vulkan backend, because the fork has no Q2_0 Vulkan kernel yet.

Prebuilt CPU binaries are available, so why build from source? Three reasons: you get the current fork head (the shipping binaries here are build 9570, behind the fork head), you control the ISA flags (section 2 is the difference between a working binary and an instant SIGILL), and you get `llama-server` — the shipping bundle is CLI-oriented, and an OpenAI-compatible server is what agent harnesses want.

## 2. The SVE trap (the one gotcha that matters)

Windows 11 on the X Elite reports SVE at the hardware level, but the OS HAL does not expose SVE to user mode. Any SVE instruction — for example `svcntb()`, which compilers happily auto-vectorize into — raises `STATUS_ILLEGAL_INSTRUCTION` (0xc000001d) the moment it executes.

A default `-march=native` (or llama.cpp's `GGML_NATIVE=ON`) probes the host, detects SVE, and emits it. The resulting binary dies at startup with no log output. The fix is to pin the ISA to what Windows actually exposes to user mode — NEON with DOTPROD, I8MM, and FP16 vector arithmetic:

```
-march=armv8.7-a+dotprod+i8mm+fp16
-DGGML_USE_DOTPROD -DGGML_USE_MATMUL_INT8 -DGGML_USE_FP16_VECTOR_ARITHMETIC
-DGGML_NATIVE=OFF
```

`GGML_NATIVE=OFF` is the load-bearing one: it stops the build system's maximal-ISA probing. This applies to *any* llama.cpp build on Windows ARM64, for any model.

## 3. Toolchain

| Component | Source | Purpose |
|---|---|---|
| Specialized llama.cpp fork, Q2_0 branch | public fork URL from the model card | Q2_0 (type 42) support |
| llvm-mingw (aarch64, UCRT) | github.com/mstorsjo/llvm-mingw releases | Clang toolchain for Windows ARM64 |
| CMake 4.x | cmake.org | Build system |
| Ninja | `pip install ninja` | Generator (must be on PATH) |

No Vulkan SDK, no glslc, no SPIRV-Headers — none of that is needed for the CPU build. On the reference machine the toolchain lives at `C:\Users\you\tools\llvm-mingw-20260616-ucrt-aarch64` and ninja at `C:\Users\you\.venv\Scripts\ninja.exe`; substitute your own paths. `C:\Users\you` is the placeholder working directory throughout this guide.

## 4. Configure (validated)

```bash
export LLVM_MINGW_ROOT="/c/Users/you/tools/llvm-mingw-20260616-ucrt-aarch64"
export PATH="/c/Users/you/.venv/Scripts:$LLVM_MINGW_ROOT/bin:$PATH"
cd /c/Users/you/src/llama-fork-src
ARCH_FLAGS="-DWIN32_LEAN_AND_MEAN -D_WIN32_WINNT=0x0A00 -march=armv8.7-a+dotprod+i8mm+fp16 -DGGML_USE_DOTPROD -DGGML_USE_MATMUL_INT8 -DGGML_USE_FP16_VECTOR_ARITHMETIC"
cmake -S . -B build-cpu -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$ARCH_FLAGS" -DCMAKE_CXX_FLAGS="$ARCH_FLAGS" \
  -DCMAKE_C_COMPILER="$LLVM_MINGW_ROOT/bin/aarch64-w64-mingw32-clang.exe" \
  -DCMAKE_CXX_COMPILER="$LLVM_MINGW_ROOT/bin/aarch64-w64-mingw32-clang++.exe" \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF \
  -DGGML_NATIVE=OFF -DGGML_VULKAN=OFF -DGGML_BACKEND_DL=OFF -DBUILD_SHARED_LIBS=OFF
```

This is the exact flag set of the validated `build-novk` tree on the reference machine (`BUILD_SHARED_LIBS=OFF`, `GGML_VULKAN=OFF`, `GGML_NATIVE=OFF`). The static build produces one self-contained executable and removes the dynamic backend loader from the failure surface.

## 5. Build

```bash
cmake --build build-cpu --target llama-server llama-cli -j 10
```

Copy the llvm-mingw runtime next to the binaries — they link dynamically against libc++ even in a static llama build:

```bash
cp "$LLVM_MINGW_ROOT/bin/"{libc++.dll,libunwind.dll,libomp.dll} build-cpu/bin/
```

A missing co-located runtime DLL makes the launcher exit silently with code 127 and no message — the classic "successful no-op" failure. Build time on the X Elite at `-j 10` is under 15 minutes.

## 6. Load test and server

```bash
# CLI smoke test — loads the ternary GGUF directly, no conversion, no requantization:
./llama-cli.exe -m model-q2_0.gguf -p "Say OK" -n 8 -t 4 -c 2048 --no-mmap

# OpenAI-compatible server:
./llama-server.exe -m model-q2_0.gguf --port 8101 --host 127.0.0.1 \
    -c 8192 -t 4 -b 256 -ub 128 --no-mmap --flash-attn off
curl http://127.0.0.1:8101/v1/models
```

A ready-made launcher with these defaults is in [scripts/launch-model-cpu.ps1](scripts/launch-model-cpu.ps1).

## 7. Measured performance (Snapdragon X Elite, 64 GB)

Prefill and decode on a 1344-token prompt, ternary 8B Q2_0, `-t 4`:

| Build | Prefill tok/s | Decode tok/s |
|---|---|---|
| Shipping build 9570 binaries | 13.6 | 8.7 |
| This recipe (fork head, `-march` pinned) | 13.8 | 10.5 |
| Companion Vulkan build on Adreno (`-ngl 99`) | — | 12.6 |

Decode for this model is fastest on the CPU ternary kernel today. GPU offload is still worthwhile when the CPU is saturated by a second, larger model. For a standard-quant model the picture flips: SmolLM3 Q4_K_M decodes at 29.1 tok/s CPU vs 30.9 on Vulkan.

## 8. Gotchas worth knowing

- **SIGILL at startup, zero output** → SVE leaked into the binary. Rebuild with section 2's flags and `GGML_NATIVE=OFF`. Do not try to "fix" it at runtime.
- **`invalid ggml type 42`** → you are running mainline llama.cpp. Use the specialized fork.
- **Silent exit 127** → missing `libc++.dll` / `libunwind.dll` / `libomp.dll` next to the exe.
- **`-D_WIN32_WINNT=0x0A00` is mandatory** for the server target: cpp-httplib hard-errors on older targets ("cpp-httplib doesn't support Windows 8 or lower").
- **`--version` on recent llama-cli exits 2 without output** in some builds; a model load is the reliable binary check.
- **Memory:** the ternary 8B Q2_0 model is ~2 GB on disk; with an 8K context the server holds ~3.2 GB RAM. The model is not the constraint on a 64 GB machine — context and parallel slots are.

## 9. License and acknowledgements

Repository content (guide, scripts): PolyForm Noncommercial License 1.0.0 — free for personal use, research, education, and noncommercial organizations. Components: the ternary 8B model and the specialized fork — model publisher, Apache 2.0. llama.cpp — ggml-org, MIT. llvm-mingw — Martin Storsjo, permissive.
