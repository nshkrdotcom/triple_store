# Test Performance Optimization

This directory contains technical documentation for optimizing TripleStore test suite performance.

## Problem Summary

Individual tests are taking ~30ms each due to RocksDB database initialization overhead in test setup blocks. This creates a slow feedback loop during development and CI.

## Documents

| Document | Description |
|----------|-------------|
| [analysis.md](analysis.md) | Root cause analysis and benchmarks |
| [solution-portable-tmpdir.md](solution-portable-tmpdir.md) | Portable RAM-disk detection (~2x speedup) |
| [solution-setup-all.md](solution-setup-all.md) | Shared DB with key isolation (~10-20x speedup) |
| [solution-db-pool.md](solution-db-pool.md) | Database pool architecture (~20x+ speedup) |
| [migration-guide.md](migration-guide.md) | Step-by-step implementation guide |

## Quick Decision Matrix

| Approach | Speedup | Effort | Portability | Test Isolation |
|----------|---------|--------|-------------|----------------|
| Portable tmpdir | ~2x | 30 min | Full | Full (separate DBs) |
| setup_all + key prefixes | ~10-20x | 2-3 hrs | Full | Logical (shared DB) |
| Database pool | ~20x+ | 4-6 hrs | Full | Logical (pooled DBs) |

## Recommended Path

1. **Immediate**: Implement portable tmpdir (quick win)
2. **Short-term**: Refactor to setup_all for high-frequency test modules
3. **Long-term**: Consider DB pool if test count grows significantly

## Date

2024-12-22
