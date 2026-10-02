from __future__ import annotations

import json
import math
from typing import Any

import httpx

from .config import BraveRuntimeConfig

DEFAULT_TIMEOUT_MS = 30_000
SEARCH_OPTIONAL_FIELDS = ["country", "searchLang", "uiLang", "safesearch", "freshness"]


def _floor_finite_number(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value):
        return int(value)
    return None


def normalize_timeout_ms(value: Any) -> int:
    normalized = _floor_finite_number(value)
    if normalized is None or normalized <= 0:
        return DEFAULT_TIMEOUT_MS
    return min(normalized, 120_000)


def _normalize_count(value: Any) -> int | None:
    normalized = _floor_finite_number(value)
    if normalized is None:
        return None
    return max(1, min(20, normalized))


def _optional_string(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed or None


def normalize_search_payload(args: dict[str, Any] | None) -> dict[str, Any]:
    safe_args = args or {}
    query = _optional_string(safe_args.get("query"))
    if not query:
        raise ValueError("Missing required parameter: query")

    payload: dict[str, Any] = {"query": query}

    count = _normalize_count(safe_args.get("count"))
    if count is not None:
        payload["count"] = count

    for key in SEARCH_OPTIONAL_FIELDS:
        value = _optional_string(safe_args.get(key))
        if value:
            payload[key] = value

    return payload


def _string_field(entry: dict[str, Any], key: str) -> str:
    value = entry.get(key)
    return value if isinstance(value, str) else ""


def normalize_search_results(result: dict[str, Any] | None) -> dict[str, Any]:
    payload = result or {}
    raw_web = payload.get("web")
    web = raw_web if isinstance(raw_web, dict) else {}
    raw_results = web.get("results")
    entries = raw_results if isinstance(raw_results, list) else []

    normalized_results = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        item = {key: _string_field(entry, key) for key in ("title", "url", "description", "age", "language")}
        if item["title"] or item["url"]:
            normalized_results.append(item)

    return {
        "count": len(normalized_results),
        "results": normalized_results,
    }


async def call_brave_proxy(
    config: BraveRuntimeConfig,
    payload: dict[str, Any],
    timeout_ms: int,
) -> dict[str, Any]:
    timeout = httpx.Timeout(timeout_ms / 1000.0)
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
        response = await client.post(
            config.proxy_url,
            headers={
                "Authorization": f"Bearer {config.starter_token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            json=payload,
        )

    raw = response.text
    try:
        parsed = json.loads(raw) if raw else None
    except json.JSONDecodeError as exc:
        if response.is_success:
            raise RuntimeError("Brave proxy returned a non-JSON response") from exc
        parsed = None

    if not response.is_success:
        message = None
        if isinstance(parsed, dict):
            error = parsed.get("error")
            if isinstance(error, str) and error.strip():
                message = error.strip()
        raise RuntimeError(message or f"Brave proxy request failed with status {response.status_code}")

    if isinstance(parsed, dict):
        return parsed
    raise RuntimeError("Brave proxy returned a non-JSON response")
