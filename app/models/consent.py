
from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, func
from app.database import Base


# 사용자의 약관 및 개인정보처리방침 동의 내역을 저정한다.
class Consent(Base):
    __tablename__ = "consents"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    terms_version = Column(String(20), nullable=False)
    privacy_version = Column(String(20), nullable=False)
    age_over_14 = Column(Boolean, nullable=False)
    agreed_at = Column(DateTime(timezone=True), server_default=func.now())
