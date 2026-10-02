from __future__ import annotations

import json
from typing import Any

from .client import (
    call_brave_proxy,
    normalize_search_payload,
    normalize_search_results,
    normalize_timeout_ms,
)
from .config import resolve_runtime_config


async def brave_web_search(args: dict[str, Any], **kwargs: Any) -> str:
    del kwargs
    config = resolve_runtime_config()
    if config is None:
        return json.dumps({"error": "Brave integration is not configured"})

    try:
        args = args or {}
        timeout_ms = normalize_timeout_ms(args.get("timeoutMs"))
        payload = normalize_search_payload(args)
        response = await call_brave_proxy(config, payload, timeout_ms)
        return json.dumps(normalize_search_results(response))
    except Exception as exc:
        return json.dumps({"error": str(exc)})
