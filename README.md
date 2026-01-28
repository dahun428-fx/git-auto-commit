# git-auto-commit

자동으로 변경사항을 분석해 커밋 메시지를 만들고, `yarn lint`와 `yarn build`를 통과한 뒤 커밋하는 Codex 스킬입니다. (push는 하지 않음)

## 주요 기능

- 한국어 커밋 메시지 생성: `MMDD:HHmm - 요약` (Asia/Seoul 기준)
- 상세 변경 요약 생성
- `yarn lint` + `yarn build` 실행 후에만 커밋
- 실패 시 로그 기반 자동 수정 재시도

## 사용 방법

Codex에서 다음처럼 요청하세요:

```
$git-auto-commit 해당 프로젝트 git에 올려줘
```

## 요구 사항

- 프로젝트 루트에 `package.json` 존재
- `yarn` 설치

## 스크립트 직접 실행

PowerShell:

```
.\scripts\commit_with_lint.ps1 -Summary "로그인 UI 개선"
```

옵션 예시:

```
.\scripts\commit_with_lint.ps1 -MaxLintFixAttempts 3 -MaxBuildFixAttempts 2
```

## 비고

- 기본 브랜치는 `develop` 기준으로 동작합니다. 다른 브랜치에서는 경고 후 진행합니다.
- lint/build 실패 시 자동 복구를 시도하며, 최대 재시도 횟수를 초과하면 커밋을 중단합니다.

