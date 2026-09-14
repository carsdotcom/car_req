defmodule CarReq do
  @external_resource "README.md"
  @moduledoc @external_resource
             |> File.read!()
             |> String.split("<!-- MDOC -->")
             |> Enum.fetch!(1)

  alias CarReq.LogStep

  @schema [
    base_url: [
      type: :string
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
    request_timeout: [
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
    cache: [
      type: :boolean
    ],
    cache_dir: [
      type: :string
    ],
    compressed: [
      type: :boolean
    ],
    compress_body: [
      type: :boolean
    ],
    retry: [
      default: false,
      type: {:in, [:safe_transient, :transient, false, {:fun, 1}]}
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
      type: {:custom, __MODULE__, :validate_fuse_opts, []}
    ],
    fuse_verbose: [
      type: :boolean
    ],
    fuse_mode: [
      type: {:in, [:sync, :async_dirty]}
    ],
    fuse_melt_func: [
      type: {:fun, 1}
    ],
    resource_name_override: [
      type: {:fun, 1}
    ]
  ]

  @compiled_schema NimbleOptions.new!(@schema)

  def validate_url(value) do
    cond do
      match?(%URI{}, value) -> {:ok, value}
      is_bitstring(value) -> {:ok, value}
      true -> {:error, ":base_url must be a String or %URI{}"}
    end
  end

  def validate_fuse_opts(value) do
    cond do
      match?({{_, _, _}, {_, _}}, value) -> {:ok, value}
      match?({{_, _, _, _}, {_, _}}, value) -> {:ok, value}
      value == :disabled -> {:ok, value}
      true -> {:error, ":fuse_opts must be a two-element tuple or the atom :disabled"}
    end
  end

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
  def attach_circuit_breaker(request, opts, request_options \\ []) do
    if Keyword.get(opts, :fuse_opts) == :disabled ||
         Keyword.get(request_options, :fuse_opts) == :disabled do
      Req.Request.register_options(request, [
        :fuse_melt_func,
        :fuse_mode,
        :fuse_name,
        :fuse_opts,
        :fuse_verbose
      ])
    else
      opts = Keyword.put_new(opts, :fuse_name, Keyword.get(opts, :implementing_module))
      ReqFuse.attach(request, opts)
    end
  end

  @doc """
  Configure the Req struct, attach the circuit breaker and set request settings (`@options`)

  The :fuse (circuit breaker) is configured by default and opted-out by setting `fuse_opts: :disabled`

  The :log_funtion (Logger) is configured by default and opted-out by setting `log_function: :none`

  Wrap the request and response steps in telemetry spans.
  """
  def client(options) do
    {request_timeout, options} = Keyword.pop(options, :request_timeout)
    options = put_request_timeout(options, request_timeout)

    Req.new()
    |> Req.Request.register_options([
      :datadog_service_name,
      :implementing_module,
      :resource_name_override
    ])
    |> LogStep.attach()
    |> CarReq.attach_circuit_breaker(options)
    |> Req.merge(options)
    |> then(fn req -> update_in(req.request_steps, &CarReq.Telemetry.request_spanner/1) end)
    |> then(fn req -> update_in(req.response_steps, &CarReq.Telemetry.response_spanner/1) end)
  end

  # Req's Finch adapter forwards only `:receive_timeout` and `:pool_timeout`; it has no
  # `:request_timeout` option, and `:request_timeout` is not a registered Req option (so it must be
  # popped before `Req.merge/2` or Req raises). `:receive_timeout` bounds the wait for each response
  # chunk, not the whole request, so an upstream that trickles or stalls can hold a call open far
  # longer than expected. When `:request_timeout` is set we inject Finch's total-response deadline
  # through Req's supported `:finch_request` hook, running the Finch request ourselves and
  # normalizing the result exactly as `Req.Finch` does so callers and telemetry see the same
  # exceptions (notably `Req.TransportError{reason: :timeout}`).
  #
  # The hook replaces Req's default Finch call, which is also where Req dispatches `:into`
  # (streaming) responses — so `:request_timeout` cannot be combined with `:into`, and we fail
  # fast rather than silently buffering a streamed response in full. `:into` is refused both when
  # it is present as the client is built and when it is applied later via `Req.request/2` or
  # `Req.merge/2` (the hook inspects the final `request.into`).
  @spec put_request_timeout(keyword(), timeout() | nil) :: keyword()
  defp put_request_timeout(options, nil), do: options

  defp put_request_timeout(options, request_timeout) do
    if Keyword.has_key?(options, :into), do: raise_into_conflict!()

    hook = fn request, finch_request, finch_name, finch_options ->
      if request.into, do: raise_into_conflict!()

      finch_options = Keyword.put(finch_options, :request_timeout, request_timeout)

      case Finch.request(finch_request, finch_name, finch_options) do
        {:ok, response} -> {request, Req.Response.new(response)}
        {:error, exception} -> {request, normalize_finch_error(exception)}
      end
    end

    Keyword.put(options, :finch_request, hook)
  end

  @spec raise_into_conflict!() :: no_return()
  defp raise_into_conflict! do
    raise ArgumentError,
          ":request_timeout cannot be combined with :into. Setting :request_timeout installs a " <>
            ":finch_request hook that bypasses Req's streaming dispatch, so an :into (streaming) " <>
            "request would be silently buffered in full instead. Drop :request_timeout for " <>
            "streaming requests, or bound them another way (e.g. :receive_timeout)."
  end

  # Guards on the module (rather than struct patterns) so this compiles without Mint/Finch being
  # compile-time dependencies of car_req: the error structs only need to exist at runtime, which
  # they do (finch produces them). Mirrors `Req.Finch`'s own error normalization.
  @spec normalize_finch_error(Exception.t()) :: Exception.t()
  defp normalize_finch_error(error) when is_struct(error, Mint.TransportError),
    do: %Req.TransportError{reason: error.reason}

  defp normalize_finch_error(error) when is_struct(error, Mint.HTTPError),
    do: %Req.HTTPError{protocol: finch_http_protocol(error.module), reason: error.reason}

  defp normalize_finch_error(error) when is_struct(error, Finch.Error),
    do: %Req.HTTPError{protocol: :http2, reason: error.reason}

  defp normalize_finch_error(error) when is_struct(error, Finch.TransportError),
    do: %Req.TransportError{reason: error.reason}

  defp normalize_finch_error(error) when is_struct(error, Finch.HTTPError),
    do: %Req.HTTPError{protocol: finch_http_protocol(error.module), reason: error.reason}

  defp normalize_finch_error(error), do: error

  @spec finch_http_protocol(module()) :: :http1 | :http2
  defp finch_http_protocol(Mint.HTTP2), do: :http2
  defp finch_http_protocol(_module), do: :http1

  @callback client_options() :: keyword()

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @options CarReq.validate_options!(opts)
      @datadog_service_name CarReq.build_service_name(__MODULE__, opts)
      @behaviour CarReq

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
        metadata = telemetry_metadata(request_options)

        # :telemetry.span/3 uses the second tuple element as stop metadata and does not
        # merge start into :stop. Every return must Map.merge/2 the start metadata so
        # method / datadog_service_name survive on the stop event.
        :telemetry.span([:http_car_req, :request], metadata, fn ->
          try do
            request_options
            |> client()
            |> Req.request()
            |> case do
              {:ok, response_struct} = response ->
                {response, Map.merge(metadata, %{status_code: response_struct.status})}

              {:error, exception} = response ->
                {response, Map.merge(metadata, %{reason: exception})}
            end
          rescue
            Jason.DecodeError ->
              {{:error, :json_decode_error}, Map.merge(metadata, %{reason: :json_decode_error})}

            error ->
              # Finch raises a RuntimeError for pool timeouts.
              if Map.get(error, :message, "") =~ "Finch was unable to provide a connection" do
                {{:error, :pool_timeout}, Map.merge(metadata, %{reason: :pool_timeout})}
              else
                {{:error, inspect(error)}, Map.merge(metadata, %{reason: inspect(error)})}
              end
          end
        end)
      end

      @doc """
      client/1 build the Req.Request struct and invokes merge_options/1 to 'correctly' merge the
      various options.
      """
      def client(request_options \\ []) do
        request_options
        |> merge_options()
        |> CarReq.client()
      end

      @doc "Merge the various options specific onto general: @options -> client_options/0 -> request_options"
      def merge_options(request_options) do
        @options
        |> Keyword.merge(implementing_module: __MODULE__)
        |> Keyword.merge(client_options())
        |> Keyword.merge(request_options)
      end

      resource_name_override = Keyword.get(opts, :resource_name_override)

      defp telemetry_metadata(request_options) do
        %{
          datadog_service_name:
            Keyword.get(request_options, :datadog_service_name, @datadog_service_name),
          url: Keyword.get(request_options, :url),
          method: Keyword.get(request_options, :method),
          resource_name_override:
            Keyword.get(request_options, :resource_name_override, unquote(resource_name_override)),
          query_params: Keyword.get(request_options, :params)
        }
      end

      @doc "Set runtime options. Implement this callback for settings that will be dynamic per env."
      @impl CarReq
      def client_options, do: []

      defoverridable client_options: 0
    end
  end
end
