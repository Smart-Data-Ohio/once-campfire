import hljs from "../../vendor/javascript/highlight.js/core.js"

import bash from "../../vendor/javascript/languages/bash.js"
import c from "../../vendor/javascript/languages/c.js"
import cpp from "../../vendor/javascript/languages/cpp.js"
import csharp from "../../vendor/javascript/languages/csharp.js"
import css from "../../vendor/javascript/languages/css.js"
import diff from "../../vendor/javascript/languages/diff.js"
import dockerfile from "../../vendor/javascript/languages/dockerfile.js"
import go from "../../vendor/javascript/languages/go.js"
import java from "../../vendor/javascript/languages/java.js"
import javascript from "../../vendor/javascript/languages/javascript.js"
import json from "../../vendor/javascript/languages/json.js"
import plaintext from "../../vendor/javascript/languages/plaintext.js"
import powershell from "../../vendor/javascript/languages/powershell.js"
import python from "../../vendor/javascript/languages/python.js"
import ruby from "../../vendor/javascript/languages/ruby.js"
import rust from "../../vendor/javascript/languages/rust.js"
import sql from "../../vendor/javascript/languages/sql.js"
import typescript from "../../vendor/javascript/languages/typescript.js"
import xml from "../../vendor/javascript/languages/xml.js"
import yaml from "../../vendor/javascript/languages/yaml.js"

hljs.registerLanguage("bash", bash)
hljs.registerLanguage("c", c)
hljs.registerLanguage("cpp", cpp)
hljs.registerLanguage("csharp", csharp)
hljs.registerLanguage("css", css)
hljs.registerLanguage("diff", diff)
hljs.registerLanguage("dockerfile", dockerfile)
hljs.registerLanguage("go", go)
hljs.registerLanguage("java", java)
hljs.registerLanguage("javascript", javascript)
hljs.registerLanguage("json", json)
hljs.registerLanguage("plaintext", plaintext)
hljs.registerLanguage("powershell", powershell)
hljs.registerLanguage("python", python)
hljs.registerLanguage("ruby", ruby)
hljs.registerLanguage("rust", rust)
hljs.registerLanguage("sql", sql)
hljs.registerLanguage("typescript", typescript)
hljs.registerLanguage("xml", xml)
hljs.registerLanguage("yaml", yaml)

export default hljs
