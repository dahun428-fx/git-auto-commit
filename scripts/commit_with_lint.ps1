<#
.SYNOPSIS
  Run lint + build gates, stage all changes, and commit with a Korean one-line message.
  Commit message format: MMdd:HHmm - 메시지 (KST/local time, 24h)
  No push.

  NEW:
  - Detailed change summary printed before commit
  - Build gate (yarn build)
  - Auto-heal loop for lint/build (best-effort auto fixes)

.EXAMPLE
  .\scripts\commit_with_lint.ps1 -Summary "로그인 카드 UI 개선"

.EXAMPLE
  .\scripts\commit_with_lint.ps1
  # Prompts for summary if auto-summary is not confident

.EXAMPLE
  .\scripts\commit_with_lint.ps1 -AutoFix
  # If lint fails, tries `yarn lint --fix` once (legacy)

.EXAMPLE
  .\scripts\commit_with_lint.ps1 -AutoHeal -MaxLintFixAttempts 3 -MaxBuildFixAttempts 2
  # Auto-heal loop enabled (recommended)

.EXAMPLE
  .\scripts\commit_with_lint.ps1 -SkipBuild
  # Skip build gate (not recommended)
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [string]$Summary,

  # Legacy: only for lint --fix once
  [Parameter(Mandatory=$false)]
  [switch]$AutoFix,

  # NEW: enable auto-heal for lint/build failures
  [Parameter(Mandatory=$false)]
  [switch]$AutoHeal = $true,

  [Parameter(Mandatory=$false)]
  [int]$MaxLintFixAttempts = 3,

  [Parameter(Mandatory=$false)]
  [int]$MaxBuildFixAttempts = 2,

  [Parameter(Mandatory=$false)]
  [switch]$SkipBuild,

  [Parameter(Mandatory=$false)]
  [string]$LintCommand = "yarn lint",

  [Parameter(Mandatory=$false)]
  [string]$LintFixCommand = "yarn lint --fix",

  [Parameter(Mandatory=$false)]
  [string]$BuildCommand = "yarn build",

  [Parameter(Mandatory=$false)]
  [switch]$DetailedSummary = $true,

  # Protected-branch safety
  [Parameter(Mandatory=$false)]
  [switch]$ForceProtectedBranch,

  # If true, do not prompt and commit anyway (useful for automation)
  [Parameter(Mandatory=$false)]
  [switch]$NoPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-CommandExists([string]$cmd) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $cmd"
  }
}

function Exec([string]$title, [string]$command) {
  Write-Host "`n== $title ==" -ForegroundColor Cyan
  Write-Host $command -ForegroundColor DarkGray
  cmd /c $command
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed ($LASTEXITCODE): $command"
  }
}

function Exec-Capture([string]$title, [string]$command) {
  Write-Host "`n== $title ==" -ForegroundColor Cyan
  Write-Host $command -ForegroundColor DarkGray

  # Capture stdout+stderr
  $out = cmd /c "$command 2>&1"
  $code = $LASTEXITCODE
  return [pscustomobject]@{ ExitCode = $code; Output = ($out | Out-String) }
}

function Get-CurrentBranch {
  $b = (git rev-parse --abbrev-ref HEAD) 2>$null
  return ($b | Out-String).Trim()
}

function Get-RepoStatusPorcelain {
  $s = (git status --porcelain) 2>$null
  return ($s | Out-String).TrimEnd()
}

function Get-ChangedFiles {
  # includes staged+unstaged; we are going to stage all anyway
  $lines = (git status --porcelain) 2>$null
  $files = @()
  foreach ($line in $lines) {
    if ($null -eq $line) { continue }
    $t = ($line | Out-String).TrimEnd()
    if ($t.Length -lt 4) { continue }
    # format: XY <path>
    $path = $t.Substring(3).Trim()
    if ($path -and $path -ne "") { $files += $path }
  }
  return $files
}

