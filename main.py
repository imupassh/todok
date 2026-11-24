# 서버 실행 및 API 등록

from fastapi import FastAPI
from sqlalchemy import text
from app.database import engine

app = FastAPI(
    title="토독 API",
    description="토독 백엔드 API 문서",
    version="1.0.0"
)


@app.get("/")
def read_root():
    return {"message": "토독 백엔드 서버 정상 작동"}


@app.get("/health/db")
def check_db():
    # 데이터베이스 연결 상태 확인
    with engine.connect() as connection:
        connection.execute(text("SELECT 1"))
    return {"database": "connected"}