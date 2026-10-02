#!/usr/bin/env python3
import json
import os
import re
import sys
from typing import Any
from urllib.parse import urlparse

import yaml


MANAGED_PLUGIN_IDS = ("agent37-brave", "agent37-composio", "agent37-environment", "agent37-kernel")
MANAGED_CUSTOM_PROVIDER_NAME = "Agent37"
MANAGED_PROVIDER_REF = f"custom:{MANAGED_CUSTOM_PROVIDER_NAME}"
STARTER_TOKEN_RE = re.compile(r"\b(?:ocst|a37st)\.[a-z0-9]{18}\.[0-9a-f]{64}\b")


def refresh_starter_tokens(value: Any, starter_token: str) -> Any:
    if isinstance(value, str):
        return STARTER_TOKEN_RE.sub(starter_token, value)
    if isinstance(value, list):
        return [refresh_starter_tokens(item, starter_token) for item in value]
    if isinstance(value, dict):
        return {key: refresh_starter_tokens(item, starter_token) for key, item in value.items()}
    return value


def apply_managed_provider(model_config: dict[str, Any], config: dict[str, Any]) -> None:
    model_config["provider"] = MANAGED_PROVIDER_REF
    # Hermes' model picker writes the managed endpoint as `provider: custom` with the base URL
    # and the starter token inlined, and seeds a second credential-pool entry from that
    # literal key. The token rotates on every recreate, so the copy goes stale; drop it and
    # let the provider ref resolve through the custom_providers entry refreshed above.
    model_config.pop("base_url", None)
    model_config.pop("api_key", None)
    config["model"] = model_config


