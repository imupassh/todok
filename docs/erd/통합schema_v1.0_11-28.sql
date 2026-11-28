-- =============================================================
-- 토독(Todok) 백엔드 통합 스키마 (v1.0)
-- 작성일: 2026-11-28 / 개발자 1(회원·인증·낭독) + 개발자 2(편지·운영자) 통합
-- 기준: MoSCoW v4.0 · PRD v4.0 · IA+Depth v3.0 · FlowChart v3.0 · API 명세서 v1.0
-- DBMS: PostgreSQL / 시간 TIMESTAMPTZ / enum = VARCHAR+CHECK(D-3)
--
-- 통합 결정(통합ERD_v1.0_11-28.md §0 참조):
--   D-2 노출 콘텐츠(readings/letters/letter_requests)에 public_id UUID
--   D-4 편지 STT는 stt_jobs(target_type=LETTER) 재사용, 결과는 대상 stt_text
--   D-5 review_queue는 STT 미저장, filter_result만
--   D-6 다형참조 (target_type,target_id) 패턴 통일 (DB FK 불가, 앱 무결성)
--   D-7 reactions 공용 1테이블 (편지 포함)
--   D-8 sanctions는 users 삭제와 무관하게 보존 (cascade 미적용)
-- =============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()

-- ============================================================
-- A. 개발자 1 — 회원 · 인증 · 낭독
-- ============================================================

CREATE TABLE users (
    id                  BIGSERIAL PRIMARY KEY,
    kakao_id            BIGINT      NOT NULL UNIQUE,      -- 탈퇴 시 해시로 대체 보관
    nickname            VARCHAR(10),                     -- 온보딩 전 NULL
    avatar_code         VARCHAR(20),
    profile_completed_at TIMESTAMPTZ,                    -- NULL이면 온보딩 미완료
    invite_code         VARCHAR(12) UNIQUE,              -- Should (P-05)
    last_login_at       TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_users_nickname_lower ON users (lower(nickname));

CREATE TABLE policies (
    id           BIGSERIAL PRIMARY KEY,
    type         VARCHAR(16) NOT NULL CHECK (type IN ('TERMS','PRIVACY','MARKETING')),
    version      VARCHAR(20) NOT NULL,
    title        VARCHAR(255) NOT NULL,
    content      TEXT        NOT NULL,
    is_required  BOOLEAN     NOT NULL DEFAULT TRUE,
    is_current   BOOLEAN     NOT NULL DEFAULT FALSE,
    effective_at TIMESTAMPTZ NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (type, version)
);
-- type당 현재 버전 1개 (부분 유니크)
CREATE UNIQUE INDEX uq_policies_current ON policies (type) WHERE is_current;

CREATE TABLE consents (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    policy_id  BIGINT      NOT NULL REFERENCES policies(id),
    agreed     BOOLEAN     NOT NULL,
    agreed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, policy_id)
);

