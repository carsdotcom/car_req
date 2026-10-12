# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0](https://github.com/carsdotcom/car_req/compare/0.4.1...0.5.0) - 2026-10-12

### Changed

- **Breaking:** Unexpected raised request exceptions now return
  `{:error, {:unexpected_exception, "<exception module name>"}}` instead of an
  inspected exception string. The request stop event uses the same sanitized
  reason and preserves start metadata. Callers matching binary error reasons
  must update their matches. Exceptions whose `message` is `nil`, such as
  `KeyError`, previously crashed the caller and now return this reason too.
- **Breaking:** `[:http_car_req, :request, :exception]` and `[:req, :step, :exception]`
  events now carry sanitized metadata, so exception fields, exit reasons, and
  stacktrace arguments no longer reach telemetry. Raised exceptions report
  `{:unexpected_exception, "<exception module name>"}`. Throw and exit reasons keep
  only an atom reason, or the leading atom of a tuple reason (for example
  `:timeout`), and report `:redacted` otherwise. Stacktrace frames keep module,
  function, arity, file, and line. Exceptions, throws, and exits still propagate
  unchanged, as do span timing and correlation, pool-timeout and JSON-decode
  request reasons, and exceptions returned by Req.
- Telemetry handlers that interpolate `reason` into a string (`"#{metadata.reason}"`)
  now raise `Protocol.UndefinedError`, and `:telemetry` permanently detaches a
  handler that raises. Check handlers before upgrading; use `inspect/1` instead.
- Support Req 0.7's `finch: [name: FinchName]` option shape. Legacy atom Finch names
  remain accepted by CarReq but are normalized before reaching Req, avoiding Req's
  Finch and `pool_timeout` deprecation warnings.
- Use Req 0.7's native `request_timeout` support instead of the deprecated `:finch_request`
  hook.

## [0.4.1](https://github.com/carsdotcom/car_req/compare/0.4.0...0.4.1) - 2026-09-14

### Fixed

- Rescue paths in `:telemetry.span/3` now `Map.merge/2` the start metadata into the
  stop payload (JSON decode, Finch pool timeout, and the catch-all). `:telemetry.span/3`
  uses that second tuple element as stop metadata and does not merge start into `:stop`,
  so those three returns previously emitted `%{reason: ...}` only. Downstream tracing and
  OTel metrics lost `method` and `datadog_service_name` on those failures; success and
  `{:error, exception}` already kept them.

## [0.4.0](https://github.com/carsdotcom/car_req/compare/0.3.4...0.4.0) - 2026-09-01

### Added

- `:request_timeout` option — Finch's total-response deadline (HTTP/1, best-effort) for bounding
  the whole request when an upstream stalls past the per-chunk `:receive_timeout`. Unset by default
  (no behavior change). Because Req's Finch adapter does not forward `:request_timeout`, it is
  applied via Req's `:finch_request` hook, with errors normalized to Req exceptions (e.g.
  `%Req.TransportError{reason: :timeout}`) exactly as the default adapter path. Motivated by
  CARS-35993 (Market Demand API ~5s stalls not bounded by the 500ms `:receive_timeout`).
  Combining `:request_timeout` with `:into` (streaming) raises `ArgumentError`, since the
  `:finch_request` hook would otherwise silently bypass Req's streaming dispatch.
- Declared `finch` as an explicit dependency, since CarReq now calls `Finch.request/3` directly.

### Documentation

- Clarified that `:receive_timeout` is a per-chunk timeout, not a total-request deadline.

## [0.3.4](https://github.com/carsdotcom/car_req/compare/0.3.3...0.3.4) - 2026-06-11

### Changed

- Upgraded `req` from 0.5.10 to 0.6.1
- Upgraded `finch` from 0.19.0 to 0.22.0 (required by req 0.6.1)
- Upgraded `mint` from 1.7.1 to 1.9.0 (required by finch 0.22)
- Raised minimum Elixir version from `~> 1.13` to `~> 1.15` (required by finch 0.22)
- Expanded CI matrix to cover Elixir 1.15–1.20 paired with OTP 25–29; dropped Elixir 1.14

### Documentation

- Created CHANGELOG.md (previously referenced in mix.exs but missing)
- Updated installation tag from `0.1.2` to `0.3.3` in README.md
- Expanded Options section to document all `@schema` options including:
  - `base_url`, `finch` (General)
  - `cache`, `cache_dir`, `compressed`, `compress_body` (Response Handling)
  - `fuse_name`, `fuse_opts`, `fuse_verbose`, `fuse_mode`, `fuse_melt_func` (Circuit Breaker)
  - `resource_name_override` (Instrumentation)
  - Added `:transient` as valid retry option
- Fixed incomplete code examples (missing closing parentheses)
- Fixed typos: "recevies" → "receives", "thorugh" → "through", "af" → "of"

## [0.3.3](https://github.com/carsdotcom/car_req/compare/0.3.2...0.3.3) - 2024

### Changed

- Upgraded `req` from 0.5.8 to 0.5.10

## [0.3.2](https://github.com/carsdotcom/car_req/compare/0.3.1...0.3.2) - 2024

### Added

- Support for `resource_name_override` option at client module level
- Support for `resource_name_override` on per-request basis
- Allow passing a hard-coded string as `resource_name_override` (not just functions)

### Changed

- Upgraded `req` to 0.5.8
- Upgraded `req_fuse` to 0.3.1

## [0.3.1](https://github.com/carsdotcom/car_req/compare/0.3.0...0.3.1) - 2024

### Changed

- Upgraded `req` and all dependencies
- Removed unused dependencies

## [0.3.0](https://github.com/carsdotcom/car_req/compare/0.2.2...0.3.0) - 2024

### Added

- Telemetry wrapping for request/response steps
- Support for additional Req options (cache, cache_dir, compressed, compress_body)

### Changed

- Upgraded `req` to 0.4.14 (introduces improved testing mechanism)
- Upgraded `req_fuse` to 0.3.0
- Replaced deprecated `Req.update/2` with `Req.merge/2`
- Updated retry config values
- Updated GitHub Actions build versions

## [0.2.2](https://github.com/carsdotcom/car_req/compare/0.2.1...0.2.2) - 2023

### Changed

- Updated `req` dependency

## [0.2.1](https://github.com/carsdotcom/car_req/compare/0.2.0...0.2.1) - 2023

### Changed

- Relaxed `nimble_options` version constraint to `~> 0.4 or ~> 1.0`

### Documentation

- Added additional example in README

## [0.2.0](https://github.com/carsdotcom/car_req/compare/0.1.1...0.2.0) - 2023

### Added

- `client_options/0` callback for runtime configuration
- Support for dynamic runtime values (base_url, secrets, etc.)

### Changed

- Refactored implementation for cleaner code
- Updated `req_fuse` dependency

## [0.1.1](https://github.com/carsdotcom/car_req/compare/0.1.0...0.1.1) - 2023

### Changed

- Made `client/1` a callback

## 0.1.0 - 2023

### Added

- Initial release
- Opinionated wrapper for Req HTTP client
- Circuit breaker support via `req_fuse`
- Telemetry integration for Datadog
- Configurable timeouts (pool_timeout, receive_timeout)
- Retry logic with configurable strategies
- Logging step with customizable log function
- NimbleOptions schema validation
