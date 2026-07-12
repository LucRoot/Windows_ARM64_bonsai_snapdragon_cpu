# Launch the ternary Q2_0 8B model as a CPU OpenAI-compatible server.
# Uses a specialized llama.cpp fork binary that supports ggml type 42.
# See GUIDE.md for the build recipe (SVE trap, NEON/DOTPROD/I8MM flags).

param(
    [string]$Model = "C:\Users\you\models\model-q2_0.gguf",
    [string]$Server = "C:\Users\you\llama-build\llama-server.exe",
    [int]$Port = 8101,
    [int]$Context = 8192,
    [int]$Threads = 4
)

Start-Process -FilePath $Server -WindowStyle Hidden -ArgumentList `
    '-m', $Model, `
    '--port', "$Port", '--host', '127.0.0.1', `
    '-c', "$Context", '-t', "$Threads", `
    '-b', '256', '-ub', '128', `
    '--no-mmap', '--flash-attn', 'off'

Write-Host "Ternary Q2_0 8B model launching on http://127.0.0.1:$Port (CPU)"
Write-Host "Verify: curl http://127.0.0.1:$Port/v1/models"