CREATE TABLE refresh_tokens (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    family_id  UUID        NOT NULL,                     -- 재사용 감지 시 family 전체 폐기
    token_hash VARCHAR(64) NOT NULL UNIQUE,              -- SHA-256
    device_id  VARCHAR(100),
    expires_at TIMESTAMPTZ NOT NULL,
    used_at    TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_refresh_tokens_family ON refresh_tokens (family_id);

CREATE TABLE passages (
    id             BIGSERIAL PRIMARY KEY,
    text           VARCHAR(500) NOT NULL,
    category       VARCHAR(20)  NOT NULL,                -- 명언/시/소설 등
    mood           VARCHAR(20),                          -- 난이도/분위기 축
    max_record_sec INT,                                  -- 없으면 settings 기본값
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_passages_filter ON passages (category, mood, is_active);

CREATE TABLE readings (
    id                 BIGSERIAL PRIMARY KEY,
    public_id          UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),  -- D-2
    user_id            BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    passage_id         BIGINT      NOT NULL REFERENCES passages(id),
    audio_key          VARCHAR(255) NOT NULL,
    duration_sec       INT         NOT NULL,             -- 재생 URL 만료 계산
    stt_text           TEXT,                             -- STT 없음 폴백이면 NULL
    status             VARCHAR(16) NOT NULL DEFAULT 'REVIEWING'
                       CHECK (status IN ('REVIEWING','PUBLISHED','REJECTED','WITHDRAWN')),
    is_hidden          BOOLEAN     NOT NULL DEFAULT FALSE,  -- 3인 신고 임시 비공개(A-05)
    reject_reason_code VARCHAR(32),
    published_at       TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ
);
CREATE INDEX idx_readings_feed    ON readings (status, published_at DESC);
CREATE INDEX idx_readings_passage ON readings (passage_id, status, published_at DESC);
CREATE INDEX idx_readings_daily   ON readings (user_id, created_at);

-- 공용: 낭독 + 편지 응원 반응 (D-7)
CREATE TABLE reactions (
    id            BIGSERIAL PRIMARY KEY,
    user_id       BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target_type   VARCHAR(8)  NOT NULL CHECK (target_type IN ('READING','LETTER')),
    target_id     BIGINT      NOT NULL,                  -- 다형 참조(앱 무결성)
    reaction_type VARCHAR(20) NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, target_type, target_id)             -- 사용자당 대상 1개(변경 가능)
);
CREATE INDEX idx_reactions_target ON reactions (target_type, target_id);

CREATE TABLE reading_bookmarks (                         -- Should (H-24)
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reading_id BIGINT      NOT NULL REFERENCES readings(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, reading_id)
);

-- 공용: 낭독 + 편지 STT (D-4)
CREATE TABLE stt_jobs (
    id            BIGSERIAL PRIMARY KEY,
    target_type   VARCHAR(8)  NOT NULL CHECK (target_type IN ('READING','LETTER')),
    target_id     BIGINT      NOT NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING','RUNNING','DONE','FAILED')),
    attempt_count INT         NOT NULL DEFAULT 0,        -- 최대 3회
    next_run_at   TIMESTAMPTZ,
    locked_at     TIMESTAMPTZ,                           -- FOR UPDATE SKIP LOCKED
    rtzr_job_id   VARCHAR(100),
    error_code    VARCHAR(32),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ
    -- 결과 텍스트는 대상의 stt_text에만 기록 (보관 최소화)
);
CREATE INDEX idx_stt_jobs_run    ON stt_jobs (status, next_run_at);
CREATE INDEX idx_stt_jobs_target ON stt_jobs (target_type, target_id);

