# pmf-init.ps1 — PerPetual Motion FrameWork 交互式环境配置脚本 (Windows)
# 用法: .\pmf-init.ps1 [-Yes] [-ForcePermissions]
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$ForcePermissions,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# ═══════════════════════════════════════════════════════════════
#  全局变量
# ═══════════════════════════════════════════════════════════════

$Script:Timestamp = Get-Date -Format "yyyyMMddHHmmss"
$Script:ScriptDir = $PSScriptRoot
if (-not $Script:ScriptDir) { $Script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Script:ComponentStatus = @{}
$Script:ComponentVersion = @{}
$Script:ToolState = @{}
$Script:BackupRecords = @()

# ═══════════════════════════════════════════════════════════════
#  帮助信息
# ═══════════════════════════════════════════════════════════════

if ($Help) {
    Write-Host @"
Usage: .\pmf-init.ps1 [OPTIONS]

PerPetual Motion FrameWork — 交互式环境配置脚本

Options:
  -Yes                全自动模式（跳过所有确认，权限层仍需确认）
  -ForcePermissions   与 -Yes 一起使用，权限层也自动修改
  -Help               显示此帮助信息

Examples:
  .\pmf-init.ps1                           # 交互模式
  .\pmf-init.ps1 -Yes                      # 全自动（权限层仍需确认）
  .\pmf-init.ps1 -Yes -ForcePermissions    # 全自动（包括权限层）
"@
    exit 0
}

# ═══════════════════════════════════════════════════════════════
#  核心工具函数
# ═══════════════════════════════════════════════════════════════

function Write-Log {
    param(
        [ValidateSet("INFO","WARN","ERROR","DEBUG")]
        [string]$Level,
        [string]$Message
    )
    switch ($Level) {
        "INFO"  { Write-Host "✅ $Message" -ForegroundColor Green }
        "WARN"  { Write-Host "⚠️ $Message" -ForegroundColor Yellow }
        "ERROR" { Write-Host "❌ $Message" -ForegroundColor Red }
        "DEBUG" { Write-Host "🔍 $Message" -ForegroundColor Cyan }
    }
}

function Invoke-PromptUser {
    param(
        [string]$Message,
        [string]$Default = "Y"
    )
    if ($Yes) { return "yes" }

    $hint = switch ($Default) {
        "Y" { "[Y/n/s]" }
        "N" { "[y/N/s]" }
        default { "[Y/n/s]" }
    }
    Write-Host "$Message $hint" -NoNewline
    Write-Host ""
    Write-Host "  Y = yes    n = skip this item    s = skip entire phase"
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
    switch ($answer.ToLower()) {
        { $_ -in "y","yes" } { return "yes" }
        { $_ -in "s","skip" } { return "skip_phase" }
        default { return "no" }
    }
}

function Backup-File {
    param([string]$Path)
    if (Test-Path $Path) {
        $backup = "${Path}.bak.${Script:Timestamp}"
        if (-not (Test-Path $backup)) {
            Copy-Item $Path $backup
            Write-Log INFO "备份: $Path → $backup"
            $Script:BackupRecords += "$Path → $backup"
        } else {
            Write-Log WARN "备份已存在: $backup"
        }
    }
}

function Refresh-Path {
    # 1. 从注册表重新读取系统和用户 PATH
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path    = "$userPath;$machinePath"

    # 2. 追加常见安装路径
    $extraPaths = @(
        "$env:APPDATA\Python\Python3*\Scripts"
        "$env:APPDATA\npm"
        "$env:USERPROFILE\.local\bin"
        "$env:USERPROFILE\.cargo\bin"
    )
    foreach ($p in $extraPaths) {
        $resolved = Resolve-Path $p -ErrorAction SilentlyContinue
        if ($resolved -and $env:Path -notlike "*$resolved*") {
            $env:Path = "$resolved;$env:Path"
        }
    }
}

function Show-PhaseBanner {
    param(
        [int]$PhaseNum,
        [string]$PhaseName
    )
    Write-Host ""
    Write-Host "═══════════════════════════════════════" -ForegroundColor White
    Write-Host "  Phase ${PhaseNum}/7: $PhaseName" -ForegroundColor White
    Write-Host "═══════════════════════════════════════" -ForegroundColor White
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════
#  检测与安装函数
# ═══════════════════════════════════════════════════════════════

function Invoke-RetryCommand {
    param(
        [string]$Command,
        [int]$MaxRetries = 3
    )
    $delays = @(5, 10)
    for ($attempt = 0; $attempt -lt $MaxRetries; $attempt++) {
        try {
            $output = Invoke-Expression $Command 2>&1
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                throw "Command exited with code $LASTEXITCODE"
            }
            return $true
        } catch {
            if ($attempt -lt ($MaxRetries - 1)) {
                $delayIdx = [Math]::Min($attempt, $delays.Count - 1)
                $waitTime = $delays[$delayIdx]
                Write-Log WARN "失败 (尝试 $($attempt+1)/$MaxRetries)，${waitTime}秒后重试..."
                Start-Sleep -Seconds $waitTime
            }
        }
    }
    Write-Log ERROR "命令在 ${MaxRetries} 次尝试后失败: $Command"
    return $false
}


function Compare-Version {
    param(
        [string]$Current,
        [string]$Minimum
    )
    try {
        $cur = [version]($Current -replace '^v','')
        $min = [version]$Minimum
        return $cur -lt $min
    } catch {
        return $false
    }
}

function Find-Tool {
    param(
        [string]$Name,
        [string]$DetectCmd,
        [string]$MinVersion = ""
    )
    try {
        $output = Invoke-Expression $DetectCmd 2>&1 | Out-String
        $match = [regex]::Match($output, '(\d+\.\d+[\.\d]*)')
        if ($match.Success) {
            $version = $match.Value
        } else {
            return "FOUND_LATEST|unknown"
        }
        if ($MinVersion -and (Compare-Version $version $MinVersion)) {
            return "FOUND_UPDATABLE|$version"
        }
        return "FOUND_LATEST|$version"
    } catch {
        return "NOT_FOUND"
    }
}

function Find-Skill {
    param(
        [string]$Name,
        [string[]]$Paths
    )
    $results = @()
    foreach ($p in $Paths) {
        $skillPath = Join-Path $p $Name
        $skillFile = Join-Path $skillPath "SKILL.md"
        if ((Test-Path $skillPath) -and (Test-Path $skillFile)) {
            $results += "FOUND"
        } elseif (Test-Path $skillPath) {
            $results += "UPDATABLE"
        } else {
            $results += "NOT_FOUND"
        }
    }
    return $results -join ","
}

function Install-Tool {
    param(
        [string]$Name,
        [string]$Method
    )
    Write-Log INFO "安装 $Name..."
    if (Invoke-RetryCommand $Method) {
        Refresh-Path
        Write-Log INFO "$Name 安装成功"
        $Script:ToolState[$Name] = "INSTALLED"
        return $true
    } else {
        Write-Log ERROR "$Name 安装失败"
        $Script:ToolState[$Name] = "FAILED"
        return $false
    }
}

function Get-InstallCommand {
    param([string]$Name)
    switch ($Name) {
        "git"     { return "winget install --accept-package-agreements --accept-source-agreements Git.Git" }
        "python3" { return "winget install --accept-package-agreements --accept-source-agreements Python.Python.3.12" }
        "node"    { return "winget install --accept-package-agreements --accept-source-agreements OpenJS.NodeJS.LTS" }
        "uv"      { return "winget install --accept-package-agreements --accept-source-agreements astral-sh.uv" }
        "codex"   { return "npm install -g @openai/codex" }
        "claude"  { return "npm install -g @anthropic-ai/claude-code" }
        "agy"     { return "npm install -g @google/agy" }
    }
    return ""
}

# ═══════════════════════════════════════════════════════════════
#  Phase 1: 基础环境
# ═══════════════════════════════════════════════════════════════

function Invoke-Phase1 {
    Show-PhaseBanner 1 "基础环境"
    Refresh-Path

    $npmAvailable = $true

    # ── Tier 1: git ──
    Write-Log INFO "检测 git..."
    $result = Find-Tool "git" "git --version"
    $parts = $result -split '\|'
    $status = $parts[0]
    $version = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    switch ($status) {
        "FOUND_LATEST" {
            Write-Log INFO "git $version ✅"
            $Script:ComponentStatus["git"] = "OK"
            $Script:ComponentVersion["git"] = $version
        }
        "FOUND_UPDATABLE" {
            Write-Log WARN "git $version 可更新"
            $Script:ComponentStatus["git"] = "UPDATE"
            $Script:ComponentVersion["git"] = $version
        }
        "NOT_FOUND" {
            Write-Log WARN "git 未找到"
            $answer = Invoke-PromptUser "安装 git?"
            if ($answer -eq "yes") {
                $cmd = Get-InstallCommand "git"
                if ($cmd -and (Install-Tool "git" $cmd)) {
                    $result = Find-Tool "git" "git --version"
                    $parts = $result -split '\|'
                    $Script:ComponentStatus["git"] = "OK"
                    $Script:ComponentVersion["git"] = $parts[1]
                } else {
                    $Script:ComponentStatus["git"] = "FAIL"
                    $Script:ComponentVersion["git"] = ""
                }
            } elseif ($answer -eq "skip_phase") {
                $Script:ComponentStatus["git"] = "SKIPPED"
                $Script:ComponentVersion["git"] = ""
                return
            } else {
                $Script:ComponentStatus["git"] = "SKIPPED"
                $Script:ComponentVersion["git"] = ""
            }
        }
    }

    # ── Tier 2: python3 + pip ──
    Write-Log INFO "检测 python3..."
    $result = Find-Tool "python3" "python --version" "3.10"
    $parts = $result -split '\|'
    $status = $parts[0]
    $version = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    switch ($status) {
        "FOUND_LATEST" {
            Write-Log INFO "python3 $version ✅"
            $Script:ComponentStatus["python3"] = "OK"
            $Script:ComponentVersion["python3"] = $version
        }
        "FOUND_UPDATABLE" {
            Write-Log WARN "python3 $version (需要 ≥3.10)"
            $Script:ComponentStatus["python3"] = "UPDATE"
            $Script:ComponentVersion["python3"] = $version
            if ($Yes) {
                $cmd = Get-InstallCommand "python3"
                if ($cmd) { Install-Tool "python3" $cmd | Out-Null }
                $result = Find-Tool "python3" "python --version" "3.10"
                $parts = $result -split '\|'
                $Script:ComponentStatus["python3"] = "OK"
                $Script:ComponentVersion["python3"] = $parts[1]
            }
        }
        "NOT_FOUND" {
            Write-Log WARN "python3 未找到"
            $answer = Invoke-PromptUser "安装 python3?"
            if ($answer -eq "yes") {
                $cmd = Get-InstallCommand "python3"
                if ($cmd -and (Install-Tool "python3" $cmd)) {
                    $result = Find-Tool "python3" "python --version" "3.10"
                    $parts = $result -split '\|'
                    $Script:ComponentStatus["python3"] = "OK"
                    $Script:ComponentVersion["python3"] = $parts[1]
                } else {
                    $Script:ComponentStatus["python3"] = "FAIL"
                    $Script:ComponentVersion["python3"] = ""
                }
            } elseif ($answer -eq "skip_phase") {
                $Script:ComponentStatus["python3"] = "SKIPPED"
                $Script:ComponentVersion["python3"] = ""
                $Script:ComponentStatus["pip"] = "SKIPPED"
                $Script:ComponentVersion["pip"] = ""
                return
            } else {
                $Script:ComponentStatus["python3"] = "SKIPPED"
                $Script:ComponentVersion["python3"] = ""
            }
        }
    }

    # pip
    Write-Log INFO "检测 pip..."
    $result = Find-Tool "pip" "pip --version"
    $parts = $result -split '\|'
    $status = $parts[0]
    $version = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    switch ($status) {
        { $_ -in "FOUND_LATEST","FOUND_UPDATABLE" } {
            Write-Log INFO "pip $version ✅"
            $Script:ComponentStatus["pip"] = "OK"
            $Script:ComponentVersion["pip"] = $version
        }
        "NOT_FOUND" {
            Write-Log WARN "pip 未找到 (随 python3 安装)"
            $Script:ComponentStatus["pip"] = "FAIL"
            $Script:ComponentVersion["pip"] = ""
        }
    }

    # ── Tier 2: node + npm ──
    Write-Log INFO "检测 node..."
    $result = Find-Tool "node" "node --version" "20"
    $parts = $result -split '\|'
    $status = $parts[0]
    $version = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    switch ($status) {
        "FOUND_LATEST" {
            Write-Log INFO "node $version ✅"
            $Script:ComponentStatus["node"] = "OK"
            $Script:ComponentVersion["node"] = $version
        }
        "FOUND_UPDATABLE" {
            Write-Log WARN "node $version (需要 ≥20)"
            $Script:ComponentStatus["node"] = "UPDATE"
            $Script:ComponentVersion["node"] = $version
            if ($Yes) {
                $cmd = Get-InstallCommand "node"
                if ($cmd) { Install-Tool "node" $cmd | Out-Null }
                $result = Find-Tool "node" "node --version" "20"
                $parts = $result -split '\|'
                if ($parts[0] -eq "FOUND_LATEST") {
                    $Script:ComponentStatus["node"] = "OK"
                }
                $Script:ComponentVersion["node"] = $parts[1]
            }
        }
        "NOT_FOUND" {
            Write-Log WARN "node 未找到"
            $answer = Invoke-PromptUser "安装 node + npm?"
            if ($answer -eq "yes") {
                $cmd = Get-InstallCommand "node"
                if ($cmd -and (Install-Tool "node" $cmd)) {
                    $result = Find-Tool "node" "node --version" "20"
                    $parts = $result -split '\|'
                    $Script:ComponentStatus["node"] = "OK"
                    $Script:ComponentVersion["node"] = $parts[1]
                } else {
                    $Script:ComponentStatus["node"] = "FAIL"
                    $Script:ComponentVersion["node"] = ""
                    $npmAvailable = $false
                }
            } elseif ($answer -eq "skip_phase") {
                $Script:ComponentStatus["node"] = "SKIPPED"
                $Script:ComponentVersion["node"] = ""
                $Script:ComponentStatus["npm"] = "SKIPPED"
                $Script:ComponentVersion["npm"] = ""
                $npmAvailable = $false
                foreach ($t in "codex","claude","agy") {
                    $Script:ComponentStatus[$t] = "BLOCKED"
                    $Script:ComponentVersion[$t] = ""
                }
                return
            } else {
                $Script:ComponentStatus["node"] = "SKIPPED"
                $Script:ComponentVersion["node"] = ""
                $npmAvailable = $false
            }
        }
    }

    # npm
    Write-Log INFO "检测 npm..."
    $result = Find-Tool "npm" "npm --version"
    $parts = $result -split '\|'
    $status = $parts[0]
    $version = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    switch ($status) {
        { $_ -in "FOUND_LATEST","FOUND_UPDATABLE" } {
            Write-Log INFO "npm $version ✅"
            $Script:ComponentStatus["npm"] = "OK"
            $Script:ComponentVersion["npm"] = $version
        }
        "NOT_FOUND" {
            Write-Log WARN "npm 未找到"
            $Script:ComponentStatus["npm"] = "FAIL"
            $Script:ComponentVersion["npm"] = ""
            $npmAvailable = $false
        }
    }

    # ── Tier 3: uv ──
    Write-Log INFO "检测 uv..."
    $result = Find-Tool "uv" "uv --version"
    $parts = $result -split '\|'
    $status = $parts[0]
    $version = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    switch ($status) {
        "FOUND_LATEST" {
            Write-Log INFO "uv $version ✅"
            $Script:ComponentStatus["uv"] = "OK"
            $Script:ComponentVersion["uv"] = $version
            $Script:ToolState["uv"] = "AVAILABLE"
        }
        "FOUND_UPDATABLE" {
            Write-Log WARN "uv $version 可更新"
            $Script:ComponentStatus["uv"] = "UPDATE"
            $Script:ComponentVersion["uv"] = $version
            $Script:ToolState["uv"] = "AVAILABLE"
        }
        "NOT_FOUND" {
            Write-Log WARN "uv 未找到"
            $answer = Invoke-PromptUser "安装 uv?"
            if ($answer -eq "yes") {
                $cmd = Get-InstallCommand "uv"
                if ($cmd -and (Install-Tool "uv" $cmd)) {
                    $result = Find-Tool "uv" "uv --version"
                    $parts = $result -split '\|'
                    $Script:ComponentStatus["uv"] = "OK"
                    $Script:ComponentVersion["uv"] = $parts[1]
                    $Script:ToolState["uv"] = "AVAILABLE"
                } else {
                    $Script:ComponentStatus["uv"] = "FAIL"
                    $Script:ComponentVersion["uv"] = ""
                    $Script:ToolState["uv"] = "MISSING"
                }
            } elseif ($answer -eq "skip_phase") {
                $Script:ComponentStatus["uv"] = "SKIPPED"
                $Script:ComponentVersion["uv"] = ""
                $Script:ToolState["uv"] = "MISSING"
                return
            } else {
                $Script:ComponentStatus["uv"] = "SKIPPED"
                $Script:ComponentVersion["uv"] = ""
                $Script:ToolState["uv"] = "MISSING"
            }
        }
    }

    # ── Tier 4: codex, claude, agy ──
    if (-not $npmAvailable) {
        Write-Log WARN "npm 不可用，Tier 4 工具标记为 BLOCKED(需要 npm)"
        foreach ($t in "codex","claude","agy") {
            $Script:ComponentStatus[$t] = "BLOCKED"
            $Script:ComponentVersion[$t] = ""
            $Script:ToolState[$t] = "MISSING"
        }
        return
    }

    $tier4 = @(
        @{ Name = "codex";  Cmd = "codex --version" }
        @{ Name = "claude"; Cmd = "claude --version" }
        @{ Name = "agy";    Cmd = "agy --version" }
    )

    foreach ($tool in $tier4) {
        $t = $tool.Name
        Write-Log INFO "检测 $t..."
        $result = Find-Tool $t $tool.Cmd
        $parts = $result -split '\|'
        $status = $parts[0]
        $version = if ($parts.Count -gt 1) { $parts[1] } else { "" }

        switch ($status) {
            "FOUND_LATEST" {
                Write-Log INFO "$t $version ✅"
                $Script:ComponentStatus[$t] = "OK"
                $Script:ComponentVersion[$t] = $version
                $Script:ToolState[$t] = "AVAILABLE"
            }
            "FOUND_UPDATABLE" {
                Write-Log WARN "$t $version 可更新"
                $Script:ComponentStatus[$t] = "UPDATE"
                $Script:ComponentVersion[$t] = $version
                $Script:ToolState[$t] = "AVAILABLE"
                if ($Yes) {
                    $cmd = Get-InstallCommand $t
                    if ($cmd) { Install-Tool $t $cmd | Out-Null }
                }
            }
            "NOT_FOUND" {
                Write-Log WARN "$t 未找到"
                $answer = Invoke-PromptUser "安装 ${t}?"
                if ($answer -eq "yes") {
                    $cmd = Get-InstallCommand $t
                    if ($cmd -and (Install-Tool $t $cmd)) {
                        $result = Find-Tool $t $tool.Cmd
                        $parts = $result -split '\|'
                        $Script:ComponentStatus[$t] = "OK"
                        $Script:ComponentVersion[$t] = $parts[1]
                        $Script:ToolState[$t] = "AVAILABLE"
                    } else {
                        $Script:ComponentStatus[$t] = "FAIL"
                        $Script:ComponentVersion[$t] = ""
                        $Script:ToolState[$t] = "MISSING"
                    }
                } elseif ($answer -eq "skip_phase") {
                    $Script:ComponentStatus[$t] = "SKIPPED"
                    $Script:ComponentVersion[$t] = ""
                    $Script:ToolState[$t] = "MISSING"
                    # Skip remaining
                    $skip = $false
                    foreach ($remaining in $tier4) {
                        if ($remaining.Name -eq $t) { $skip = $true; continue }
                        if ($skip) {
                            $Script:ComponentStatus[$remaining.Name] = "SKIPPED"
                            $Script:ComponentVersion[$remaining.Name] = ""
                            $Script:ToolState[$remaining.Name] = "MISSING"
                        }
                    }
                    return
                } else {
                    $Script:ComponentStatus[$t] = "SKIPPED"
                    $Script:ComponentVersion[$t] = ""
                    $Script:ToolState[$t] = "MISSING"
                }
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════
#  Phase 2: 记忆层 — Graphify
# ═══════════════════════════════════════════════════════════════

function Invoke-Phase2 {
    Show-PhaseBanner 2 "记忆层 — Graphify"
    Refresh-Path

    if ($Script:ToolState["uv"] -ne "AVAILABLE") {
        Write-Log WARN "graphify 标记为 BLOCKED(需要 uv)"
        foreach ($sub in "graphify","graphify→codex","graphify→agy","graphify→claude","graphify-out/") {
            $Script:ComponentStatus[$sub] = "BLOCKED"
            $Script:ComponentVersion[$sub] = ""
        }
        return
    }

    Write-Log INFO "检测 graphify..."
    $result = Find-Tool "graphify" "graphify --version"
    $parts = $result -split '\|'
    $status = $parts[0]
    $version = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    switch ($status) {
        "FOUND_LATEST" {
            Write-Log INFO "graphify $version ✅"
            $Script:ComponentStatus["graphify"] = "OK"
            $Script:ComponentVersion["graphify"] = $version
        }
        "FOUND_UPDATABLE" {
            Write-Log WARN "graphify $version 可更新"
            $Script:ComponentStatus["graphify"] = "UPDATE"
            $Script:ComponentVersion["graphify"] = $version
            if ($Yes) {
                Invoke-RetryCommand "uv tool upgrade graphifyy" | Out-Null
                $result = Find-Tool "graphify" "graphify --version"
                $parts = $result -split '\|'
                $Script:ComponentStatus["graphify"] = "OK"
                $Script:ComponentVersion["graphify"] = $parts[1]
            }
        }
        "NOT_FOUND" {
            Write-Log WARN "graphify 未找到"
            $answer = Invoke-PromptUser "安装 graphifyy via uv?"
            if ($answer -eq "yes") {
                if (Install-Tool "graphify" "uv tool install 'graphifyy[office,chinese]'") {
                    $result = Find-Tool "graphify" "graphify --version"
                    $parts = $result -split '\|'
                    $Script:ComponentStatus["graphify"] = "OK"
                    $Script:ComponentVersion["graphify"] = $parts[1]
                } else {
                    $Script:ComponentStatus["graphify"] = "FAIL"
                    $Script:ComponentVersion["graphify"] = ""
                }
            } elseif ($answer -eq "skip_phase") {
                foreach ($sub in "graphify","graphify→codex","graphify→agy","graphify→claude","graphify-out/") {
                    $Script:ComponentStatus[$sub] = "SKIPPED"
                    $Script:ComponentVersion[$sub] = ""
                }
                return
            } else {
                foreach ($sub in "graphify","graphify→codex","graphify→agy","graphify→claude","graphify-out/") {
                    $Script:ComponentStatus[$sub] = "SKIPPED"
                    $Script:ComponentVersion[$sub] = ""
                }
                return
            }
        }
    }

    if ($Script:ComponentStatus["graphify"] -notin "OK","UPDATE") {
        foreach ($sub in "graphify→codex","graphify→agy","graphify→claude","graphify-out/") {
            $Script:ComponentStatus[$sub] = "BLOCKED"
            $Script:ComponentVersion[$sub] = ""
        }
        return
    }

    # Platform registration
    $platforms = @(
        @{ Tool = "codex";  Platform = "codex";       Label = "graphify→codex" }
        @{ Tool = "agy";    Platform = "antigravity";  Label = "graphify→agy" }
        @{ Tool = "claude"; Platform = "claude";       Label = "graphify→claude" }
    )

    foreach ($p in $platforms) {
        if ($Script:ToolState[$p.Tool] -eq "AVAILABLE") {
            Write-Log INFO "注册 graphify → $($p.Tool)..."
            if (Invoke-RetryCommand "graphify install --platform $($p.Platform)") {
                $Script:ComponentStatus[$p.Label] = "OK"
                $Script:ComponentVersion[$p.Label] = "skill"
            } else {
                $Script:ComponentStatus[$p.Label] = "FAIL"
                $Script:ComponentVersion[$p.Label] = ""
            }
        } else {
            Write-Log WARN "$($p.Tool) 不可用，跳过 $($p.Label)"
            $Script:ComponentStatus[$p.Label] = "SKIPPED"
            $Script:ComponentVersion[$p.Label] = ""
        }
    }

    # Project graph
    $graphOutPath = Join-Path $Script:ScriptDir "graphify-out"
    if (Test-Path $graphOutPath) {
        if ($Yes) {
            Write-Log INFO "graphify-out/ 已存在，重新生成项目图谱..."
            Push-Location $Script:ScriptDir
            Invoke-RetryCommand "graphify ." | Out-Null
            Pop-Location
            $Script:ComponentStatus["graphify-out/"] = "OK"
        } else {
            Write-Log INFO "graphify-out/ 已存在 (可更新)"
            $Script:ComponentStatus["graphify-out/"] = "UPDATE"
        }
        $Script:ComponentVersion["graphify-out/"] = ""
    } else {
        $answer = Invoke-PromptUser "生成项目图谱 (graphify .)?"
        if ($answer -eq "yes") {
            Write-Log INFO "生成项目图谱..."
            Push-Location $Script:ScriptDir
            if (Invoke-RetryCommand "graphify .") {
                $Script:ComponentStatus["graphify-out/"] = "OK"
            } else {
                $Script:ComponentStatus["graphify-out/"] = "FAIL"
            }
            Pop-Location
        } else {
            $Script:ComponentStatus["graphify-out/"] = "SKIPPED"
        }
        $Script:ComponentVersion["graphify-out/"] = ""
    }
}

# ═══════════════════════════════════════════════════════════════
#  Phase 3: 方法层 — Superpowers
# ═══════════════════════════════════════════════════════════════

function Invoke-Phase3 {
    Show-PhaseBanner 3 "方法层 — Superpowers"
    Refresh-Path

    $repoUrl = "https://github.com/obra/superpowers.git"
    $localPath = Join-Path $env:USERPROFILE "agent-tools\superpowers"

    if (-not (Test-Path $localPath)) {
        Write-Log INFO "克隆 superpowers..."
        $answer = Invoke-PromptUser "克隆 superpowers 仓库?"
        if ($answer -eq "yes") {
            $parentDir = Split-Path $localPath -Parent
            if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
            if (Invoke-RetryCommand "git clone '$repoUrl' '$localPath'") {
                Write-Log INFO "superpowers 克隆成功"
            } else {
                Write-Log ERROR "superpowers 克隆失败"
                foreach ($sub in "superpowers→agy","superpowers→codex","superpowers→claude") {
                    $Script:ComponentStatus[$sub] = "FAIL"
                    $Script:ComponentVersion[$sub] = ""
                }
                return
            }
        } elseif ($answer -eq "skip_phase") {
            foreach ($sub in "superpowers→agy","superpowers→codex","superpowers→claude") {
                $Script:ComponentStatus[$sub] = "SKIPPED"
                $Script:ComponentVersion[$sub] = ""
            }
            return
        } else {
            foreach ($sub in "superpowers→agy","superpowers→codex","superpowers→claude") {
                $Script:ComponentStatus[$sub] = "SKIPPED"
                $Script:ComponentVersion[$sub] = ""
            }
            return
        }
    } else {
        Write-Log INFO "superpowers 已存在，检查更新..."
        try {
            git -C $localPath fetch 2>&1 | Out-Null
            $updates = git -C $localPath log "HEAD..origin/main" --oneline 2>&1 | Out-String
            if ($updates.Trim()) {
                if ($Yes) {
                    Write-Log INFO "拉取更新..."
                    git -C $localPath pull 2>&1 | Out-Null
                } else {
                    Write-Log WARN "远端有更新: $($updates.Trim())"
                }
            } else {
                Write-Log INFO "superpowers 已是最新"
            }
        } catch { }
    }

    # AGY install
    if ($Script:ToolState["agy"] -eq "AVAILABLE") {
        Write-Log INFO "安装 superpowers → agy..."
        if (Invoke-RetryCommand "agy plugin install '$localPath'") {
            $Script:ComponentStatus["superpowers→agy"] = "OK"
            $Script:ComponentVersion["superpowers→agy"] = "plugin"
        } else {
            $Script:ComponentStatus["superpowers→agy"] = "FAIL"
            $Script:ComponentVersion["superpowers→agy"] = ""
        }
    } else {
        Write-Log WARN "agy 不可用，跳过 superpowers→agy"
        $Script:ComponentStatus["superpowers→agy"] = "SKIPPED"
        $Script:ComponentVersion["superpowers→agy"] = ""
    }

    # Codex install (file placement)
    $codexSkills = Join-Path $env:USERPROFILE ".codex\skills"
    if (($Script:ToolState["codex"] -eq "AVAILABLE") -or (Test-Path (Split-Path $codexSkills -Parent))) {
        Write-Log INFO "安装 superpowers → codex..."
        if (-not (Test-Path $codexSkills)) { New-Item -ItemType Directory -Path $codexSkills -Force | Out-Null }
        $skillsSrc = Join-Path $localPath "skills"
        $count = 0
        if (Test-Path $skillsSrc) {
            foreach ($dir in Get-ChildItem $skillsSrc -Directory) {
                $target = Join-Path $codexSkills $dir.Name
                if (Test-Path $target) {
                    Write-Log INFO "  SKIPPED: $($dir.Name) (已存在)"
                } else {
                    Copy-Item $dir.FullName $target -Recurse
                    $count++
                }
            }
        }
        $Script:ComponentStatus["superpowers→codex"] = "OK"
        $Script:ComponentVersion["superpowers→codex"] = "$count skills"
    } else {
        Write-Log WARN "codex 不可用，跳过 superpowers→codex"
        $Script:ComponentStatus["superpowers→codex"] = "SKIPPED"
        $Script:ComponentVersion["superpowers→codex"] = ""
    }

    # Claude install (file placement)
    $claudeSkills = Join-Path $env:USERPROFILE ".agents\skills"
    if (($Script:ToolState["claude"] -eq "AVAILABLE") -or (Test-Path (Split-Path $claudeSkills -Parent))) {
        Write-Log INFO "安装 superpowers → claude..."
        if (-not (Test-Path $claudeSkills)) { New-Item -ItemType Directory -Path $claudeSkills -Force | Out-Null }
        $skillsSrc = Join-Path $localPath "skills"
        $count = 0
        if (Test-Path $skillsSrc) {
            foreach ($dir in Get-ChildItem $skillsSrc -Directory) {
                $target = Join-Path $claudeSkills $dir.Name
                if (Test-Path $target) {
                    Write-Log INFO "  SKIPPED: $($dir.Name) (已存在)"
                } else {
                    Copy-Item $dir.FullName $target -Recurse
                    $count++
                }
            }
        }
        $Script:ComponentStatus["superpowers→claude"] = "OK"
        $Script:ComponentVersion["superpowers→claude"] = "$count skills"
    } else {
        Write-Log WARN "claude 不可用，跳过 superpowers→claude"
        $Script:ComponentStatus["superpowers→claude"] = "SKIPPED"
        $Script:ComponentVersion["superpowers→claude"] = ""
    }
}

# ═══════════════════════════════════════════════════════════════
#  Phase 4: 执行层 — Missions
# ═══════════════════════════════════════════════════════════════

function Invoke-Phase4 {
    Show-PhaseBanner 4 "执行层 — Missions"
    Refresh-Path

    $repoUrl = "https://github.com/flowing-water1/Missions.git"
    $localPath = Join-Path $env:USERPROFILE "agent-tools\Missions"
    $missionDirs = @("mission","mission-doc-route","mission-approved-doc","mission-csv-execute","mission-long-task","mission-recovery")

    if (-not (Test-Path $localPath)) {
        Write-Log INFO "克隆 Missions..."
        $answer = Invoke-PromptUser "克隆 Missions 仓库?"
        if ($answer -eq "yes") {
            $parentDir = Split-Path $localPath -Parent
            if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
            if (Invoke-RetryCommand "git clone '$repoUrl' '$localPath'") {
                Write-Log INFO "Missions 克隆成功"
            } else {
                Write-Log ERROR "Missions 克隆失败"
                foreach ($sub in "missions→agy","missions→codex","missions→claude") {
                    $Script:ComponentStatus[$sub] = "FAIL"
                    $Script:ComponentVersion[$sub] = ""
                }
                return
            }
        } elseif ($answer -eq "skip_phase") {
            foreach ($sub in "missions→agy","missions→codex","missions→claude") {
                $Script:ComponentStatus[$sub] = "SKIPPED"
                $Script:ComponentVersion[$sub] = ""
            }
            return
        } else {
            foreach ($sub in "missions→agy","missions→codex","missions→claude") {
                $Script:ComponentStatus[$sub] = "SKIPPED"
                $Script:ComponentVersion[$sub] = ""
            }
            return
        }
    } else {
        Write-Log INFO "Missions 已存在，检查更新..."
        try {
            git -C $localPath fetch 2>&1 | Out-Null
            $updates = git -C $localPath log "HEAD..origin/main" --oneline 2>&1 | Out-String
            if ($updates.Trim()) {
                if ($Yes) {
                    Write-Log INFO "拉取更新..."
                    git -C $localPath pull 2>&1 | Out-Null
                } else {
                    Write-Log WARN "远端有更新: $($updates.Trim())"
                }
            } else {
                Write-Log INFO "Missions 已是最新"
            }
        } catch { }
    }

    $platformTargets = @(
        @{ Platform = "agy";    Target = Join-Path $env:USERPROFILE ".gemini\config\skills" }
        @{ Platform = "codex";  Target = Join-Path $env:USERPROFILE ".codex\skills" }
        @{ Platform = "claude"; Target = Join-Path $env:USERPROFILE ".agents\skills" }
    )

    foreach ($pt in $platformTargets) {
        $label = "missions→$($pt.Platform)"
        Write-Log INFO "安装 missions → $($pt.Platform)..."
        if (-not (Test-Path $pt.Target)) { New-Item -ItemType Directory -Path $pt.Target -Force | Out-Null }
        $installed = 0; $skipped = 0

        foreach ($mdir in $missionDirs) {
            $srcPath = Join-Path $localPath $mdir
            $dstPath = Join-Path $pt.Target $mdir
            if (Test-Path $srcPath) {
                if (Test-Path $dstPath) {
                    Write-Log INFO "  SKIPPED: $mdir (已存在)"
                    $skipped++
                } else {
                    Copy-Item $srcPath $dstPath -Recurse
                    $installed++
                }
            } else {
                Write-Log WARN "  未找到: $srcPath"
            }
        }

        $total = $installed + $skipped
        $Script:ComponentStatus[$label] = "OK"
        $Script:ComponentVersion[$label] = "$total dirs"
        Write-Log INFO "  ${label}: $installed 新安装, $skipped 已存在"
    }
}

# ═══════════════════════════════════════════════════════════════
#  Phase 5: 权限层 — Codex config.toml
# ═══════════════════════════════════════════════════════════════

function Invoke-Phase5 {
    Show-PhaseBanner 5 "权限层 — Codex config.toml"
    Refresh-Path

    $configPath = Join-Path $env:USERPROFILE ".codex\config.toml"
    $configDir = Split-Path $configPath -Parent
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

    $currentApproval = ""
    $currentSandbox = ""
    $currentMultiAgent = ""

    if (Test-Path $configPath) {
        $content = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
        if ($content -match 'approval_policy\s*=\s*"?([^"\r\n]+)"?') { $currentApproval = $Matches[1].Trim() }
        if ($content -match 'sandbox_mode\s*=\s*"?([^"\r\n]+)"?') { $currentSandbox = $Matches[1].Trim() }
        if ($content -match 'multi_agent\s*=\s*(\S+)') { $currentMultiAgent = $Matches[1].Trim() }
    }

    $targetApproval = "never"
    $targetSandbox = "danger-full-access"
    $targetMultiAgent = "true"

    $changesNeeded = ($currentApproval -ne $targetApproval) -or ($currentSandbox -ne $targetSandbox) -or ($currentMultiAgent -ne $targetMultiAgent)

    if (-not $changesNeeded) {
        Write-Log INFO "所有权限配置已是目标值"
        $Script:ComponentStatus["approval_policy"] = "OK"
        $Script:ComponentVersion["approval_policy"] = ""
        $Script:ComponentStatus["sandbox_mode"] = "OK"
        $Script:ComponentVersion["sandbox_mode"] = ""
        $Script:ComponentStatus["multi_agent"] = "OK"
        $Script:ComponentVersion["multi_agent"] = ""
        return
    }

    Write-Host ""
    Write-Host "⚠ WARNING: 以下修改会降低 Codex 安全限制" -ForegroundColor Red
    Write-Host ""
    if ($currentApproval -ne $targetApproval) {
        Write-Host "  Current approval_policy = `"$currentApproval`"  →  Target: `"$targetApproval`""
    }
    if ($currentSandbox -ne $targetSandbox) {
        Write-Host "  Current sandbox_mode    = `"$currentSandbox`"  →  Target: `"$targetSandbox`""
    }
    if ($currentMultiAgent -ne $targetMultiAgent) {
        Write-Host "  Current multi_agent     = $currentMultiAgent  →  Target: $targetMultiAgent"
    }
    Write-Host ""
    Write-Host "  This means Codex will execute commands without approval"
    Write-Host "  and have full access to your filesystem and network."
    Write-Host ""
    Write-Host "  Only use in git-managed workspaces without production secrets." -ForegroundColor Yellow
    Write-Host ""

    $apply = $false
    if ($Yes -and $ForcePermissions) {
        Write-Log INFO "强制权限模式，跳过确认"
        $apply = $true
    } else {
        Write-Host "Apply permission changes? [y/N]"
        $answer = Read-Host
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = "N" }
        if ($answer.ToLower() -in "y","yes") { $apply = $true }
    }

    if ($apply) {
        Backup-File $configPath

        if (-not (Test-Path $configPath)) {
            @"
approval_policy = "$targetApproval"
sandbox_mode = "$targetSandbox"

[features]
multi_agent = $targetMultiAgent
"@ | Set-Content $configPath -Encoding UTF8
        } else {
            $content = Get-Content $configPath -Raw

            if ($content -match 'approval_policy\s*=') {
                $content = $content -replace 'approval_policy\s*=\s*"?[^"\r\n]+"?', "approval_policy = `"$targetApproval`""
            } else {
                $content += "`napproval_policy = `"$targetApproval`""
            }

            if ($content -match 'sandbox_mode\s*=') {
                $content = $content -replace 'sandbox_mode\s*=\s*"?[^"\r\n]+"?', "sandbox_mode = `"$targetSandbox`""
            } else {
                $content += "`nsandbox_mode = `"$targetSandbox`""
            }

            if ($content -match 'multi_agent\s*=') {
                $content = $content -replace 'multi_agent\s*=\s*\S+', "multi_agent = $targetMultiAgent"
            } else {
                if ($content -match '\[features\]') {
                    $content = $content -replace '(\[features\])', "`$1`nmulti_agent = $targetMultiAgent"
                } else {
                    $content += "`n`n[features]`nmulti_agent = $targetMultiAgent"
                }
            }

            $content | Set-Content $configPath -Encoding UTF8
        }

        Write-Log INFO "权限配置已更新"
        $Script:ComponentStatus["approval_policy"] = "OK"
        $Script:ComponentVersion["approval_policy"] = ""
        $Script:ComponentStatus["sandbox_mode"] = "OK"
        $Script:ComponentVersion["sandbox_mode"] = ""
        $Script:ComponentStatus["multi_agent"] = "OK"
        $Script:ComponentVersion["multi_agent"] = ""
    } else {
        Write-Log WARN "用户跳过权限配置"
        $Script:ComponentStatus["approval_policy"] = "SKIPPED"
        $Script:ComponentVersion["approval_policy"] = ""
        $Script:ComponentStatus["sandbox_mode"] = "SKIPPED"
        $Script:ComponentVersion["sandbox_mode"] = ""
        $Script:ComponentStatus["multi_agent"] = "SKIPPED"
        $Script:ComponentVersion["multi_agent"] = ""
    }
}

# ═══════════════════════════════════════════════════════════════
#  Phase 6: 项目结构
# ═══════════════════════════════════════════════════════════════

function Invoke-Phase6 {
    Show-PhaseBanner 6 "项目结构"

    $dirs = @("docs\superpowers\specs", "issues", ".mission")
    foreach ($d in $dirs) {
        $fullPath = Join-Path $Script:ScriptDir $d
        if (Test-Path $fullPath) {
            Write-Log INFO "$d\ 已存在 ✅"
        } else {
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
            Write-Log INFO "$d\ 已创建"
        }
        $Script:ComponentStatus["$d/"] = "OK"
        $Script:ComponentVersion["$d/"] = ""
    }

    # AGENTS.md
    $agentsPath = Join-Path $Script:ScriptDir "AGENTS.md"
    $agentsTemplate = @"
# 项目 Agent 规则

## 工具分工
- 讨论、需求澄清、spec 设计：首选 Claude/AGY（Opus 4.6）+ Superpowers + Missions
- 降级讨论：Codex + Superpowers + Missions
- 长时间执行：Codex ``/goal @issues/*.csv``
- 方法层：仅使用 Superpowers

## 工作流路由
- 简单查询/审查：直接回答
- 复杂任务：先 spec → mission 转 CSV → /goal 执行
- 中断恢复：`$mission continue
- 代码库理解：优先查 Graphify

## 硬门禁
- 不虚构验证证据
- 低等级证据不包装为高等级结论
- 变更后必须运行验证并写明结果
- 不写入密钥，不运行破坏性命令

## 长任务完成定义
- 四状态闭环：dev_state + review_initial + review_regression + git_state
- REVIEW 行对齐原始目标
- 无法验证项必须记录 validation_gap 和 risk
"@

    if (Test-Path $agentsPath) {
        if ($Yes) {
            Write-Log INFO "AGENTS.md 已存在，-Yes 模式默认跳过"
        } else {
            Write-Host ""
            Write-Host "AGENTS.md 已存在，如何处理？" -ForegroundColor White
            Write-Host "  [1] 覆盖"
            Write-Host "  [2] 追加"
            Write-Host "  [3] 跳过"
            Write-Host ""
            Write-Host "选择 [1/2/3]:"
            $choice = Read-Host
            switch ($choice) {
                "1" {
                    Backup-File $agentsPath
                    $agentsTemplate | Set-Content $agentsPath -Encoding UTF8
                    Write-Log INFO "AGENTS.md 已覆盖"
                }
                "2" {
                    "`n---`n" | Add-Content $agentsPath -Encoding UTF8
                    $agentsTemplate | Add-Content $agentsPath -Encoding UTF8
                    Write-Log INFO "AGENTS.md 已追加"
                }
                default {
                    Write-Log INFO "AGENTS.md 跳过"
                }
            }
        }
    } else {
        $agentsTemplate | Set-Content $agentsPath -Encoding UTF8
        Write-Log INFO "AGENTS.md 已生成"
    }
    $Script:ComponentStatus["AGENTS.md"] = "OK"
    $Script:ComponentVersion["AGENTS.md"] = ""
}

# ═══════════════════════════════════════════════════════════════
#  Phase 7: 验收
# ═══════════════════════════════════════════════════════════════

function Get-StatusSymbol {
    param([string]$Status)
    switch ($Status) {
        "OK"      { return "✅ OK" }
        "UPDATE"  { return "⚠️ UPDATE" }
        "FAIL"    { return "❌ FAIL" }
        "BLOCKED" { return "🚫 BLOCKED" }
        "SKIPPED" { return "⏭️ SKIPPED" }
        default   { return "? $Status" }
    }
}

function Invoke-Phase7 {
    Show-PhaseBanner 7 "验收"

    $layers = @(
        @{ Name = "基础环境"; Components = @("git","node","npm","python3","pip","uv","codex","claude","agy") }
        @{ Name = "记忆层";   Components = @("graphify","graphify→codex","graphify→agy","graphify→claude","graphify-out/") }
        @{ Name = "方法层";   Components = @("superpowers→agy","superpowers→codex","superpowers→claude") }
        @{ Name = "执行层";   Components = @("missions→agy","missions→codex","missions→claude") }
        @{ Name = "权限层";   Components = @("approval_policy","sandbox_mode","multi_agent") }
        @{ Name = "项目结构"; Components = @("docs\superpowers\specs/","issues/",".mission/","AGENTS.md") }
    )

    $okCount = 0; $updateCount = 0; $failCount = 0; $blockedCount = 0; $skippedCount = 0

    Write-Host "  ┌─────────────┬──────────────────────┬──────────────┬───────────┐"
    Write-Host "  │ Layer       │ Component            │ Status       │ Version   │"
    Write-Host "  ├─────────────┼──────────────────────┼──────────────┼───────────┤"

    $firstLayer = $true
    foreach ($layer in $layers) {
        if (-not $firstLayer) {
            Write-Host "  ├─────────────┼──────────────────────┼──────────────┼───────────┤"
        }
        $firstLayer = $false
        $firstInLayer = $true

        foreach ($comp in $layer.Components) {
            $status = if ($Script:ComponentStatus.ContainsKey($comp)) { $Script:ComponentStatus[$comp] } else { "SKIPPED" }
            $version = if ($Script:ComponentVersion.ContainsKey($comp)) { $Script:ComponentVersion[$comp] } else { "" }
            $sym = Get-StatusSymbol $status

            switch ($status) {
                "OK"      { $okCount++ }
                "UPDATE"  { $updateCount++ }
                "FAIL"    { $failCount++ }
                "BLOCKED" { $blockedCount++ }
                "SKIPPED" { $skippedCount++ }
            }

            $layerCol = ""
            if ($firstInLayer) {
                $layerCol = $layer.Name
                $firstInLayer = $false
            }

            Write-Host ("  │ {0,-11} │ {1,-20} │ {2,-12} │ {3,-9} │" -f $layerCol, $comp, $sym, $version)
        }
    }

    Write-Host "  └─────────────┴──────────────────────┴──────────────┴───────────┘"
    Write-Host ""
    Write-Host "  Summary: $okCount OK / $updateCount UPDATE / $failCount FAIL / $blockedCount BLOCKED / $skippedCount SKIPPED" -ForegroundColor White
    Write-Host ""

    if ($updateCount -gt 0) {
        Write-Host "  ⚠ 可更新项：" -ForegroundColor Yellow
        foreach ($key in $Script:ComponentStatus.Keys) {
            if ($Script:ComponentStatus[$key] -eq "UPDATE") {
                Write-Host "    ${key}: 当前 $($Script:ComponentVersion[$key])"
            }
        }
        Write-Host ""
    }

    if ($failCount -gt 0) {
        Write-Host "  ❌ 失败项：" -ForegroundColor Red
        foreach ($key in $Script:ComponentStatus.Keys) {
            if ($Script:ComponentStatus[$key] -eq "FAIL") {
                Write-Host "    $key"
            }
        }
        Write-Host ""
    }

    # Generate report
    New-Report

    if ($failCount -eq 0 -and $blockedCount -eq 0) {
        Write-Host "  ✅ 环境就绪！请重启 Claude Code / AGY / Codex 使新配置生效。" -ForegroundColor Green
    }
}

function New-Report {
    $reportFile = Join-Path $Script:ScriptDir "pmf-init-report-${Script:Timestamp}.md"
    $osInfo = "$([Environment]::OSVersion.Platform)/$([Environment]::OSVersion.Version)/$([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"

    $mode = "交互式"
    if ($Yes -and $ForcePermissions) { $mode = "-Yes -ForcePermissions" }
    elseif ($Yes) { $mode = "-Yes" }

    $report = @"
# PerPetual Motion FrameWork 环境配置报告

> 生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
> 平台: $osInfo
> 模式: $mode

## 状态总览

| 层 | 组件 | 状态 | 版本 | 备注 |
|---|---|---|---|---|
"@

    $layers = @(
        @{ Name = "基础环境"; Components = @("git","node","npm","python3","pip","uv","codex","claude","agy") }
        @{ Name = "记忆层";   Components = @("graphify","graphify→codex","graphify→agy","graphify→claude","graphify-out/") }
        @{ Name = "方法层";   Components = @("superpowers→agy","superpowers→codex","superpowers→claude") }
        @{ Name = "执行层";   Components = @("missions→agy","missions→codex","missions→claude") }
        @{ Name = "权限层";   Components = @("approval_policy","sandbox_mode","multi_agent") }
        @{ Name = "项目结构"; Components = @("docs\superpowers\specs/","issues/",".mission/","AGENTS.md") }
    )

    foreach ($layer in $layers) {
        foreach ($comp in $layer.Components) {
            $status = if ($Script:ComponentStatus.ContainsKey($comp)) { $Script:ComponentStatus[$comp] } else { "SKIPPED" }
            $version = if ($Script:ComponentVersion.ContainsKey($comp)) { $Script:ComponentVersion[$comp] } else { "" }
            $report += "`n| $($layer.Name) | $comp | $status | $version | |"
        }
    }

    $report += "`n`n## 可更新项`n"
    $hasUpdates = $false
    foreach ($key in $Script:ComponentStatus.Keys) {
        if ($Script:ComponentStatus[$key] -eq "UPDATE") {
            $report += "- ${key}: $($Script:ComponentVersion[$key])`n"
            $hasUpdates = $true
        }
    }
    if (-not $hasUpdates) { $report += "无`n" }

    $report += "`n## 失败项`n"
    $hasFails = $false
    foreach ($key in $Script:ComponentStatus.Keys) {
        if ($Script:ComponentStatus[$key] -eq "FAIL") {
            $report += "- $key (重试 3 次后失败)`n"
            $hasFails = $true
        }
    }
    if (-not $hasFails) { $report += "无`n" }

    $report += "`n## 被阻塞项`n"
    $hasBlocked = $false
    foreach ($key in $Script:ComponentStatus.Keys) {
        if ($Script:ComponentStatus[$key] -eq "BLOCKED") {
            $report += "- $key`n"
            $hasBlocked = $true
        }
    }
    if (-not $hasBlocked) { $report += "无`n" }

    $report += "`n## 用户跳过项`n"
    $hasSkipped = $false
    foreach ($key in $Script:ComponentStatus.Keys) {
        if ($Script:ComponentStatus[$key] -eq "SKIPPED") {
            $report += "- $key`n"
            $hasSkipped = $true
        }
    }
    if (-not $hasSkipped) { $report += "无`n" }

    $report += @"

## 备份记录
"@
    if ($Script:BackupRecords.Count -gt 0) {
        foreach ($rec in $Script:BackupRecords) {
            $report += "`n- $rec"
        }
    } else {
        $report += "`n无"
    }

    $report += @"

## 下一步
1. 重启 Claude Code / AGY / Codex
2. 确认 skills 可触发：hello → `$mission continue
3. 运行 graphify . 建立/刷新图谱
4. 开始讨论需求：首选 Claude/AGY，降级 Codex
"@

    $report | Set-Content $reportFile -Encoding UTF8
    Write-Log INFO "报告已生成: $reportFile"
}

# ═══════════════════════════════════════════════════════════════
#  主执行流
# ═══════════════════════════════════════════════════════════════

function Main {
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════╗" -ForegroundColor Blue
    Write-Host "║  PerPetual Motion FrameWork — 环境配置          ║" -ForegroundColor Blue
    Write-Host "╚═══════════════════════════════════════════════════╝" -ForegroundColor Blue
    Write-Host ""

    Refresh-Path

    Invoke-Phase1
    Invoke-Phase2
    Invoke-Phase3
    Invoke-Phase4
    Invoke-Phase5
    Invoke-Phase6
    Invoke-Phase7
}

Main
