import Foundation

/// Tiny in-app localizer. UI strings are written in English and looked up here.
/// The current language is a global mirror of the app setting; views refresh by
/// keying their root on the language (see RootView), so a free `tr()` is enough.
enum I18n {
    static var lang = "English"
    static var isKorean: Bool { lang == "한국어" }

    static func tr(_ en: String) -> String {
        guard isKorean else { return en }
        return ko[en] ?? en
    }

    static let ko: [String: String] = [
        // Tabs / chrome
        "My PRs": "내 PR",
        "Reviews": "리뷰",
        "Settings": "설정",
        "Sync now": "지금 동기화",
        "Check for Updates…": "업데이트 확인…",
        "Quit Peck": "Peck 종료",
        // My PRs
        "No open PRs": "열린 PR 없음",
        "PRs you author will show up here with their review status.": "당신이 올린 PR이 리뷰 상태와 함께 여기에 표시됩니다.",
        "Waiting on:": "대기 중:",
        "Draft": "초안",
        "Conflict": "충돌",
        "Checks": "체크",
        // Quest (Peck world: egg → chick → chicken)
        "Laid": "알 낳음",
        "Hatching": "부화 중",
        "Grown": "닭 다 컸다",
        "Chicken dinner!": "치킨 완성! 🍗",
        "Needs work": "수정 필요",
        "Boss: conflict": "보스: 충돌",
        "approvals": "승인",
        // Reviews
        "No reviews requested": "요청된 리뷰 없음",
        "When someone requests your review, the agent drafts an explanation and a verdict here.":
            "누군가 리뷰를 요청하면, 에이전트가 설명과 평결 초안을 여기에 만들어요.",
        "Let Peck review": "Peck에게 리뷰 맡기기",
        "Peck is reviewing…": "Peck이 리뷰 중…",
        "Review body": "리뷰 본문",
        "Open on GitHub": "GitHub에서 열기",
        "Retry": "다시 시도",
        "Set up the review agent in Settings to enable reviews.": "리뷰를 사용하려면 설정에서 리뷰 에이전트를 구성하세요.",
        // Verdicts
        "Approve": "승인",
        "Request changes": "변경 요청",
        "Comment": "코멘트",
        // Settings — GitHub
        "Connect GitHub": "GitHub 연결",
        "Sign in with GitHub CLI": "GitHub CLI로 로그인",
        "Reuses your existing `gh auth login`. If you're not logged in, run `gh auth login` in a terminal first.":
            "기존 `gh auth login`을 재사용해요. 로그인 안 돼 있으면 터미널에서 `gh auth login` 먼저 실행하세요.",
        "or paste a token instead": "또는 토큰 붙여넣기",
        "Hide token option": "토큰 옵션 숨기기",
        "Create a token on GitHub →": "GitHub에서 토큰 만들기 →",
        "Connect": "연결",
        "GitHub": "GitHub",
        "via gh CLI login": "gh CLI 로그인",
        "via personal access token": "개인 액세스 토큰",
        "Disconnect": "연결 해제",
        // Settings — agent
        "Review agent": "리뷰 에이전트",
        "Using your existing login — no API key needed.": "기존 로그인 사용 — API 키 불필요.",
        "CLI not found on PATH. Install it or pick another backend.": "PATH에서 CLI를 못 찾음. 설치하거나 다른 백엔드를 선택하세요.",
        "Calls the Anthropic API directly. Requires a key (billed to your account).":
            "Anthropic API를 직접 호출해요. 키 필요(계정으로 과금).",
        "Key saved": "키 저장됨",
        "Not set": "미설정",
        "Add key": "키 추가",
        "Replace": "교체",
        "Cancel": "취소",
        "Save": "저장",
        "Save key": "키 저장",
        "Model": "모델",
        "Explanation (shown to you)": "설명 (나에게 표시)",
        "Review posted to GitHub": "GitHub에 올라가는 리뷰",
        // Settings — behavior
        "Behavior": "동작",
        "Auto-review new requests": "새 요청 자동 리뷰",
        "Auto-submit agent verdict": "에이전트 평결 자동 제출",
        "Desktop notifications": "데스크탑 알림",
        "Send test notification": "테스트 알림 보내기",
        "macOS is blocking Peck's notifications. Allow them in System Settings and this goes away.":
            "macOS가 Peck의 알림을 차단하고 있어요. 시스템 설정에서 허용하면 이 안내는 사라져요.",
        "Open System Settings": "시스템 설정 열기",
        // Settings — skills + language
        "Review skills": "리뷰 스킬",
        "Skills are *.md files in ~/Library/Application Support/PRAgent/skills. Add `enabled: false` to a file's frontmatter to disable it.":
            "스킬은 ~/Library/Application Support/PRAgent/skills 의 *.md 파일이에요. 끄려면 frontmatter에 `enabled: false`를 추가하세요.",
        "Reload skills": "스킬 다시 불러오기",
        "Open skills folder": "스킬 폴더 열기",
        "App language": "앱 언어",
        "Anthropic API key": "Anthropic API 키",
    ]
}

/// Localize a UI string.
func tr(_ s: String) -> String { I18n.tr(s) }