def as_object(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def as_non_empty_string(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def as_string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [entry for entry in value if isinstance(entry, str) and entry]


def as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def normalize_base_url(value: Any) -> str:
    raw = as_non_empty_string(value)
    if not raw:
        return ""

    parsed = urlparse(raw)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return ""

    path = parsed.path.rstrip("/")
    if not path.endswith("/v1"):
        path = f"{path}/v1" if path else "/v1"

    normalized = parsed._replace(path=path, params="", query="", fragment="")
    return normalized.geturl()


# The credentials Hermes' `provider: auto` resolution actually reads (hermes_cli/auth.py
# resolve_provider): OPENROUTER_API_KEY / OPENAI_API_KEY from the env (which Hermes fills from
# the home's .env), then the credential pool and the OAuth login in the home's auth.json.
OWN_KEY_ENV_NAMES = ("OPENROUTER_API_KEY", "OPENAI_API_KEY")
ENV_ASSIGNMENT_RE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")


def has_own_provider_credentials(home_dir: str) -> bool:
    """Whether `provider: auto` would resolve to a credential of the customer's own. Only what
    Hermes' chain checks counts: an unrelated *_API_KEY (RESEND_API_KEY, a search key) or a
    stale, logged-out or malformed auth.json would still end in "No inference provider
    configured", so they must not suppress the managed bootstrap."""
    for name in OWN_KEY_ENV_NAMES:
        if os.environ.get(name, "").strip():
            return True
    try:
        with open(os.path.join(home_dir, ".env"), "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = ENV_ASSIGNMENT_RE.match(line)
                if match and match.group(1) in OWN_KEY_ENV_NAMES and match.group(2).strip("\"'"):
                    return True
    except OSError:
        pass
    try:
        with open(os.path.join(home_dir, "auth.json"), "r", encoding="utf-8") as handle:
            auth_store = json.load(handle)
    except (OSError, ValueError):
        return False
    if not isinstance(auth_store, dict):
        return False
    if as_non_empty_string(auth_store.get("active_provider")):
        return True
    return bool(as_object(auth_store.get("credential_pool")))


def set_model_value(model_config: dict[str, Any], model_id: str) -> None:
    if "default" in model_config or "model" not in model_config:
        model_config["default"] = model_id
        return
    model_config["model"] = model_id


def get_model_value(model_config: dict[str, Any]) -> str:
    return as_non_empty_string(model_config.get("default")) or as_non_empty_string(
        model_config.get("model")
    )


def upsert_managed_custom_provider(
    config: dict[str, Any],
    *,
    provider_name: str,
    base_url: str,
    api_key: str,
    model_id: str,
) -> None:
    custom_providers = as_list(config.get("custom_providers"))

    target_index = None
    for index, entry in enumerate(custom_providers):
        if isinstance(entry, dict) and as_non_empty_string(entry.get("name")) == provider_name:
            target_index = index
            break

    existing = as_object(custom_providers[target_index]) if target_index is not None else {}
    merged = {
        **existing,
        "name": provider_name,
        "base_url": normalize_base_url(base_url),
        "api_key": api_key,
        "api_mode": "chat_completions",
        # Hermes' /model picker live-probes {base_url}/models with the api_key,
        # so the full managed catalog surfaces without a static list here; the
        # "model" field is only the default selection.
        "model": model_id,
        # An empty mapping, not a missing key: after a probe Hermes caches the
        # discovered catalog back into "models", and the gateway then resolves
        # any id in that cache to this endpoint, overriding the customer's own
        # model.provider and billing their traffic to us. Hermes never rewrites
        # a mapping (that shape is per-model metadata, not an allowlist), so the
        # picker keeps live-probing and the cache can never come back.
        "models": {},
    }

    if target_index is None:
        custom_providers.append(merged)
    else:
        custom_providers[target_index] = merged

    config["custom_providers"] = custom_providers


config_path = os.environ.get("HERMES_CONFIG_PATH", "").strip()
meta_path = os.environ.get("META_PATH", "").strip()
starter_model_id = os.environ.get("STARTER_MODEL_ID", "default")
starter_proxy_url = normalize_base_url(os.environ.get("STARTER_PROXY_URL", ""))
starter_token = as_non_empty_string(os.environ.get("STARTER_TOKEN"))
has_starter_provider = bool(starter_proxy_url and starter_token)


def _env_truthy(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


brave_enabled = _env_truthy("HERMES_BRAVE_ENABLED")
composio_enabled = _env_truthy("HERMES_COMPOSIO_ENABLED")
perflo_enabled = _env_truthy("HERMES_PERFLO_ENABLED")

if not config_path:
    print("HERMES_CONFIG_PARSE_ERROR HERMES_CONFIG_PATH is required", file=sys.stderr)
    sys.exit(2)

config: dict[str, Any] = {}
try:
    with open(config_path, "r", encoding="utf-8") as handle:
        loaded = yaml.safe_load(handle) or {}
    if not isinstance(loaded, dict):
        print("HERMES_CONFIG_PARSE_ERROR expected top-level mapping", file=sys.stderr)
        sys.exit(2)
    config = loaded
except FileNotFoundError:
    pass
except Exception as exc:
    print(f"HERMES_CONFIG_PARSE_ERROR {exc}", file=sys.stderr)
    sys.exit(2)

model_config = as_object(config.get("model"))
current_model_id = get_model_value(model_config)
current_provider = as_non_empty_string(model_config.get("provider"))
model_bootstrapped = False
managed_runtime_refreshed = False

if has_starter_provider:
    # Any starter token in the file is one of this instance's own, and only the current one
    # authenticates: earlier copies (auxiliary blocks, fallback entries) 401 forever.
    config = refresh_starter_tokens(config, starter_token)
    model_config = as_object(config.get("model"))
    upsert_managed_custom_provider(
        config,
        provider_name=MANAGED_CUSTOM_PROVIDER_NAME,
        base_url=starter_proxy_url,
        api_key=starter_token,
        model_id=starter_model_id,
    )
    is_using_managed_custom_endpoint = current_provider == MANAGED_PROVIDER_REF or (
        current_provider == "custom" and normalize_base_url(model_config.get("base_url")) == starter_proxy_url
    )

    # `provider: auto` is Hermes' untouched template: the config_defaults value, and what
    # `hermes profile create` writes into every new profile. Hermes resolves `auto` from the
    # customer's own credentials only (env keys, the home's .env, an OAuth login), never from
    # custom_providers, so with none of those it means "no provider chosen" and the instance
    # answers "No inference provider configured". Bootstrap the managed provider exactly like
    # an empty config; any credential of their own keeps `auto` untouched.
    home_dir = os.path.dirname(os.path.abspath(config_path))
    is_unresolved_auto = current_provider == "auto" and not has_own_provider_credentials(home_dir)

    if not current_model_id or is_unresolved_auto:
        set_model_value(model_config, starter_model_id)
        apply_managed_provider(model_config, config)
        model_bootstrapped = True
    elif is_using_managed_custom_endpoint:
        apply_managed_provider(model_config, config)
        managed_runtime_refreshed = True
elif model_config:
    config["model"] = model_config

plugins_config = as_object(config.get("plugins"))
existing_enabled = [
    plugin for plugin in as_string_list(plugins_config.get("enabled")) if plugin not in MANAGED_PLUGIN_IDS
]

existing_enabled.append("agent37-environment")
if brave_enabled:
    existing_enabled.append("agent37-brave")

plugins_config["enabled"] = existing_enabled
plugins_config.pop("disabled", None)
config["plugins"] = plugins_config

# Configure Hermes' native Composio MCP server with starter-token authentication. The control
# plane injects the canonical URL (AGENT37_COMPOSIO_MCP_URL); without it there is no valid
# endpoint to write, so omit the entry rather than derive a URL.
composio_mcp_url = as_non_empty_string(os.environ.get("AGENT37_COMPOSIO_MCP_URL"))
mcp_servers = as_object(config.get("mcp_servers"))
if composio_enabled and has_starter_provider and composio_mcp_url:
    mcp_servers["composio"] = {
        "url": composio_mcp_url,
        "headers": {"Authorization": f"Bearer {starter_token}"},
    }
else:
    mcp_servers.pop("composio", None)

# Paid tools: one metered pay-per-call server, reached through the same managed proxy and the
# same starter token. The control plane injects the URL only where paid tools apply, so its
# absence is the off switch, not something to derive around.
perflo_mcp_url = as_non_empty_string(os.environ.get("AGENT37_PERFLO_MCP_URL"))
if perflo_enabled and has_starter_provider and perflo_mcp_url:
    mcp_servers["perflo"] = {
        "url": perflo_mcp_url,
        "headers": {"Authorization": f"Bearer {starter_token}"},
    }
else:
    mcp_servers.pop("perflo", None)

if mcp_servers:
    config["mcp_servers"] = mcp_servers
else:
    config.pop("mcp_servers", None)

approvals_config = as_object(config.get("approvals"))
if "mode" not in approvals_config:
    approvals_config["mode"] = "off"
config["approvals"] = approvals_config

# Hermes defaults the browser to the Browser Use CLI whenever uvx can run it, and in a
# sandbox that path can only reach their paid cloud (402). "off" restores the built-in
# browser_* tools, which drive the image's Chromium via the baked agent-browser CLI. Only
# a default: an explicit customer backend choice is preserved.
browser_config = as_object(config.get("browser"))
if not as_non_empty_string(browser_config.get("backend")):
    browser_config["backend"] = "off"
config["browser"] = browser_config

# Image-baked skills (consumer images bake e.g. the agent37-expose skill here); registering the
# directory keeps the skill live from the image instead of a stale copy on the persisted volume.
BAKED_SKILLS_DIR = "/usr/local/lib/hermes/skills"
if os.path.isdir(BAKED_SKILLS_DIR):
    skills_config = as_object(config.get("skills"))
    external_dirs = as_string_list(skills_config.get("external_dirs"))
    if BAKED_SKILLS_DIR not in external_dirs:
        external_dirs.append(BAKED_SKILLS_DIR)
    skills_config["external_dirs"] = external_dirs
    config["skills"] = skills_config

platform_toolsets = as_object(config.get("platform_toolsets"))
if "cron" not in platform_toolsets:
    platform_toolsets["cron"] = ["all"]
config["platform_toolsets"] = platform_toolsets

if meta_path:
    with open(meta_path, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "starterProviderConfigured": has_starter_provider,
                "modelBootstrapped": model_bootstrapped,
                "managedRuntimeRefreshed": managed_runtime_refreshed,
                "preservedModel": bool(current_model_id) and not model_bootstrapped,
                "finalModel": get_model_value(as_object(config.get("model"))) or None,
                "finalProvider": as_non_empty_string(as_object(config.get("model")).get("provider")) or None,
            },
            handle,
            indent=2,
        )
        handle.write("\n")

yaml.safe_dump(config, sys.stdout, sort_keys=False)
