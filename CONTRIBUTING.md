# Contributing

1. Fork it (<https://github.com/tristanholl/crystal-es/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Run `make test` and `make lint` — CI runs both and will reject a red branch
5. Push to the branch (`git push origin my-new-feature`)
6. Create a new Pull Request

## Development

Start the development environment with Docker:

```bash
docker-compose up -d   # starts PostgreSQL
make test              # run the spec suite
```

### Coding standards

Two tools guard the code style, and both run in CI on every push and pull
request:

- `crystal tool format`, the formatter that ships with the compiler.
- [Ameba](https://github.com/crystal-ameba/ameba), a static analyser for
  Crystal that catches code smells, dead assignments and constructs that work
  but read badly.

```bash
make lint          # formatter check + Ameba, the same pair CI runs
make lint-format   # formatter check only
make lint-ameba    # Ameba only
make lint-fix      # rewrite files: format, then auto-correct what Ameba can
```

Ameba is a development dependency, so `shards install` pulls it in. The binary
is compiled into `bin/ameba` by `shards build ameba` and is baked into the dev
image, which is why `make lint` starts instantly rather than compiling the
linter first.

Ameba 1.7 itself needs Crystal >= 1.19, which is newer than the `>= 1.14.0`
floor in `shard.yml`. That floor is what applications *using* this shard need —
`shards install` does not pull a dependency's development dependencies, so it is
unaffected. It only matters if you lint outside Docker on an older compiler; the
dev image pins 1.20.2, so every `make` target is fine.

Rules are configured in [`.ameba.yml`](./.ameba.yml), which runs Ameba's defaults
with two relaxations, each explained next to it in the file:

- `Style/MultilineStringLiteral` is off, because it would rewrite every adapter
  migration's `%( ... )` SQL literal as a heredoc.
- `Naming/AccessorMethodName` and `Naming/QueryBoolMethods` stay on but are
  exempted for the three files holding accessors that are already part of the
  shard's public API. New code is still checked by both.

Note that Ameba ignores rule names it does not recognise, so a typo in that file
silently disables nothing — re-run `make lint-ameba` after editing it.

A single line can be exempted in place instead of globally:

```crystal
# ameba:disable Naming/BlockParameterName
items.each { |x| puts x }
```
