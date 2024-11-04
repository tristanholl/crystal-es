# crystal-es

An event sourcing library for Crystal

[![crystal-es (CI)](https://github.com/tristanholl/crystal-es/actions/workflows/ci.yml/badge.svg)](https://github.com/tristanholl/crystal-es/actions/workflows/ci.yml)

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     crystal-es:
       github: tristanholl/crystal-es
   ```

2. Run `shards install`

## Usage

```crystal
require "crystal-es"
```

The library aims to provide a foundation for event sourced applications. It is optimized and tested for the usage of PostgreSQL as event store, queue, as well as projection database. It was extraced out of a bigger project that focused on bringing an open-source core-banking system to life. This is the simplified version of the library used and will be back-ported into it.

The repository provides a simple example in `./examples/financial-transaction` on how to structure a business domain with a financial transaction flow. 

In order to keep bigger projects manageable, I suggest the following (opinionated) structure of domain verticals, which worked quite well:

```
src/
- domains/
  - domain 1/
    - aggregates/
      - aggregate.cr
    - commands/
      - command_1.cr
      - command_2.cr
    - events/
      - event_1.cr
      - event_2.cr
    - migrations/
      - YYYYMMDDHHmmSS_migration_1.sql
    - projections/
      - projection_1.cr
  - domain 2/
    - ...
- shared/
  - ...
```

## Development

TODO:

## Contributing

1. Fork it (<https://github.com/your-github-user/crystal-es/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Tristan Holl](https://github.com/tristanholl) - creator and maintainer