function Warn-SensitiveFiles([string[]]$files) {
  $patterns = @(
    "^\.env(\..+)?$",
    "\.pem$",
    "\.p12$",
    "\.keystore$",
    "\.jks$",
    "id_rsa$",
    "secrets?\.?json$",
    "config\.local\.",
    "dist\/",
    "build\/",
    "\.log$"
  )

  $hits = @()
  foreach ($f in $files) {
    foreach ($p in $patterns) {
      if ($f -match $p) { $hits += $f; break }
    }
  }

  if ($hits.Count -gt 0) {
    Write-Host "`n[경고] 민감/산출물로 의심되는 파일이 포함될 수 있어요:" -ForegroundColor Yellow
    $hits | Sort-Object -Unique | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
    Write-Host "커밋에 포함해도 되는지 꼭 확인하세요." -ForegroundColor Yellow
  }
}

function Get-AutoSummary([string[]]$files) {
  if ($files.Count -eq 0) { return $null }

  $lower = $files | ForEach-Object { $_.ToLowerInvariant() }

  $hasUI = $lower | Where-Object { $_ -match "(component|components|ui|view|page|pages|screen|screens|\.tsx$|\.jsx$|\.css$|\.scss$|\.tailwind|\.html$)" }
  $hasAPI = $lower | Where-Object { $_ -match "(api|apis|service|services|client|fetch|axios|bff|controller|route|routes)" }
  $hasState = $lower | Where-Object { $_ -match "(store|zustand|recoil|redux|context|atom)" }
  $hasTest = $lower | Where-Object { $_ -match "(test|tests|__tests__|spec|\.test\.|\.spec\.)" }
  $hasDocs = $lower | Where-Object { $_ -match "(readme|docs|\.md$)" }
  $hasConfig = $lower | Where-Object { $_ -match "(\.yml$|\.yaml$|\.json$|\.toml$|\.env|config|settings|eslint|prettier|tsconfig|vite|next\.config|webpack)" }
  $hasBugFixHint = $lower | Where-Object { $_ -match "(fix|bug|hotfix|patch)" }

  if ($hasBugFixHint.Count -gt 0) { return "버그 수정" }
  if ($hasTest.Count -gt 0 -and $files.Count -le 5) { return "테스트 보강" }
  if ($hasDocs.Count -gt 0 -and $files.Count -le 5) { return "문서 업데이트" }
  if ($hasConfig.Count -gt 0 -and $files.Count -le 6) { return "설정 정리" }
  if ($hasAPI.Count -gt 0 -and $hasUI.Count -gt 0) { return "UI/API 연동 개선" }
  if ($hasUI.Count -gt 0) { return "UI 개선" }
  if ($hasAPI.Count -gt 0) { return "API 로직 개선" }
  if ($hasState.Count -gt 0) { return "상태관리 로직 개선" }

  return "작업 반영"
}

function Get-CommitPrefix {
  return (Get-Date).ToString("MMdd:HHmm")
}

function Get-DetailedChangeSummary([string[]]$files) {
  # Best-effort, human friendly summary from git diff/stat
  $summary = New-Object System.Collections.Generic.List[string]

  $stat = (git diff --stat) 2>$null
  $statText = ($stat | Out-String).Trim()

  $summary.Add("[상세 변경 요약]")
  if ($files.Count -gt 0) {
    $summary.Add("- 변경 파일 수: $($files.Count)개")
  }

  if ($statText) {
    $summary.Add("- 변경 규모(요약):")
    foreach ($line in $statText.Split("`n")) {
      $t = $line.TrimEnd()
      if ($t) { $summary.Add("  - $t") }
    }
  }

  # file-by-file peek (top N lines per file)
  $maxFiles = 10
  $maxLinesPerFile = 12

  $peekFiles = $files | Select-Object -First $maxFiles
  if ($peekFiles.Count -gt 0) {
    $summary.Add("- 핵심 변경 스니펫(상위 $maxFiles개 파일):")
    foreach ($f in $peekFiles) {
      $summary.Add("  - $f")
      $diff = (git diff -- "$f") 2>$null
      $diffText = ($diff | Out-String).Trim()
      if (-not $diffText) {
        $summary.Add("    - (diff 없음 또는 바이너리)")
        continue
      }

      # Extract a few informative lines (avoid huge output)
      $lines = $diffText.Split("`n") |
        Where-Object { $_ -notmatch "^(diff --git|index |---|\+\+\+|@@)" } |
        Where-Object { $_ -match "^[\+\-]" } |
        Select-Object -First $maxLinesPerFile

      if ($lines.Count -eq 0) {
        $summary.Add("    - (변경 라인 추출 실패: 컨텍스트 위주 변경일 수 있음)")
      } else {
        foreach ($l in $lines) {
          $summary.Add("    - $l")
        }
      }
    }

    if ($files.Count -gt $maxFiles) {
      $summary.Add("  - ... (나머지 $($files.Count - $maxFiles)개 파일 생략)")
    }
  }

  return ($summary -join "`n")
}