CREATE TABLE push_tokens (
    id          BIGSERIAL PRIMARY KEY,
    user_id     BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token       VARCHAR(255) NOT NULL UNIQUE,
    platform    VARCHAR(10) NOT NULL DEFAULT 'ANDROID',
    device_id   VARCHAR(100),
    is_active   BOOLEAN     NOT NULL DEFAULT TRUE,       -- UNREGISTERED 시 false
    last_seen_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE notification_settings (
    user_id          BIGINT  PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    reaction_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    letter_enabled   BOOLEAN NOT NULL DEFAULT TRUE,
    notice_enabled   BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE withdrawn_users (
    id           BIGSERIAL PRIMARY KEY,
    kakao_hash   VARCHAR(64) NOT NULL UNIQUE,            -- 재가입 제재 회피 확인
    withdrawn_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    retain_until TIMESTAMPTZ                             -- 활성 제재(D-8) 반영
);

CREATE TABLE job_queue (                                 -- 공통 재시도성 작업
    id         BIGSERIAL PRIMARY KEY,
    job_type   VARCHAR(40) NOT NULL,                     -- WITHDRAW_RETRY/S3_CLEANUP/FCM_SEND/KAKAO_UNLINK
    payload    JSONB,
    status     VARCHAR(10) NOT NULL DEFAULT 'PENDING'
               CHECK (status IN ('PENDING','RUNNING','DONE','FAILED')),
    run_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    attempts   INT         NOT NULL DEFAULT 0,
    locked_at  TIMESTAMPTZ,
    last_error VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_job_queue_run ON job_queue (status, run_at);

-- ============================================================
-- B. 개발자 2 — 편지 · 운영자
-- ============================================================

CREATE TABLE letter_requests (
    id            BIGSERIAL PRIMARY KEY,
    public_id     UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),  -- D-2
    requester_id  BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title         VARCHAR(10) NOT NULL,
    content       VARCHAR(50) NOT NULL,
    status        VARCHAR(16) NOT NULL DEFAULT 'REVIEWING'
                  CHECK (status IN ('REVIEWING','PUBLISHED','REJECTED','CLOSING','CLOSED','EXPIRED')),
    letter_count  INT         NOT NULL DEFAULT 0,        -- 내부용(C-09)
    reject_reason VARCHAR(255),
    published_at  TIMESTAMPTZ,
    expires_at    TIMESTAMPTZ,                           -- published_at + 24h
    deleted_at    TIMESTAMPTZ,                           -- L-09 소프트 삭제
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),    -- 제출 시각(쿨다운 기준)
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_letter_requests_cooldown ON letter_requests (requester_id, created_at DESC);
CREATE INDEX idx_letter_requests_close    ON letter_requests (status, expires_at);
CREATE INDEX idx_letter_requests_list     ON letter_requests (status, published_at);

CREATE TABLE stamps (
    id         BIGSERIAL PRIMARY KEY,
    name       VARCHAR(50)  NOT NULL,
    image_key  VARCHAR(255) NOT NULL,
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
    sort_order INT          NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_stamps_active ON stamps (is_active, sort_order);

CREATE TABLE letters (
    id           BIGSERIAL PRIMARY KEY,
    public_id    UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),     -- D-2
    sender_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    request_id   BIGINT      NOT NULL REFERENCES letter_requests(id),
    stamp_id     BIGINT      NOT NULL REFERENCES stamps(id),
    audio_key    VARCHAR(255) NOT NULL,
    duration_sec INT         NOT NULL CHECK (duration_sec <= 30),
    stt_text     TEXT,                                   -- stt_jobs 결과(D-4)
    status       VARCHAR(16) NOT NULL DEFAULT 'REVIEWING'
                 CHECK (status IN ('REVIEWING','PUBLISHED','REJECTED','WITHDRAWN')),
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),     -- L-04 마감 비교
    delivered_at TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_letters_daily   ON letters (sender_id, submitted_at);
CREATE INDEX idx_letters_request ON letters (request_id, status);
CREATE INDEX idx_letters_status  ON letters (status);

CREATE TABLE mailbox (
    id           BIGSERIAL PRIMARY KEY,
    recipient_id BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    letter_id    BIGINT      NOT NULL UNIQUE REFERENCES letters(id) ON DELETE CASCADE,
    status       VARCHAR(12) NOT NULL DEFAULT 'UNREAD'
                 CHECK (status IN ('UNREAD','READ','BURNED','EXPIRED')),
    opened_at    TIMESTAMPTZ,
    expires_at   TIMESTAMPTZ,                            -- opened_at + 24h
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),     -- 도착 시각
    deleted_at   TIMESTAMPTZ
);
CREATE INDEX idx_mailbox_list   ON mailbox (recipient_id, status, created_at DESC);
CREATE INDEX idx_mailbox_expire ON mailbox (status, expires_at);

CREATE TABLE letter_bookmarks (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    letter_id  BIGINT      NOT NULL REFERENCES letters(id) ON DELETE CASCADE,
    direction  VARCHAR(8)  NOT NULL CHECK (direction IN ('RECEIVED','SENT')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, letter_id)
);
CREATE INDEX idx_letter_bookmarks_user ON letter_bookmarks (user_id, created_at DESC);

CREATE TABLE reports (
    id          BIGSERIAL PRIMARY KEY,
    reporter_id BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target_type VARCHAR(8)  NOT NULL CHECK (target_type IN ('READING','LETTER')),
    target_id   BIGINT      NOT NULL,
    reason_code VARCHAR(32) NOT NULL,
    status      VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                CHECK (status IN ('PENDING','RESOLVED')),
    resolution  VARCHAR(10) CHECK (resolution IN ('NO_ISSUE','ACTIONED')),
    resolved_by BIGINT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at TIMESTAMPTZ,
    UNIQUE (reporter_id, target_type, target_id)         -- D-9 (reporter_id 선두)
);
CREATE INDEX idx_reports_target ON reports (target_type, target_id);
CREATE INDEX idx_reports_queue  ON reports (status, created_at);

-- D-8: users 삭제와 무관하게 보존 → user_id에 FK/cascade 걸지 않음(논리 참조)
CREATE TABLE sanctions (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT      NOT NULL,                     -- 논리 참조 (no FK cascade)
    level      VARCHAR(16) NOT NULL
               CHECK (level IN ('WITHDRAW','WARNING','UPLOAD_BLOCK')),
    report_id  BIGINT      REFERENCES reports(id),
    reason     VARCHAR(255),
    starts_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ends_at    TIMESTAMPTZ,                              -- 7일 제한 해제 일시
    created_by BIGINT      NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_sanctions_user ON sanctions (user_id, ends_at);

CREATE TABLE banned_words (
    id         BIGSERIAL PRIMARY KEY,
    pattern    VARCHAR(255) NOT NULL,
    type       VARCHAR(10) NOT NULL CHECK (type IN ('WORD','PHISHING')),
    is_regex   BOOLEAN     NOT NULL DEFAULT FALSE,
    created_by BIGINT      NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_banned_words_type ON banned_words (type);

CREATE TABLE settings (
    key         VARCHAR(64) PRIMARY KEY,
    value       VARCHAR(255) NOT NULL,
    value_type  VARCHAR(8)  NOT NULL CHECK (value_type IN ('INT','STRING','BOOL','JSON')),
    description VARCHAR(255),
    updated_by  BIGINT,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO settings (key, value, value_type, description) VALUES
  ('daily_upload_limit',             '5',  'INT', 'H-09 하루 낭독 업로드 횟수'),
  ('daily_letter_limit',             '10', 'INT', 'L-04 하루 편지 보내기 횟수'),
  ('request_cooldown_hours',         '24', 'INT', 'L-02 편지 요청 쿨다운'),
  ('letter_duration_sec',            '30', 'INT', '편지 녹음 최대 길이(초)'),
  ('unread_letter_max',              '5',  'INT', 'L-07 안 읽은 편지 최대 수'),
  ('letter_bookmark_max',            '30', 'INT', 'L-10 편지 북마크 최대 수'),
  ('opened_letter_ttl_hours',        '24', 'INT', 'L-06 열람 편지 소멸 시간'),
  ('request_publish_ttl_hours',      '24', 'INT', '요청 게시 유지 시간'),
  ('expired_request_retention_days', '7',  'INT', 'L-09 0통 요청 소프트 삭제 보관(가정)');
-- ('request_closing_soon_hours', ?, 'INT', '마감 임박 기준 — 미정(L-03)')

-- D-5: STT 글자는 대상(readings/letters)의 stt_text를 조인해 표시, 여기 저장 안 함
CREATE TABLE review_queue (
    id                BIGSERIAL PRIMARY KEY,
    target_type       VARCHAR(8)  NOT NULL
                      CHECK (target_type IN ('REQUEST','READING','LETTER')),
    target_id         BIGINT      NOT NULL,
    queue_type        VARCHAR(6)  NOT NULL CHECK (queue_type IN ('TEXT','VOICE')),
    status            VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                      CHECK (status IN ('PENDING','APPROVED','REJECTED')),
    filter_result     JSONB,                             -- 금지어·원문대조·무음
    assigned_admin_id BIGINT,
    decided_by        BIGINT,
    reject_reason     VARCHAR(255),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),-- 대기시간 지표(A-12)
    decided_at        TIMESTAMPTZ
);
CREATE INDEX idx_review_queue_list   ON review_queue (queue_type, status, created_at);
CREATE INDEX idx_review_queue_target ON review_queue (target_type, target_id);

-- ============================= end =============================
