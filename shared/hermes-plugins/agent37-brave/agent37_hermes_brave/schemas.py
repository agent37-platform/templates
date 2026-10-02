BRAVE_WEB_SEARCH_SCHEMA = {
    "name": "brave_web_search",
    "description": "Search the web via the Agent37-managed Brave integration.",
    "parameters": {
        "type": "object",
        "additionalProperties": False,
        "required": ["query"],
        "properties": {
            "query": {
                "type": "string",
                "description": "Search query text.",
            },
            "count": {
                "type": "integer",
                "minimum": 1,
                "maximum": 20,
                "description": "Maximum results to return.",
            },
            "country": {
                "type": "string",
                "description": 'Two-letter country code, for example "US".',
            },
            "searchLang": {
                "type": "string",
                "description": 'Search language, for example "en".',
            },
            "uiLang": {
                "type": "string",
                "description": 'UI language, for example "en-US".',
            },
            "safesearch": {
                "type": "string",
                "enum": ["off", "moderate", "strict"],
                "description": "SafeSearch mode.",
            },
            "freshness": {
                "type": "string",
                "enum": ["pd", "pw", "pm", "py"],
                "description": "Freshness filter: day, week, month, year.",
            },
            "timeoutMs": {
                "type": "integer",
                "minimum": 1,
                "maximum": 120000,
                "description": "Override network timeout for this call.",
            },
        },
    },
}
