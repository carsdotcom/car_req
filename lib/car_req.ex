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
  """
  def client(client_options, compiled_options, module) do
    options =
      compiled_options
      |> Keyword.merge(implementing_module: module)
      |> Keyword.merge(client_options)

    Req.new()
    |> Req.Request.register_options([
      :datadog_service_name,
      :implementing_module
    ])
    |> LogStep.attach()
    |> CarReq.attach_circuit_breaker(options)
    |> Req.update(options)
  end

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

      @doc "Build up the Req client; merge @options, client_options/0, and request_options"
      def client(request_options \\ []) do
        opts = Keyword.merge(client_options(), request_options)
        CarReq.client(opts, @options, __MODULE__)
      end

      @doc "Set runtime options. Implement this callback for settings that will be dynamic per env."
      @impl CarReq
      def client_options, do: []

      defoverridable client_options: 0
    end
  end
end
