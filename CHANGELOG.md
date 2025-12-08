# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
