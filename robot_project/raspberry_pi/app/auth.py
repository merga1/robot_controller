"""JWT authentication — FR-AUTH-1 / FR-AUTH-2 / FR-AUTH-3."""
import hashlib
import time
import json
import base64
import hmac
import os
from fastapi import HTTPException, Security
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from .database import get_db

SECRET = os.environ.get("ROBOT_JWT_SECRET", "change-me-in-production")
TOKEN_TTL = 3600  # 1 hour

bearerscheme = HTTPBearer()


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _sign(payload: dict) -> str:
    header = _b64(b'{"alg":"HS256","typ":"JWT"}')
    body = _b64(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(SECRET.encode(), f"{header}.{body}".encode(), hashlib.sha256).digest()
    return f"{header}.{body}.{_b64(sig)}"


def _decode_token(token: str) -> dict:
    if not token or not token.strip():
        raise ValueError("missing token")
    token = token.strip()
    header, body, sig = token.split(".")
    expected = _b64(
        hmac.new(SECRET.encode(), f"{header}.{body}".encode(), hashlib.sha256).digest()
    )
    if not hmac.compare_digest(sig, expected):
        raise ValueError("bad signature")
    payload = json.loads(base64.urlsafe_b64decode(body + "=="))
    if payload["exp"] < time.time():
        raise ValueError("expired")
    return payload


def _verify(token: str) -> dict:
    try:
        return _decode_token(token)
    except Exception as exc:
        raise HTTPException(status_code=401, detail=str(exc))


def verify_token(token: str) -> dict:
    """Verify JWT for WebSocket (raises ValueError, not HTTPException)."""
    return _decode_token(token)


def create_token(username: str, role: str) -> str:
    return _sign({"sub": username, "role": role, "exp": time.time() + TOKEN_TTL})


def verify_password(plain: str, hashed: str) -> bool:
    return hashlib.sha256(plain.encode()).hexdigest() == hashed


def login(username: str, password: str) -> dict:
    conn = get_db()
    row = conn.execute(
        "SELECT username, password_hash, role FROM users WHERE username = ?",
        (username,),
    ).fetchone()
    conn.close()
    if not row or not verify_password(password, row["password_hash"]):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = create_token(row["username"], row["role"])
    return {"access_token": token, "token_type": "bearer", "role": row["role"]}


def require_user(
    creds: HTTPAuthorizationCredentials = Security(bearerscheme),
) -> dict:
    return _verify(creds.credentials)


def require_admin(
    creds: HTTPAuthorizationCredentials = Security(bearerscheme),
) -> dict:
    payload = _verify(creds.credentials)
    if payload.get("role") != "administrator":
        raise HTTPException(status_code=403, detail="Administrator role required")
    return payload
