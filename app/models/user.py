from sqlalchemy import Column, Integer, String, DateTime, func
from app.database import Base


# 명세서의 users 테이블을 정의한다.
class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    kakao_sub = Column(String, unique=True, nullable=False, index=True)
    nickname = Column(String(20), unique=True, nullable=True)
    icon_id = Column(String(50), nullable=True)
    joined_at = Column(DateTime(timezone=True), server_default=func.now())
    role = Column(String(20), nullable=False, default="USER")
    sanction_level = Column(Integer, nullable=False, default=0)
    upload_blocked_until = Column(DateTime(timezone=True), nullable=True)
    deleted_at = Column(DateTime(timezone=True), nullable=True)