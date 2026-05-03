package presets

import _ "embed"

//go:embed pipeline-presets.json
var builtinJSON []byte
