# Contributing to TripleStore

## Getting Started

1. Fork the repository
2. Clone your fork
3. Create a feature branch from `master`

## Development Setup

```bash
# Install dependencies
mix deps.get

# Compile the project
mix compile

# Run tests
mix test
```

## Code Style

- Follow standard Elixir formatting (`mix format`)
- Use `mix credo` for static analysis
- Rust code should pass `cargo clippy` and `cargo fmt`

## Testing

- Write tests for new functionality
- Ensure all tests pass before submitting a PR
- Run the full test suite: `mix test`
- Run a specific test: `mix test path/to/test.exs:LINE`

## Pull Request Process

1. Update documentation if adding new features
2. Add tests for new functionality
3. Ensure CI passes
4. Request review from maintainers

## Reporting Issues

When reporting bugs, include:
- Elixir/OTP version
- Steps to reproduce
- Expected vs actual behavior
- Relevant error messages or logs

## Project Structure

```
lib/
  triple_store/
    backend/        # RocksDB NIF interface
    dictionary/     # Term encoding/decoding
    index/          # Triple indices (SPO, POS, OSP)
    sparql/         # Parser, algebra, executor
    reasoner/       # OWL 2 RL rule engine
native/
  rocksdb_nif/      # Rust NIF code
  sparql_parser/    # SPARQL parser NIF
test/
```

## Architecture Guidelines

- NIFs for I/O-bound and parsing operations only
- Keep query execution in pure Elixir (preemptible)
- Use dirty CPU schedulers for NIF operations >1ms
- Prefer Stream-based lazy evaluation for query results