function Get-FailureHints([string]$output) {
  # Pull key error lines to help fixes (best-effort)
  $lines = ($output -split "`r?`n")
  $picked = New-Object System.Collections.Generic.List[string]

  foreach ($l in $lines) {
    $t = $l.Trim()
    if (-not $t) { continue }
    if ($t -match "(error|ERROR|Failed|failed|TS\d{4}|Cannot find module|Module not found|Parsing error|Unexpected|Type '.*' is not assignable|ESLint)" ) {
      $picked.Add($t)
      if ($picked.Count -ge 25) { break }
    }
  }

  if ($picked.Count -eq 0) {
    return ($lines | Select-Object -Last 25) -join "`n"
  }
  return ($picked -join "`n")
}

function Apply-AIFix([string]$kind, [string]$output) {
  <#
    Best-effort auto-fix strategy.
    - Lint: run lint --fix once if available, and other safe actions can be added here.
    - Build: safe "obvious" fixes are hard without an LLM; this function is a hook.
      You can connect an external AI fixer via environment variable AI_FIX_CMD.
      Example:
        $env:AI_FIX_CMD = "node scripts/ai_fix.mjs"
      That external tool can read logs from stdin and apply patches.
  #>

  Write-Host "`n[AutoHeal] $kind 실패 로그(핵심):" -ForegroundColor Yellow
  Write-Host (Get-FailureHints $output) -ForegroundColor Yellow

  if ($kind -eq "lint") {
    # Try yarn lint --fix if enabled
    if ($AutoFix) {
      Write-Host "`n[AutoHeal] lint --fix 시도..." -ForegroundColor Yellow
      $r = Exec-Capture "Run lint --fix" $LintFixCommand
      if ($r.ExitCode -ne 0) {
        Write-Host "[AutoHeal] lint --fix 실패" -ForegroundColor Yellow
      } else {
        Write-Host "[AutoHeal] lint --fix 성공" -ForegroundColor Green
      }
    }
  }

  # Optional external AI fixer
  $aiFixCmd = $env:AI_FIX_CMD
  if ($aiFixCmd -and $aiFixCmd.Trim().Length -gt 0) {
    Write-Host "`n[AutoHeal] 외부 AI 수정 커맨드 실행: $aiFixCmd" -ForegroundColor Yellow
    try {
      # Pass output via stdin to external tool
      $tmp = New-TemporaryFile
      Set-Content -Path $tmp.FullName -Value $output -Encoding UTF8
      cmd /c "type `"$($tmp.FullName)`" | $aiFixCmd"
      Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
    } catch {
      Write-Host "[AutoHeal] 외부 AI 수정 커맨드 실행 실패: $($_.Exception.Message)" -ForegroundColor Yellow
    }
  } else {
    Write-Host "`n[AutoHeal] 외부 AI 수정 커맨드(AI_FIX_CMD)가 설정되지 않았습니다. (선택 사항)" -ForegroundColor DarkYellow
  }
}

function Run-WithAutoHeal([string]$kind, [string]$command, [int]$maxAttempts) {
  for ($i = 1; $i -le $maxAttempts; $i++) {
    $r = Exec-Capture "Run $kind (attempt $i/$maxAttempts)" $command
    if ($r.ExitCode -eq 0) {
      Write-Host "[OK] $kind 성공" -ForegroundColor Green
      return
    }

    if (-not $AutoHeal) {
      throw "$kind 실패입니다. (AutoHeal 비활성) 로그:`n$($r.Output)"
    }

    Write-Host "`n[AutoHeal] $kind 실패 → 자동 수정 시도 ($i/$maxAttempts)" -ForegroundColor Yellow
    Apply-AIFix $kind $r.Output
  }

  throw "$kind 자동 복구 시도($maxAttempts회) 후에도 실패했습니다. 수동 수정이 필요합니다."
}

# ---- Preflight ----
Assert-CommandExists "git"
Assert-CommandExists "yarn"

# Ensure we're in a git repo
git rev-parse --is-inside-work-tree *> $null

$status = Get-RepoStatusPorcelain
if (-not $status -or $status.Trim().Length -eq 0) {
  Write-Host "변경사항이 없습니다. 커밋할 내용이 없어요." -ForegroundColor Yellow
  exit 0
}

$branch = Get-CurrentBranch
Write-Host "현재 브랜치: $branch" -ForegroundColor Green

# Branch policy
$protected = @("main","master","release","production","prod")
if ($protected -contains $branch) {
  if (-not $ForceProtectedBranch) {
    throw "보호 브랜치($branch)에서 커밋은 위험할 수 있어요. 진행하려면 -ForceProtectedBranch 옵션을 사용하세요."
  } else {
    Write-Host "[경고] 보호 브랜치($branch)에서 강제 진행합니다." -ForegroundColor Yellow
  }
} elseif ($branch -ne "develop") {
  Write-Host "[알림] 기본 브랜치(develop)가 아닙니다. 그래도 진행합니다." -ForegroundColor Yellow
}

$files = Get-ChangedFiles
Write-Host "`n변경 파일($($files.Count)):" -ForegroundColor Cyan
$files | ForEach-Object { Write-Host " - $_" }

Warn-SensitiveFiles $files

if ($DetailedSummary) {
  Write-Host "`n" + (Get-DetailedChangeSummary $files) -ForegroundColor Cyan
}

# Determine summary
if (-not $Summary -or $Summary.Trim().Length -eq 0) {
  $auto = Get-AutoSummary $files
  if ($auto -and $auto.Trim().Length -gt 0) {
    if (-not $NoPrompt) {
      Write-Host "`n자동 요약 제안: $auto" -ForegroundColor Cyan
      $inputSummary = Read-Host "커밋 메시지 요약(Enter=자동요약 사용)"
      if ($inputSummary -and $inputSummary.Trim().Length -gt 0) {
        $Summary = $inputSummary.Trim()
      } else {
        $Summary = $auto
      }
    } else {
      $Summary = $auto
    }
  } else {
    if ($NoPrompt) {
      throw "Summary가 비어있고 자동 요약도 실패했습니다. -Summary를 지정하세요."
    }
    $Summary = (Read-Host "커밋 메시지 요약(한국어 한 줄)").Trim()
    if (-not $Summary -or $Summary.Length -eq 0) {
      throw "Summary는 비어있을 수 없습니다."
    }
  }
}

$prefix = Get-CommitPrefix
$commitMessage = "$prefix - $Summary"
Write-Host "`n커밋 메시지: $commitMessage" -ForegroundColor Green

# ---- Lint gate (with auto-heal) ----
Run-WithAutoHeal "lint" $LintCommand $MaxLintFixAttempts

# ---- Build gate (with auto-heal) ----
if (-not $SkipBuild) {
  Run-WithAutoHeal "build" $BuildCommand $MaxBuildFixAttempts
} else {
  Write-Host "`n[경고] -SkipBuild 옵션으로 빌드 검사를 건너뜁니다. (권장하지 않음)" -ForegroundColor Yellow
}

# ---- Stage & commit (no push) ----
Exec "Stage all changes" "git add -A"

Write-Host "`n스테이징된 변경 요약:" -ForegroundColor Cyan
cmd /c "git diff --cached --stat"

Exec "Commit" ("git commit -m " + ('"' + $commitMessage.Replace('"','\"') + '"'))

Write-Host "`n완료: lint/build 통과 후 커밋만 수행했습니다. (푸시는 수동으로 진행)" -ForegroundColor Green
