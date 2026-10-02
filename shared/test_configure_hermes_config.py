#!/usr/bin/env python3
"""Regression coverage for the Hermes managed-config updater. Run: python3 docker/shared/test_configure_hermes_config.py"""
import os
import subprocess
import sys
import tempfile
import unittest

import yaml

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "configure-hermes-config.py")
PROXY_URL = "https://www.agent37.com/api/openclaw/starter-proxy/v1"
STALE_TOKEN = "ocst.r4yxbx892kbge0ozmr." + "a" * 64
OTHER_STALE_TOKEN = "ocst.8aaibgw6q12bjpy56u." + "b" * 64
CURRENT_TOKEN = "ocst.zar4sfnb20n7406u46." + "c" * 64


FRESH_PROFILE_MODEL = {"default": "anthropic/claude-opus-4.6", "provider": "auto",
                       "base_url": "https://openrouter.ai/api/v1"}


def run_updater(config: dict, *, home_files: dict | None = None, extra_env: dict | None = None) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "config.yaml")
        with open(path, "w", encoding="utf-8") as handle:
            yaml.safe_dump(config, handle)
        for name, content in (home_files or {}).items():
            with open(os.path.join(tmp, name), "w", encoding="utf-8") as handle:
                handle.write(content)
        env = {
            **{k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")},
            "HERMES_CONFIG_PATH": path,
            "STARTER_MODEL_ID": "default",
            "STARTER_PROXY_URL": PROXY_URL,
            "STARTER_TOKEN": CURRENT_TOKEN,
            **(extra_env or {}),
        }
        out = subprocess.run([sys.executable, SCRIPT], env=env, check=True, capture_output=True, text=True).stdout
    return yaml.safe_load(out)


class ConfigureHermesConfigTest(unittest.TestCase):
    def test_picker_written_model_block_is_normalized_and_stale_tokens_refreshed(self):
        result = run_updater({
            "model": {"default": "z-ai/glm-5.3", "provider": "custom", "base_url": PROXY_URL,
                      "api_key": STALE_TOKEN, "api_mode": "chat_completions"},
            "custom_providers": [{"name": "Agent37", "base_url": PROXY_URL, "api_key": OTHER_STALE_TOKEN,
                                  "api_mode": "chat_completions", "model": "default", "models": {}}],
            "auxiliary": {"vision": {"provider": "custom", "base_url": PROXY_URL, "api_key": STALE_TOKEN}},
            "platforms": {"whatsapp": {"enabled": True, "home_channel": {"chat_id": "109380670341184@lid"}}},
        })
        self.assertEqual(result["model"], {"default": "z-ai/glm-5.3", "provider": "custom:Agent37",
                                           "api_mode": "chat_completions"})
        self.assertEqual(result["custom_providers"][0]["api_key"], CURRENT_TOKEN)
        self.assertEqual(result["auxiliary"]["vision"]["api_key"], CURRENT_TOKEN)
        self.assertEqual(result["platforms"]["whatsapp"]["home_channel"]["chat_id"], "109380670341184@lid")
        self.assertNotIn(STALE_TOKEN, yaml.safe_dump(result))
        self.assertNotIn(OTHER_STALE_TOKEN, yaml.safe_dump(result))

    def test_customer_own_provider_is_left_alone(self):
        result = run_updater({
            "model": {"default": "anthropic/claude-sonnet-5", "provider": "openrouter"},
            "custom_providers": [{"name": "Agent37", "base_url": PROXY_URL, "api_key": STALE_TOKEN}],
        })
        self.assertEqual(result["model"], {"default": "anthropic/claude-sonnet-5", "provider": "openrouter"})
        self.assertEqual(result["custom_providers"][0]["api_key"], CURRENT_TOKEN)

    def test_fresh_profile_template_auto_provider_is_bootstrapped(self):
        # What `hermes profile create` writes: Hermes resolves `auto` from the customer's own
        # keys only, so without any the profile would answer "No inference provider configured".
        result = run_updater({"model": dict(FRESH_PROFILE_MODEL), "plugins": {"enabled": []}})
        self.assertEqual(result["model"], {"default": "default", "provider": "custom:Agent37"})
        self.assertEqual(result["custom_providers"][0]["api_key"], CURRENT_TOKEN)

    def test_auto_provider_with_own_credentials_is_left_alone(self):
        for label, kwargs in (
            ("env key", {"extra_env": {"OPENROUTER_API_KEY": "sk-or-v1-own"}}),
            ("dotenv key", {"home_files": {".env": "# OPENROUTER_API_KEY=\nOPENAI_API_KEY='sk-own'\n"}}),
            ("oauth login", {"home_files": {"auth.json": '{"version": 2, "providers": {"nous": {"access_token": "x"}}, "active_provider": "nous"}'}}),
            ("credential pool", {"home_files": {"auth.json": '{"version": 2, "providers": {}, "credential_pool": {"openrouter": [{"api_key": "sk-or-v1-pool"}]}}'}}),
        ):
            with self.subTest(label):
                result = run_updater({"model": dict(FRESH_PROFILE_MODEL)}, **kwargs)
                self.assertEqual(result["model"], FRESH_PROFILE_MODEL)

    def test_credentials_hermes_auto_does_not_use_do_not_suppress_bootstrap(self):
        managed = {"default": "default", "provider": "custom:Agent37"}
        for label, kwargs in (
            ("unrelated env key", {"extra_env": {"RESEND_API_KEY": "re_123", "BRAVE_API_KEY": "b"}}),
            ("commented or empty dotenv keys", {"home_files": {".env": "# OPENROUTER_API_KEY=sk-in-a-comment\nOPENAI_API_KEY=\nRESEND_API_KEY=re_123\n"}}),
            ("logged-out auth store", {"home_files": {"auth.json": '{"version": 2, "providers": {"nous": {}}, "active_provider": null}'}}),
            ("malformed auth store", {"home_files": {"auth.json": "{not json"}}),
        ):
            with self.subTest(label):
                result = run_updater({"model": dict(FRESH_PROFILE_MODEL)}, **kwargs)
                self.assertEqual(result["model"], managed)

if __name__ == "__main__":
    unittest.main()
