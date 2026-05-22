# Shared in-process state for fallback/non-Redis mode and admin wizard locks.

import threading
from collections import deque
from typing import Any, Dict

users: Dict[str, Dict[str, str]] = {}
claim_queue: deque = deque()
pending_otps: Dict[str, Dict[str, Any]] = {}

ADMIN_SESSIONS: Dict[str, float] = {}
ADMIN_LOGIN_ATTEMPTS: Dict[str, Dict[str, Any]] = {}
WIZARD_DB_LOCK = threading.Lock()
