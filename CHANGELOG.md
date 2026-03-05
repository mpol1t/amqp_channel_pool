# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-03-05

### Added
- HexDocs structure with curated guides for setup, configuration, checkout/failure semantics, recovery lifecycle, telemetry, and integration testing.

### Changed
- ExDoc configuration now includes stable source references, canonical HexDocs URL, grouped module/guide navigation, and curated project extras.
- README now links to focused guides for API usage and operational semantics.

## [0.2.0] - 2026-03-05

### Added
- Explicit worker lifecycle model (`:starting | :ready | :stale | :recovering | :closing`) with deterministic startup and cleanup behavior.
- Stale detection using monitor `DOWN` handling plus checkout-time validation.
- One-shot worker recovery with typed pool-layer recovery errors.
- Borrower-failure safety semantics (`raise`/`exit`/`throw` propagate; tainted workers are discarded).
- Telemetry surface for checkout, worker init/recovery, and discard/terminate events.
- RabbitMQ-backed integration test harness and CI integration job.
- Migration guide for the breaking redesign.

### Fixed
- Checkout error plumbing no longer rewrites callback failures into generic pool runtime errors.
- Checkout telemetry worker-pid metadata normalization is consistent across stop/exception paths.
- CI integration job now runs integration-tagged tests only.

### Changed
- Public API moved from singleton-style usage to explicit named-pool usage.
- Startup config now requires `:name` and `:connection`; legacy `:opts` is rejected.
- `child_spec/1` default ID strategy is stable per pool name and supports explicit `:id`.
- Documentation now defines explicit boundaries between pool responsibilities and publisher responsibilities.

### Removed
- Singleton pool assumptions and related documentation examples.
- Implicit module-targeted stop/checkout usage.

### Breaking
- `start_link/1` now requires `:name` and `:connection`; `:opts` is no longer accepted.
- `checkout/3` and `checkout!/3` now require explicit pool name: `checkout(pool_name, fun, opts)`.
- `stop/1` now requires explicit pool name: `stop(pool_name)`.
- Existing callers must migrate to named pools and explicit checkout/stop targets. See `docs/migration_0_1_to_0_2.md`.

## [0.1.0] - 2025-01-02

### Added
- Initial release of `amqp_channel_pool`.
- Support for managing a pool of AMQP channels using NimblePool.
- Simple and flexible API for starting the pool and checking out channels.
- Configuration support for AMQP connection options (e.g., `host`, `port`, `username`, `password`).
- Documentation, including a README with usage examples and configuration guidance.
