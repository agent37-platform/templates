from __future__ import annotations

from dataclasses import dataclass
import os

CANONICAL_STARTER_TOKEN_ENV = "AGENT37_STARTER_TOKEN"
FALLBACK_STARTER_TOKEN_ENV = "OPENCLAW_STARTER_TOKEN"
CANONICAL_BRAVE_PROXY_URL_ENV = "AGENT37_BRAVE_PROXY_URL"
FALLBACK_BRAVE_PROXY_URL_ENV = "OPENCLAW_BRAVE_PROXY_URL"
PLUGIN_ENABLED_ENV = "AGENT37_HERMES_BRAVE_ENABLED"
# The platform injects the URL above. This is only the floor for an image booted without it;
# it is never derived from another managed service's URL (that mismatch broke Brave for a
# month when the LLM proxy moved hosts).
DEFAULT_BRAVE_PROXY_URL = "https://api.agent37.com/search/brave"


@dataclass(frozen=True)
class BraveRuntimeConfig:
    proxy_url: str
    starter_token: str


def _read_env(*names: str) -> str:
    for name in names:
        value = os.environ.get(name)
        if isinstance(value, str):
            trimmed = value.strip()
            if trimmed:
                return trimmed
    return ""


def _is_truthy(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def is_plugin_enabled() -> bool:
    return _is_truthy(os.environ.get(PLUGIN_ENABLED_ENV, "true"))


def _resolve_proxy_url() -> str:
    return _read_env(CANONICAL_BRAVE_PROXY_URL_ENV, FALLBACK_BRAVE_PROXY_URL_ENV) or DEFAULT_BRAVE_PROXY_URL


_cached_config: BraveRuntimeConfig | None | bool = False


def resolve_runtime_config() -> BraveRuntimeConfig | None:
    global _cached_config
    if _cached_config is not False:
        return _cached_config  # type: ignore[return-value]

    if not is_plugin_enabled():
        _cached_config = None
        return None

    proxy_url = _resolve_proxy_url()
    starter_token = _read_env(
        CANONICAL_STARTER_TOKEN_ENV,
        FALLBACK_STARTER_TOKEN_ENV,
    )
    if not proxy_url or not starter_token:
        return None

    config = BraveRuntimeConfig(proxy_url=proxy_url, starter_token=starter_token)
    _cached_config = config
    return config
