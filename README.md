# Native ARM64 CPU Server for a Ternary 8B Q2_0 Model on Snapdragon X Elite

*Tested 2026-07-12 on a Snapdragon X Elite (X1E80100), Windows 11 ARM64, 64 GB RAM. Every command and number below comes from the logged build session; the guide and launch script are included so you can reproduce the recipe on your own box.*

---

## TL;DR

Build a specialized llama.cpp fork from source for the **Snapdragon X Elite CPU** on **Windows ARM64** and serve a ternary 8B Q2_0 model with an OpenAI-compatible CPU server. The mainline llama.cpp cannot load this GGUF because its tensor type (42) is not in mainline's type table. The other blocker is Windows 11's user-mode SVE gap: a naive `-march=native` build emits SVE instructions and dies instantly with `STATUS_ILLEGAL_INSTRUCTION`. Pinning the ISA to `armv8.7-a+dotprod+i8mm+fp16` with `GGML_NATIVE=OFF` fixes it.

On the reference machine, this recipe decodes the ternary 8B Q2_0 model at **10.5 tok/s** (CPU, 4 threads), faster than the shipping build 9570 binaries (8.7 tok/s) and close to the Adreno Vulkan backend (12.6 tok/s). See [GUIDE.md](GUIDE.md) for the full build recipe, runtime DLL checklist, and benchmarks.

---

## Environment

| Item | Value |
|---|---|
| CPU | Snapdragon X Elite X1E80100, 12 Oryon cores (ARMv8, NEON, DOTPROD, I8MM, FP16; **no user-mode SVE**) |
| RAM | 64 GB unified memory |
| OS | Windows 11 ARM64 |
| Toolchain | llvm-mingw aarch64 UCRT (Clang 22.1.8) |
| Build system | CMake 4.x + Ninja |
| Target model | Ternary 8B Q2_0 GGUF (ggml type 42, ~2 GB on disk) |

> **Note on paths:** this guide uses `C:\Users\you\...` as a placeholder for your own working directory. Replace it with your actual paths (e.g., `C:\Users\you\src`, `C:\Users\you\tools`, `$HOME/src` under Git Bash).

---

## Step-by-step instructions

### 1. Get the specialized llama.cpp fork

Mainline llama.cpp fails to load this model with `invalid ggml type 42`. Obtain the public fork that adds Q2_0 support and clone the relevant branch:

```bash
git clone --depth 1 --branch <fork-branch> <llama.cpp-fork-url> llama-fork-src
cd llama-fork-src
```

### 2. Install the toolchain

- **llvm-mingw** (aarch64 UCRT): download from the [mstorsjo/llvm-mingw releases](https://github.com/mstorsjo/llvm-mingw/releases) page and extract to `C:\Users\you\tools\llvm-mingw-20260616-ucrt-aarch64` (or another path).
- **CMake** 4.x and **Ninja** (`pip install ninja`).

No Vulkan SDK is needed for the CPU build.

### 3. Configure with pinned ISA flags

From a Git Bash / MSYS2 shell:

```bash
export LLVM_MINGW_ROOT="/c/Users/you/tools/llvm-mingw-20260616-ucrt-aarch64"
export PATH="/c/Users/you/.venv/Scripts:$LLVM_MINGW_ROOT/bin:$PATH"
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

### 4. Build and stage runtime DLLs

```bash
cmake --build build-cpu --target llama-server llama-cli -j 10
cp "$LLVM_MINGW_ROOT/bin/"{libc++.dll,libunwind.dll,libomp.dll} build-cpu/bin/
```

Build time on the X Elite is under 15 minutes.

### 5. Run the model

```bash
# CLI smoke test
./build-cpu/bin/llama-cli.exe -m C:/Users/you/models/model-q2_0.gguf -p "Say OK" -n 8 -t 4 -c 2048 --no-mmap

# OpenAI-compatible server
./build-cpu/bin/llama-server.exe -m C:/Users/you/models/model-q2_0.gguf --port 8101 --host 127.0.0.1 \
    -c 8192 -t 4 -b 256 -ub 128 --no-mmap --flash-attn off
```

A PowerShell launcher with these defaults is in [scripts/launch-model-cpu.ps1](scripts/launch-model-cpu.ps1). Update the `$Model` and `$Server` paths inside the script before running it.

---

## Verification / testing

After the build, run these checks to confirm the binary is healthy and the model loads:

```bash
# 1. The server binary exists and the runtime DLLs are co-located
ls build-cpu/bin/ | grep -E 'llama-server|llama-cli|libc\+\+|libunwind|libomp'

# 2. CLI smoke test — should complete without SIGILL and print a few tokens
./build-cpu/bin/llama-cli.exe -m C:/Users/you/models/model-q2_0.gguf -p "Say OK" -n 8 -t 4 -c 2048 --no-mmap

# 3. Server health check (after starting the server in another terminal)
curl http://127.0.0.1:8101/v1/models
```

What success looks like for the CLI smoke test:

```
main: build = 1 (a5527fc)
...
Say OK
```

What failure looks like:

- **No output, immediate exit** → SVE leaked in; rebuild with `-DGGML_NATIVE=OFF` and the pinned `-march` flags.
- **`invalid ggml type 42`** → you are using mainline llama.cpp; switch to the specialized fork.
- **Silent exit 127** → missing `libc++.dll`, `libunwind.dll`, or `libomp.dll` next to the executable.

---

## Known limitations

- **User-mode SVE is not available on Windows ARM11 / Snapdragon X Elite.** Do not use `-march=native` or `GGML_NATIVE=ON`; the resulting binary will SIGILL at startup.
- **This build is CPU-only.** The Vulkan backend is intentionally disabled (`GGML_VULKAN=OFF`) because the specialized fork does not yet have a Q2_0 Vulkan kernel.
- **Static build.** `BUILD_SHARED_LIBS=OFF` produces a single self-contained executable but disables the dynamic backend loader.
- **Model-specific fork.** The specialized fork exists only to support ggml type 42; it is not a general upstream replacement.
- **Single-machine measurements.** The numbers below are from one Snapdragon X Elite box on one day; thermal state, background load, and future compiler/fork changes can move them.

---

## Reproduction notes

All artifacts needed to reproduce this work are in the repo:

- **[GUIDE.md](GUIDE.md)** — full CPU build guide, the SVE trap explanation, the exact configure command, runtime DLL checklist, and the benchmark table.
- **[scripts/launch-model-cpu.ps1](scripts/launch-model-cpu.ps1)** — PowerShell launcher that starts the model as a background OpenAI-compatible server. Edit the `$Model` and `$Server` paths to point to your GGUF and `llama-server.exe`.

To reproduce from scratch:

1. Replace all `C:\Users\you\...` placeholders with your own paths.
2. Obtain the ternary 8B Q2_0 GGUF and the specialized llama.cpp fork from the model publisher.
3. Run the configure/build commands from this README or GUIDE.md.
4. Run the verification commands in the section above.

---

## License

Repository content is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE) — free for personal use, research, education, and noncommercial organizations.

Component licenses: the specialized llama.cpp fork (Apache 2.0), upstream llama.cpp (MIT), llvm-mingw (permissive).

---

License: PolyForm Noncommercial 1.0.0. Measurements: take them as one data point from one machine on one day, and re-run the scripts on yours.

---

**Author:** Dr. Lucas Root, Ph.D. — [info@lucasroot.com](mailto:info@lucasroot.com)
