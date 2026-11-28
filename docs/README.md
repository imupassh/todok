# 토독 백엔드 설계 문서 (개발자 2 — 편지 · 운영자)

개발자 2(박나현) 담당 도메인의 설계 산출물 모음. 기준 문서: MoSCoW v4.0 · PRD v4.0 · IA+Depth v3.0 · FlowChart v3.0 · API 명세서 v1.0.

## ERD · 스키마 (`erd/`)
| 파일 | 내용 |
| --- | --- |
| [통합ERD_v1.0_11-28.md](erd/통합ERD_v1.0_11-28.md) | 개발자 1·2 전체 23개 테이블 통합 ERD (Mermaid + 테이블 정의 + 통합 결정 D-1~D-10) |
| [통합schema_v1.0_11-28.sql](erd/통합schema_v1.0_11-28.sql) | 통합 PostgreSQL DDL (제약·인덱스·settings 시드 포함) |

## API (`api/`)
| 파일 | 내용 |
| --- | --- |
| [openapi_letters_v0.1_11-27.yaml](api/openapi_letters_v0.1_11-27.yaml) | 편지 앱 API 17개 OpenAPI 3.0.3 (요청·응답·타입, DTO 19개) |
| [개발자2_11-27_API필드정의.md](api/개발자2_11-27_API필드정의.md) | 공통 규약 + 17개 API 필드 체크리스트 + 에러 매핑 요약 |

## 주요 통합 결정 (ERD 문서 §0)
- **public_id UUID**: 외부 노출 콘텐츠(readings·letters·letter_requests) 식별자 (순번 PK 미노출)
- **stt_jobs 공용 재사용**: 편지 STT는 `target_type=LETTER`, 결과는 대상 `stt_text`에만 저장
- **reactions 공용 1테이블**: 낭독·편지 공용
- **sanctions no-cascade 보존**: 탈퇴 후에도 제재 이력 유지
- **enum = VARCHAR + CHECK**, 다형 참조 `(target_type, target_id)` 통일

## 팀 회의 확정 대기
L-04(마감 후 전달) · L-09(0통 처리) · 마감 임박 기준 시간 · STT/제재 보관 기간 · RTZR 약관 — 현재는 계획서 가정값으로 동작.
