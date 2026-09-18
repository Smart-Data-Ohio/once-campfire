# Vendored Highlight.js

The core and language grammars use Highlight.js **11.9.0**. The BSD 3-Clause license is in `LICENSE` beside this file.

The C, C++, C#, Dockerfile, plaintext, PowerShell, TypeScript, and YAML ES modules in `../languages/` were downloaded unchanged from the official Highlight.js CDN release:

```
https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/es/languages/<language>.min.js
```

They are stored as `<language>.js` and bundled for automatic language detection by `script/code-highlighter/detector.mjs`. Keep grammar versions aligned with the core when updating. Shiki renders the final tokens; Highlight.js is only used to identify unlabelled blocks. No browser request to a third-party CDN is needed at runtime.
