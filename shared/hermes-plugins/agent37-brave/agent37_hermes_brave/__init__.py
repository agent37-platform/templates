from __future__ import annotations

from .config import resolve_runtime_config
from .schemas import BRAVE_WEB_SEARCH_SCHEMA
from .tools import brave_web_search

TOOLSET_NAME = "plugin_agent37_brave"


def _is_available() -> bool:
    return resolve_runtime_config() is not None


def register(ctx) -> None:
    ctx.register_tool(
        name="brave_web_search",
        toolset=TOOLSET_NAME,
        schema=BRAVE_WEB_SEARCH_SCHEMA,
        handler=brave_web_search,
        check_fn=_is_available,
        is_async=True,
        description=BRAVE_WEB_SEARCH_SCHEMA["description"],
    )
