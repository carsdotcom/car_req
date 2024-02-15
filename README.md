# CarReq

[![CI](https://github.com/carsdotcom/car_req/actions/workflows/elixir.yml/badge.svg)](https://github.com/carsdotcom/car_req/actions/workflows/elixir.yml)


<!-- MDOC -->
CarReq is an opinionated framework wrapper for Req, which implements plug (-and-play) discrete steps in an
HTTP call. Req is itself an abstraction on the underlying HTTP libraries, the adapter: Finch.
Finch is itself an abstraction to Mint. It's turtles all the way down.

The goal for this package is to ensure we (cars.com Marketplace engineering) are setting
sensible defaults, configuring a circuit breakers, and emitting telemetry for all implementations.

A secondary goal is to leak as little as possible about the underlying Req and adapter interface
back to the usage of this module.

## How do I use this?

Use the `use` block.

### Basic usage (all default values)

```elixir
  defmodule ExampleImpl do
    use CarReq
  end
```

### Configured usage

```elixir
  defmodule ExampleImpl do
    use CarReq,
      base_url: "https://www.cars.com/",
      pool_timeout: 100,
      receive_timeout: 999,
      retry: :safe_transient,
      max_retries: 3,
      fuse_opts: {{:standard, 5, 10_000}, {:reset, 30_000}}
  end
```

### Runtime values (config and secrets)

There's a concern about compile-time evaluation of Application and system env vars. Secret values
are only set as runtime values via helm charts and runtime configuration. If we rely on those
values at compile-time, there's a chance that the values may not be defined
correctly at runtime. It's not 100% clear what the value would contain at runtime.

In order to help mitigate this possibility, runtime values must be wrapped in functions to
ensure they are evaluated (without ambiguity) at runtime.
This adds some complexity to the implementation but in the hope that this will behave "correctly"
at runtime. It is highly recommended to implement the `client_options/0` callback for all dynamic
settings.

For example, the `base_url` value is likely to change per environment. Setting this value in the
`use` block can "bake" the value at compile-time and then the value may not change as intended with
deployments. (Ask me how I know this ;) )

The `client_options/0` callback is provided to manage explicitly runtime concerns.

### Configured usage (with client_options)

```elixir
  defmodule ExampleImpl do
    use CarReq,
      pool_timeout: 100,
      receive_timeout: 999,
      retry: :safe_transient,
      max_retries: 3,
      fuse_opts: {{:standard, 5, 10_000}, {:reset, 30_000}}

    @impl true
    def client_options do
      [
        # Any values that may need to be runtime dynamic.
        base_url: Application.get_env(:car_req, __MODULE__, "https://www.cars.com/")
      ]
    end
  end
```

## Instrumentation

By default implementations of this module will be represented as Services in Datadog. The service name can be one of three options. By default the name is extracted from the module name. If the module name contains `External`, the service name will be snaked case atom of the module name after `External`. Example: `Engine.External.Wordpress.DefaultAdapter` would have a service name of `:wordpress_default_adapter`.

If the module name does not contain `External`, the whole module name is used. Example: `Engine.Wordpress.DefaultAdapter` would have a service name of `:engine_wordpress_default_adapter`

The option `datadog_service_name` can be used to set an explicit service name. The following example will have a service name of `:dont_put_me_in_a_box`

```elixir
defmodule ExampleImpl do
  use CarReq, datadog_service_name: :dont_put_me_in_a_box
end
```
## Options

  # adapter
  - `:pool_timeout` - How long to wait to checkout a connection from the pool.
  - `:receive_timeout` - (for Finch) The maximum time to wait for a response before returning an error.
  - `:raw` - Bypass the decompress step on the response body step when `true`.
  - `:decode_body` --  Bypass the decode step on the response body step when `false`.

  # fuse
  - keywords for fuse configuration. See `ReqFuse`

  # Instrumentation (datadog)
  - `:datadog_service_name` - An atom used to name Telemetry traces. This will be the resource name used in DataDog.
  - `:log_function` - a 1-arity function to emit a Logger message or `:none` to skip the logging step.

  # retry logic
  - `:retry` - one of: `:safe_transient`, `false`, or a 1-arity function.
  - `:retry_delay` - a 1-arity function to determine the delay. (Receives retry count as the argument)
    Ex `fn count -> count * 100 end`
  - `:max_retries` - a non-negative integer. Ignored when `retry: false`

See [Req `retry/1`](https://hexdocs.pm/req/Req.Steps.html#retry/1) for more information on
  retry options.

See [Req `run_finch/1`](https://hexdocs.pm/req/Req.Steps.html#run_finch/1) for more information
  timeout options

How do I see the telemetry for the implementations?
  The module you implement will be the :service in DataDog, for example, `ExampleImpl`.

## Request Options

Override any Req option by passing the option into the underlying Req.request function call.

### Example
```elixir
  defmodule ExampleImpl do
    use CarReq
      base_url: "https://www.cars.com/"
  end
  fake_adapter = fn request ->
    {request, Req.Response.new()}
  end
  {:ok, %Req.Response{}} = ExampleImpl.request(
    method: :get,
    params: [page: 1, page_size: 10],
    receive_timeout: 500,
    adapter: fake_adapter)
  {:ok, %Req.Response{}} = ExampleImpl.request(
    method: :get,
    params: [page: 1, page_size: 10],
    receive_timeout: 500,
    adapter: &CarReq.Adapter.success/1)
```

## Usage in Testing

Testing HTTP clients can be very tricky, partly because they are software designed to interact with the outside world.

`Req` and thus `CarReq` have the ability to define a lower level adapter to be used for the actual HTTP request processing. To make testing easier, `CarReq` supports setting the adapter by passing a module implementing the `CarReq.Adapter` behaviour via Application config:

```elixir
config :car_req, MyApi, adapter_module: Another.Adapter
```

If no adapter is configured, we use `Req.Steps.run_finch(request)` whichs in turn uses [finch](https://github.com/sneako/finch).

In the following example HTTP client:

```elixir
defmodule ExternalService.Client do
  use CarReq, base_url: "https://www.service.com/"

  def get_data(vehicle_id) do
    [
      url: "api/vehicle_data/",
      headers: %{"content-type" => "application/json"},
      method: :get,
      params: %{vehicle_id: vehicle_id}
    ]
    |> request()
  end
end
```

We can utilize [`Mox`](https://hexdocs.pm/mox/Mox.html) to define a custom adapter module for use only in tests.

First, we need to generate the mock adapter  in `test_helper.exs`:

```elixir
Mox.defmock(ExternalService.MockAdapter, for: CarReq.Adapter)
```

Then configure your `Req`-based client to use this adapter in your config:

```elixir
# config/test.exs
config :car_req, ExternalService.Client,
  adapter_module: ExternalService.MockAdapter
```

Then in your tests, set expectations on the adapter:

```elixir
defmodule ExternalService.ClientTest do
  use ExUnit.Case, async: true
  import Mox

  alias ExternalService.Client

  # Checks your mock expectations on each test
  setup :verify_on_exit!

  test "can get data" do
    expect(ExternalService.MockAdapter, :run, fn %Req.Request{} = request ->
      {request,
       Req.Response.json(%{"make" => "kia", "model" => "soul"})}
    end)

    assert {:ok, %{status: 200, body: body}} = Client.get_data()
    assert body["make"] == "kia"
  end
end
```

You can also pass the adapter into the `request/1` function call. (See the moduledoc Example above.)

When passing `:adapter` to the request function, it takes the form af a 1-arity function which
recevies the `%Req.Request{}` struct and returns a tuple of the form `{request, %Req.Response{}}`.

You may pass `Mod.fun/1` or an anonymous function as the value to the `:adapter` key.
See the moduledoc example above for the anonymous function flavor.
<!-- MDOC -->

## Installation

Used internally, so only available thorugh github at this time.

~If [available in Hex](https://hex.pm/docs/publish),~
The package can be installed by adding `car_req` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:car_req, git: "git@github.com:carsdotcom/car_req.git", tag: "0.1.2"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/car_req>.

