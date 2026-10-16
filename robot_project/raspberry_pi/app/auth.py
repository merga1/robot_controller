"""
auth.py — JWT authentication for the robot API.

Endpoints:
  POST /auth/login   { username, password } → { access_token, role }

Users are configured via environment variables:
  ROBOT_ADMIN_USER / ROBOT_ADMIN_PASS   (default: admin / admin)
  ROBOT_USER_USER  / ROBOT_USER_PASS   (default: user  / user)

TOKEN_TTL: tokens expire after 1 hour (matches the Flutter client expectation).
"""

import os
import time
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from jose import JWTError, jwt
from passlib.context import CryptContext
from pydantic import BaseModel

# ── Config ────────────────────────────────────────────────────────────────────

SECRET_KEY = os.getenv("ROBOT_JWT_SECRET", "change-me-in-production-robot-secret-2024")
ALGORITHM = "HS256"
TOKEN_TTL = timedelta(hours=1)

_pwd_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")

# In-memory user store — extend with a DB if you need more users.
_USERS: dict[str, dict] = {
    os.getenv("ROBOT_ADMIN_USER", "admin"): {
        "hashed": _pwd_ctx.hash(os.getenv("ROBOT_ADMIN_PASS", "admin")),
        "role": "admin",
    },
    os.getenv("ROBOT_USER_USER", "user"): {
        "hashed": _pwd_ctx.hash(os.getenv("ROBOT_USER_PASS", "user")),
        "role": "user",
    },
}

# ── Router ────────────────────────────────────────────────────────────────────

router = APIRouter(prefix="/auth", tags=["auth"])
_bearer = HTTPBearer(auto_error=False)


class LoginRequest(BaseModel):
    username: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    role: str


def _create_token(username: str, role: str) -> str:
    expire = datetime.now(timezone.utc) + TOKEN_TTL
    payload = {"sub": username, "role": role, "exp": expire}
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def _verify_token(token: str) -> dict:
    """Decode and validate a JWT. Raises HTTPException 401 on failure."""
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        return payload
    except JWTError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
        )


@router.post("/login", response_model=TokenResponse)
async def login(req: LoginRequest):
    user = _USERS.get(req.username)
    if not user or not _pwd_ctx.verify(req.password, user["hashed"]):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
        )
    token = _create_token(req.username, user["role"])
    return TokenResponse(access_token=token, role=user["role"])


# ── Dependency ────────────────────────────────────────────────────────────────

def require_auth(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> dict:
    """FastAPI dependency — injects the decoded JWT payload or raises 401."""
    if not creds:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authorization header missing",
        )
    return _verify_token(creds.credentials)


def require_admin(payload: dict = Depends(require_auth)) -> dict:
    """Like require_auth but also enforces admin role."""
    if payload.get("role") != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin role required",
        )
    return payload
