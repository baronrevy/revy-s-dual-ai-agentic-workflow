# Config migrations

One jq program per version step, named `<from>-to-<to>.jq` (for example `1-to-2.jq`).
Each takes a config at version `<from>` and outputs it at version `<to>`, setting
`.schema_version` and filling defaults for any new keys.

The loader applies the chain in memory and validates the result against the current
schema. It never rewrites `config.json` on disk. A missing step makes the loader
refuse the config (exit 13).

There are no migrations yet: schema version 1 is the first.
