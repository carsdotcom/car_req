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

### Resource Name Overrides

In most cases, your application's instrumentation modules (the ones that call `:telemetry.attach/4` on Telemetry events executed by CarReq) will take the metadata provided by CarReq's Telemetry events and form a resource name that may look something like:

```
get some_partner.api.com/product/4123/details
```

In some cases, you may want specific requests or clients to override the default resource name provided by your application's instrumentation module. To do so, you can pass along a `:resource_name_override` option at the client level or on a per-request
basis. The value of `:resource_name_override` must be a 1-arity function that takes a string (the default resource_name provided by your
instrumentation) and returns a new string (the overridden resource_name). Note that when passing this option at the client-level, you
must pass the option as an external function capture, i.e., `&Module.function/1`. An example would be:

```elixir
defmodule MyResourceOverrideClient do
  use CarReq, resource_name_override: &MyResourceOverrideClient.override_function/1

  @doc """
  Replaces any consecutive instances of numbers in a string with the
  placeholder `{guid}`. For example

  MyResourceOverrideClient.override_function("get partner.api.com/product/1234/details")
  # => "get partner.api.com/product/{guid}/details"
  """
  def override_function(resource_name) do
    String.replace(resource_name, ~r|\d+|, "{guid}")
  end
end
```

You can also provide an override function on a per-request basis as follows:

```elixir
MyResourceOverrideClient.request(
  method: :get,
  url: url,
  resource_name_override: fn resource_name -> 
   String.replace(resource_name, ~r|\d+|, "{guid}")
  end
```

And finally, on a per-request basis, you can provide a hard-coded string as well rather than a 1-arity function:

```elixir
MyResourceOverrideClient.request(
  method: :get,
  url: url,
  resource_name_override: "get product_details_endpoint"
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

There are two options for using CarReq in testing. If you don't care about the HTTP responses,
then there is a stubbed adapter that can be passed in the `:adapter` key.
See `CarReq.Adapter.success/1`.

You can also pass the adapter into the request/1 function call. (See the moduledoc Example above.)

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

