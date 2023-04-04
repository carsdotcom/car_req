defmodule CarReq do
  @moduledoc """
  Yet another adapter to HTTP requests.

  This module is an abstraction to Req, which implements plug (-and-play) discrete steps in an
  HTTP call. Req is itself an abstraction on the underlying HTTP libraries, the adapter: Finch.
  Finch is itself an abstraction to Mint. It's turtles all the way down.

  The goal for this glue code is to ensure we are setting sensible defaults for all timeouts and
  forcing connection pool usage.

  A secondary goal is to leak as little as possible about the underlying Req and adapter interface
  back to the usage of this module.

  ## How do I use this?

  Use the `use` block.

  ### Basic usage (all default values)

  ```elixir
    defmodule ExampleImpl do
      use CarReq

        def base_url, do: "https://www.cars.com/"
    end
  ```

  ### Configured usage

  ```elixir
    defmodule ExampleImpl do
      use CarReq,
        pool_timeout: 100,
        receive_timeout: 999,
        retry: :safe,
        max_retries: 3,
        fuse_opts: {{:standard, 5, 10_000}, {:reset, 30_000}}

        def base_url, do: "https://www.cars.com/"
    end
  ```

  ### Runtime values (config and secrets)

  There's a concern about compile-time evaluation of Application and system env vars. Secret values
  are only set as runtime values via helm charts and runtime configuration. If we rely on those
  values at compile-time, there's a chance that the values may not be defined
  correctly at runtime. It's not 100% clear what the value would contain at runtime.

  In order to help mitigate this possibility, runtime values must be wrapped in functions to
  ensure they are evaluated (without ambiguity) at runtime.
  The callback allows deferring the evaluation of the value to an explicitly runtime concern.
  This adds some complexity to the implementation but in the hope that this will behave "correctly"
  at runtime.

  ## Instrumentation

  By default implementations of this module will be represented as Services in Datadog. The service name can be one of three options. By default the name is extracted from the module name. If the module name contains `External`, the service name will be snaked case atom of the module name after `External`. Example: `Engine.External.Wordpress.DefaultAdapter` would have a service name of `:wordpress_default_adapter`.

  If the module name does not contain `External`, the whole module name is used. Example: `Engine.Wordpress.DefaultAdapter` would have a service name of `:engine_wordpress_default_adapter`

  The option `datadog_service_name` can be used to set an explicit service name. The following example will have a service name of `:dont_put_me_in_a_box`

  ```elixir
  defmodule ExampleImpl do
    use CarReq,
      datadog_service_name: :dont_put_me_in_a_box
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
    - `:retry` - one of: `:safe`, `false`, or a 1-arity function.
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
      def base_url, do: "http://www.cars.com"
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
  """

  alias CarReq.LogStep

  @schema [
    base_url: [
      type: {:or, [:string, {:struct, URI}]}
    ],
    datadog_service_name: [
      type: :atom
    ],
    finch: [
      type: :atom
    ],
    pool_timeout: [
      default: 500,
      type: :timeout
    ],
    receive_timeout: [
      default: 1000,
      type: :timeout
    ],
    decode_body: [
      default: true,
      type: :boolean
    ],
    raw: [
      default: false,
      type: :boolean
    ],
    retry: [
      default: false,
      type: {:in, [:safe, false, {:fun, 1}]}
    ],
    retry_delay: [
      type: {:or, [:timeout, {:fun, 1}]}
    ],
    max_retries: [
      type: :non_neg_integer
    ],
    log_function: [
      type: {:or, [:atom, {:fun, 1}]}
    ],
    fuse_name: [
      type: :atom
    ],
    fuse_opts: [
      # type: :tuple NimbleOptions doesn't support tuple in this version
      type: :any
    ],
    fuse_verbose: [
      type: :boolean
    ],
    fuse_mode: [
      type: {:in, [:sync, :async_dirty]}
    ],
    fuse_melt_func: [
      type: {:fun, 1}
    ]
  ]

  @compiled_schema NimbleOptions.new!(@schema)

  def validate_options!(opts) do
    NimbleOptions.validate!(opts, @compiled_schema)
  end

  def build_service_name(module_name, opts) do
    Keyword.get_lazy(opts, :datadog_service_name, fn ->
      module_name
      |> Macro.underscore()
      |> String.replace("\/", "_")
      |> String.split("external_", parts: 2)
      |> case do
        [a] -> a
        [_, a] -> a
      end
      |> String.to_atom()
    end)
  end

  @doc """
  Configure circuit-breaker :fuse step.

  Explicit opt-out via `fuse_opts: :disabled`

  ### Note:

  The fuse is evaluated per-node. There is no global fuse state. So two running nodes may have
  different states depending on their respective traffic loads and the failing requests.

  ### Options

    See `ReqFuse.Steps.Fuse` at https://github.com/carsdotcom/req_fuse/blob/main/lib/steps/fuse.ex
    for more about each of the options.

    See https://github.com/jlouis/fuse#tutorial for more information, supported strategies, and options

    ### Required
      - `:fuse_name` - Defaults to the `use CarReq` module

    ### Optional
      - `:fuse_opts` The fuse trigger and reset options, disable fuse with `fuse_opts: :disabled`
      - `:fuse_melt_func` The melt message to the fuse server
      - `:fuse_verbose` - suppress log output
      - `:fuse_mode` - :sync or :async_dirty

  ### Examples
  ```elixir
  defmodule NoneImpl do
    use CarReq, fuse_opts: :disabled
  end

  defmodule ExampleImpl do
    use CarReq,
      fuse_opts: {{:standard, 1, 1000}, {:reset, 300}},
      fuse_melt_func: my_melt_function,
      fuse_name: My.Fuse.Name
  end
  ```
  """

  @spec attach_circuit_breaker(Req.Request.t(), keyword(), keyword()) :: Req.Request.t()
  def attach_circuit_breaker(request, opts, request_options) do
    if Keyword.get(opts, :fuse_opts) == :disabled ||
         Keyword.get(request_options, :fuse_opts) == :disabled do
      Req.Request.register_options(request, [
        :fuse_name,
        :fuse_opts,
        :fuse_verbose,
        :fuse_mode,
        :fuse_melt_func
      ])
    else
      opts = Keyword.put_new(opts, :fuse_name, Keyword.get(opts, :implementing_module))
      ReqFuse.attach(request, opts)
    end
  end

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @options CarReq.validate_options!(opts)
      @datadog_service_name CarReq.build_service_name(__MODULE__, opts)

      @doc """
      Make a verb agnostic HTTP request. Allow the supplied request_options to override the
      `use` configured options. Useful for testing with a specific return value or to test
      reduced timeouts, sensitve or disabled circuit breakers, retries, and other (supported)
      options that may be useful in debugging.

      ## Common Request Options

         - `:method` - the request method, one of [`:head`, `:get`, `:delete`, `:trace`, `:options`, `:post`, `:put`, `:patch`]
         - `:url` - either full url e.g. "http://example.com/some/path" or just "/some/path" if :base_url is set.
         - `:params` - a keyword list of query params, e.g. `[page: 1, per_page: 100]`
         - `:headers` - a keyworld list of headers, e.g. `[{"content-type", "text/plain"}]`
         - `:body` - the request body
         - `:json` - the request body, JSON encoded

      ## Additional Request Options

        A full list of options [can be found here.](https://hexdocs.pm/req/Req.html#request/1-options)
      """

      def request(request_options) do
        metadata = %{
          datadog_service_name:
            Keyword.get(request_options, :datadog_service_name, @datadog_service_name),
          url: Keyword.get(request_options, :url),
          method: Keyword.get(request_options, :method),
          query_params: Keyword.get(request_options, :params)
        }

        client = client(request_options)

        # :telemetry.span is used so that the status code of the request, or the exception reason, can be added to the stop event's metadata.
        :telemetry.span([:http_car_req, :request], metadata, fn ->
          try do
            case Req.request(client) do
              {:ok, response_struct} = response ->
                {response, Map.merge(metadata, %{status_code: response_struct.status})}

              {:error, exception} = response ->
                {response, Map.merge(metadata, %{reason: exception})}
            end
          rescue
            Jason.DecodeError ->
              {{:error, :json_decode_error}, %{reason: :json_decode_error}}

            error ->
              # Finch raises a RuntimeError for pool timeouts.
              if Map.get(error, :message, "") =~ "Finch was unable to provide a connection" do
                {{:error, :pool_timeout}, %{reason: :pool_timeout}}
              else
                {{:error, inspect(error)}, %{reason: inspect(error)}}
              end
          end
        end)
      end

      @doc """
      Configure the Req struct, attach the circuit breaker and set request settings (`@options`)

      The :fuse (circuit breaker) is configured by default and opted-out by setting `fuse_opts: :disabled`

      The :log_funtion (Logger) is configured by default and opted-out by setting `log_function: :none`
      """
      def client(request_options) do
        compiled_opts = Keyword.merge(@options, implementing_module: __MODULE__)

        Req.new()
        |> Req.Request.register_options([
          :datadog_service_name,
          :implementing_module
        ])
        |> LogStep.attach()
        |> CarReq.attach_circuit_breaker(compiled_opts, request_options)
        # Order matters. The `compiled_opts` set the baseline settings.
        # The `request_options` are specific to one request so they override the baseline.
        |> Req.update(compiled_opts)
        |> Req.update(request_options)
      end
    end
  end
end
