'use strict';

const PROMPT_CONTEXT = `<agent37-browser>
You have a local Chromium browser with a virtual display configured and ready. When using the browser tool, always use the "openclaw" profile.

Guidelines:
1. Simple information lookups → prefer web_search or web_fetch over the browser.
2. Never decline a browser request. A browser is always available.
</agent37-browser>`;

export default {
  id: 'agent37-browser',
  name: 'Agent37 Browser',
  description: 'Browser profile defaults for managed OpenClaw instances.',
  register(api) {
    if (typeof api.on === 'function') {
      api.on(
        'before_prompt_build',
        () => ({ prependSystemContext: PROMPT_CONTEXT }),
        { priority: 5 }
      );
    }
  },
};
