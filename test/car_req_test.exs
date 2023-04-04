defmodule CarReqTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CarReq
  alias CarReq.Adapter

  doctest CarReq

  def handle_event(event, measurements, meta, pid) do
    send(pid, {:event, event, measurements, meta})
  end

  setup context do
    name = context.test

    :telemetry.attach_many(
      "http-client-test",
      [
        [:http_car_req, :request, :start],
        [:http_car_req, :request, :stop],
        [:http_car_req, :request, :exception]
      ],
      &__MODULE__.handle_event/4,
      self()
    )

    on_exit(fn ->
      :fuse.reset(TestImpl)
      :fuse.remove(name)
      :fuse.remove(TestImpl)
      :telemetry.detach("http-client-test")
    end)

    {:ok, name: name}
  end

  defmodule TestImpl do
    use CarReq

    @impl true
    def base_url, do: ""
  end

  @moduletag :capture_log
  describe "use CarReq/1" do
    test "with no opts has reasonable defaults" do
      assert {:ok, response} = TestImpl.request(method: :get, url: "https://www.example.com/")

      assert response.status == 200
    end

    test "configure client", %{name: name} do
      defmodule TestClientImpl do
        use CarReq,
          fuse_name: name

        @impl true
        def base_url, do: "https://www.example.com"
      end

      assert {:ok, response} =
               TestClientImpl.request(method: :get, url: "https://www.example.com/")

      assert response.status == 200
      :fuse.remove(TestClientImpl)
    end

    test "base_url path is maintained" do
      defmodule TestBaseURLImpl do
        use CarReq

        @impl true
        def base_url, do: "https://www.example.com/this_path_SHOULDNT_get_dropped"
      end

      defmodule TestBaseTrailingSlashImpl do
        use CarReq

        @impl true
        def base_url, do: "https://www.example.com/this_path_SHOULDNT_get_dropped/"
      end

      defmodule TestBaseNoSchemeImpl do
        use CarReq

        @impl true
        def base_url, do: "www.example.com/this_path_SHOULDNT_get_dropped"
      end

      defmodule TestBaseTrailingSlashNoSchemeImpl do
        use CarReq

        @impl true
        def base_url, do: "www.example.com/this_path_SHOULDNT_get_dropped/"
      end

      fake = fn %{url: uri} = request ->
        assert uri.host == "www.example.com"
        assert uri.path == "/this_path_SHOULDNT_get_dropped/" <> "an/override/path"
        {request, Req.Response.new()}
      end

      assert {:ok, _response} =
               TestBaseURLImpl.request(method: :get, url: "an/override/path", adapter: fake)

      assert {:ok, _response} =
               TestBaseURLImpl.request(method: :get, url: "/an/override/path", adapter: fake)

      assert {:ok, _response} =
               TestBaseTrailingSlashImpl.request(
                 method: :get,
                 url: "an/override/path",
                 adapter: fake
               )

      assert {:ok, _response} =
               TestBaseTrailingSlashImpl.request(
                 method: :get,
                 url: "/an/override/path",
                 adapter: fake
               )

      fake = fn %{url: uri} = request ->
        assert uri.host == nil
        assert uri.path == "www.example.com/this_path_SHOULDNT_get_dropped/" <> "an/override/path"
        {request, Req.Response.new()}
      end

      assert {:ok, _response} =
               TestBaseNoSchemeImpl.request(method: :get, url: "an/override/path", adapter: fake)

      assert {:ok, _response} =
               TestBaseNoSchemeImpl.request(method: :get, url: "/an/override/path", adapter: fake)

      assert {:ok, _response} =
               TestBaseTrailingSlashNoSchemeImpl.request(
                 method: :get,
                 url: "an/override/path",
                 adapter: fake
               )

      assert {:ok, _response} =
               TestBaseTrailingSlashNoSchemeImpl.request(
                 method: :get,
                 url: "/an/override/path",
                 adapter: fake
               )
    end

    test "handles finch pool_timeout", %{name: name} do
      defmodule TestPoolTimeout do
        use CarReq,
          fuse_name: name,
          pool_timeout: 0

        @impl true
        def base_url, do: "https://www.example.com"
      end

      assert {:error, :pool_timeout} = TestPoolTimeout.request(url: "/")
    end

    test "handles finch receive_timeout", %{name: name} do
      defmodule TestFinchTimeout do
        use CarReq,
          receive_timeout: 0,
          fuse_name: name

        @impl true
        def base_url, do: "https://www.example.com"
      end

      assert {:error, %Mint.TransportError{reason: :timeout}} =
               TestFinchTimeout.request(
                 method: :get,
                 url: "/electric-flying-cars",
                 adapter: &Req.Steps.run_finch/1
               )
    end

    test "setting :implementing_module, raises", %{name: name} do
      assert_raise NimbleOptions.ValidationError, fn ->
        defmodule TestRaiseName do
          use CarReq, implementing_module: :my_custom_default_name

          @impl true
          def base_url, do: ""
        end

        TestRaiseName.request(method: :get, url: "http://httpstat.us/200")
      end
    end

    test "returns Req.Response" do
      defmodule TestDefaultResponse do
        use CarReq

        @impl true
        def base_url, do: ""
      end

      assert {:ok, %Req.Response{}} =
               TestDefaultResponse.request(
                 method: :get,
                 url: "http://httpstat.us/200",
                 adapter: &Adapter.success/1
               )
    end

    test "sets retry false" do
      defmodule TestRetryResponse do
        use CarReq, retry: false

        @impl true
        def base_url, do: ""
      end

      assert {:ok, %Req.Response{}} =
               TestRetryResponse.request(
                 method: :get,
                 url: "http://httpstat.us/500",
                 adapter: &Adapter.failed/1
               )
    end

    test "retry true raises ValidationError" do
      assert_raise NimbleOptions.ValidationError, fn ->
        defmodule TestRetryTrue do
          use CarReq, retry: true

          @impl true
          def base_url, do: ""
        end
      end
    end

    test "override the adapter via request option" do
      fake_out = fn request ->
        {request, Req.Response.json(%{json_body: "That was reasy"})}
      end

      assert {:ok, %{status: 200} = response} =
               TestImpl.request(method: :get, url: "https://www.example.com/", adapter: fake_out)

      assert response.body["json_body"] == "That was reasy"
    end

    test "override timeout options to Req client" do
      assert {:error, :pool_timeout} =
               TestImpl.request(url: "http://www.sssnakes.com", pool_timeout: 0)

      assert {:error, %{reason: :timeout}} =
               TestImpl.request(url: "http://www.sssnakes.com", receive_timeout: 0)
    end

    test "only valid request_options are permitted" do
      assert_raise ArgumentError, "unknown option :mathematical", fn ->
        TestImpl.request(mathematical: :get)
      end
    end
  end

  describe "use CarReq/1 check steps" do
    test "circuit breaker is configured default" do
      defmodule TestFuseDefault do
        use CarReq

        @impl true
        def base_url, do: "https://www.example.com"
      end

      TestFuseDefault

      assert {:error, :not_found} = :fuse.ask(TestFuseDefault, :sync)
      TestFuseDefault.request(method: :get, url: "http://httpstat.us/200")
      assert :ok = :fuse.ask(TestFuseDefault, :sync)
    end

    test "fuse triggers circuit breaks", %{name: name} do
      defmodule TestFuseImpl do
        use CarReq,
          fuse_opts: {{:standard, 1, 1000}, {:reset, 300}},
          fuse_name: name

        @impl true
        def base_url, do: ""
      end

      TestFuseImpl.request(
        method: :get,
        url: "http://httpstat.us/200",
        adapter: &Adapter.failed/1
      )

      :fuse.melt(name)
      assert :fuse.ask(name, :sync) == :blown

      assert {:error, %RuntimeError{message: "circuit breaker is open"}} =
               TestFuseImpl.request(method: :get, url: "http://httpstat.us/500")

      # reset the circuit
      :fuse.reset(name)
      assert :fuse.ask(name, :sync) == :ok
    end

    test "Req exceptions trigger circuit breaks", %{name: name} do
      defmodule TestFuseExceptionImpl do
        use CarReq,
          fuse_opts: {{:standard, 1, 1000}, {:reset, 300}},
          fuse_name: name,
          retry: :safe,
          max_retries: 2,
          retry_delay: 50

        @impl true
        def base_url, do: ""
      end

      exception = fn request ->
        {request, %RuntimeError{message: "something we real wrong"}}
      end

      TestFuseExceptionImpl.request(
        method: :get,
        url: "http://httpstat.us/200",
        adapter: exception
      )

      TestFuseExceptionImpl.request(
        method: :get,
        url: "http://httpstat.us/500",
        receive_timeout: 0
      )

      assert :fuse.ask(name, :sync) == :blown
    end

    test "fuse + open circuit with retries", %{name: name} do
      defmodule TestRetryFuseImpl do
        use CarReq,
          fuse_opts: {{:standard, 1, 1000}, {:reset, 300}},
          fuse_name: name,
          retry: :safe,
          max_retries: 2,
          retry_delay: &CarReqTest.delay/1

        @impl true
        def base_url, do: ""
      end

      # retries with bad request and circuit is closed.
      logs =
        capture_log(fn ->
          TestRetryFuseImpl.request(
            method: :get,
            url: "http://httpstat.us/500",
            adapter: &Adapter.failed/1
          )
        end)

      assert logs =~ "retry: got response with status 500, will retry in"
      assert logs =~ "2 attempts left"
      assert logs =~ "1 attempt left"
      :fuse.melt(name)

      # retries with bad request and circuit is open.
      logs =
        capture_log(fn ->
          TestRetryFuseImpl.request(method: :get, url: "http://httpstat.us/500")
        end)

      # no retries
      refute logs =~ "retry: got response with status 500, will retry in"
      refute logs =~ "2 attempts left"
      refute logs =~ "1 attempt left"
      assert :fuse.ask(name, :sync) == :blown

      assert {:error, %RuntimeError{message: "circuit breaker is open"}} =
               TestRetryFuseImpl.request(method: :get, url: "http://httpstat.us/500")
    end

    test "default fuse name to module" do
      defmodule TestFuseDefaultNameImpl do
        use CarReq,
          fuse_opts: {{:standard, 1, 1000}, {:reset, 30_000}}

        @impl true
        def base_url, do: ""
      end

      TestFuseDefaultNameImpl.request(
        method: :get,
        url: "http://httpstat.us/500",
        adapter: &Adapter.failed/1
      )

      assert :fuse.ask(TestFuseDefaultNameImpl, :sync) == :ok

      TestFuseDefaultNameImpl.request(
        method: :get,
        url: "http://httpstat.us/500",
        adapter: &Adapter.failed/1
      )

      assert :fuse.ask(TestFuseDefaultNameImpl, :sync) == :blown
      :fuse.remove(TestFuseDefaultNameImpl)
    end

    test "override fuse name" do
      defmodule TestFuseNameImpl do
        use CarReq,
          fuse_opts: {{:standard, 1, 1000}, {:reset, 30_000}},
          fuse_name: My.Test.Fuse

        @impl true
        def base_url, do: ""
      end

      TestFuseNameImpl.request(
        method: :get,
        url: "http://httpstat.us/500",
        adapter: &Adapter.failed/1
      )

      assert :fuse.ask(My.Test.Fuse, :sync) == :ok

      TestFuseNameImpl.request(
        method: :get,
        url: "http://httpstat.us/500",
        adapter: &Adapter.failed/1
      )

      assert :fuse.ask(My.Test.Fuse, :sync) == :blown
      :fuse.remove(My.Test.Fuse)
    end

    test "override fuse name with request options" do
      defmodule TestRuntimeFuseNameImpl do
        use CarReq,
          fuse_opts: {{:standard, 1, 1000}, {:reset, 30_000}},
          fuse_name: My.Test.Fuse

        @impl true
        def base_url, do: ""
      end

      TestRuntimeFuseNameImpl.request(
        method: :get,
        url: "http://httpstat.us/500",
        adapter: &Adapter.failed/1,
        fuse_name: My.Other.Test.Fuse,
        fuse_opts: {{:standard, 2, 1000}, {:reset, 30_000}}
      )

      assert :fuse.ask(My.Other.Test.Fuse, :sync) == :ok

      TestRuntimeFuseNameImpl.request(
        method: :get,
        url: "http://httpstat.us/500",
        adapter: &Adapter.failed/1,
        fuse_name: My.Other.Test.Fuse,
        fuse_opts: {{:standard, 21, 1000}, {:reset, 30_000}}
      )

      assert :fuse.ask(My.Other.Test.Fuse, :sync) == :ok
      assert :fuse.ask(My.Test.Fuse, :sync) == {:error, :not_found}

      TestRuntimeFuseNameImpl.request(
        method: :get,
        url: "http://httpstat.us/500",
        adapter: &Adapter.failed/1,
        fuse_name: My.Other.Test.Fuse,
        fuse_opts: {{:standard, 2, 1000}, {:reset, 30_000}}
      )

      assert :fuse.ask(My.Other.Test.Fuse, :sync) == :blown
      assert :fuse.ask(My.Test.Fuse, :sync) == {:error, :not_found}
      :fuse.remove(My.Other.Test.Fuse)
    end

    test "circuit_breaker unset, ALL defaults", %{name: name} do
      defmodule TestDefaultFuseImpl do
        use CarReq,
          fuse_name: name

        @impl true
        def base_url, do: ""
      end

      TestDefaultFuseImpl.request(
        method: :get,
        url: "http://httpstat.us/200",
        adapter: &Adapter.success/1
      )

      assert :ok = :fuse.ask(name, :sync)
    end

    test "fuse disabled, skips fuse", %{name: name} do
      defmodule TestNoFuseImpl do
        use CarReq, fuse_opts: :disabled

        @impl true
        def base_url, do: ""
      end

      TestNoFuseImpl.request(
        method: :get,
        url: "http://httpstat.us/500",
        adapter: &Adapter.failed/1
      )

      assert {:error, :not_found} = :fuse.ask(TestNoFuseImpl, :sync)

      TestNoFuseImpl.request(
        method: :get,
        url: "http://httpstat.us/500",
        adapter: &Adapter.failed/1
      )

      assert {:error, :not_found} = :fuse.ask(TestNoFuseImpl, :sync)
    end

    test "fuse_opts: :disabled as request option, skips fuse", %{name: name} do
      defmodule TestFuseDisabledImpl do
        use CarReq

        @impl true
        def base_url, do: ""
      end

      TestFuseDisabledImpl.request(
        method: :get,
        url: "http://httpstat.us/500",
        adapter: &Adapter.success/1
      )

      Enum.each(1..11, fn _ ->
        :fuse.melt(TestFuseDisabledImpl)
      end)

      assert :blown = :fuse.ask(TestFuseDisabledImpl, :sync)

      assert {:ok, %Req.Response{}} =
               TestFuseDisabledImpl.request(
                 method: :get,
                 url: "http://httpstat.us/200",
                 adapter: &Adapter.success/1,
                 fuse_opts: :disabled
               )
    end

    test "emit logs for 500 + statuses" do
      log =
        capture_log(fn ->
          TestImpl.request(
            method: :get,
            url: "http://httpstat.us/500",
            adapter: &Adapter.failed/1
          )
        end)

      assert log =~ "[warning] CarReq request failed"
    end

    test "emit log with an MFA logger function" do
      defmodule TestLogEmission do
        use CarReq, log_function: &__MODULE__.log_function/1
        require Logger
        @impl true
        def base_url, do: ""

        def log_function({_request, response}) do
          if response.status >= 400 do
            Logger.warning("my WARNING message; module: #{__MODULE__}")
          else
            :ok
          end
        end
      end

      logs =
        capture_log(fn ->
          TestLogEmission.request(
            method: :get,
            url: "http://httpstat.us/499",
            adapter: &Adapter.not_found/1
          )
        end)

      assert logs =~ "[warning] my WARNING message; module: Elixir.CarReqTest.TestLogEmission"
    end

    test ":none don't emit log messages" do
      defmodule TestLogSuppression do
        use CarReq, log_function: :none
        @impl true
        def base_url, do: ""
      end

      logs =
        capture_log(fn ->
          TestLogSuppression.request(
            method: :get,
            url: "http://httpstat.us/500",
            adapter: &Adapter.failed/1
          )
        end)

      assert logs =~ ""
    end

    test "with invalid finch supervisor name" do
      defmodule TestBadFinch do
        use CarReq,
          finch: CarReq.Finch

        @impl true
        def base_url, do: ""
      end

      resp =
        TestBadFinch.request(
          method: :get,
          url: "http://httpstat.us/500",
          receive_timeout: 10
        )

      assert resp == {:error, "%ArgumentError{message: \"unknown registry: CarReq.Finch\"}"}
    end

    test "with valid finch supervisor name" do
      start_supervised!({Finch, name: CarReq.FinchSupervisor})

      defmodule TestFinch do
        use CarReq,
          finch: CarReq.FinchSupervisor

        @impl true
        def base_url, do: ""
      end

      # set a receive timeout, long enough that we get a pool worker from the Finch supervisor, but
      # short enough so we don't wait on a real HTTP call.

      resp =
        TestFinch.request(
          method: :get,
          url: "http://httpstat.us/200",
          receive_timeout: 2
        )

      assert resp == {:error, %Mint.TransportError{reason: :timeout}}
    end

    test "set finch in request options" do
      start_supervised!({Finch, name: CarReq.FinchSupervisor})

      defmodule TestRuntimeFinch do
        use CarReq

        @impl true
        def base_url, do: ""
      end

      # set a receive timeout long enough that we get a pool worker from the Finch supervisor, but
      # short enough so we don't wait on a real HTTP call.

      resp =
        TestRuntimeFinch.request(
          finch: CarReq.FinchSupervisor,
          method: :get,
          receive_timeout: 2,
          url: "http://httpstat.us/200"
        )

      assert resp == {:error, %Mint.TransportError{reason: :timeout}}
    end
  end

  describe "request/1" do
    test "works with no opts and the slimmest implementation" do
      assert {:ok, response} = TestImpl.request(method: :get, url: "https://www.example.com/")
      assert response.status == 200
    end

    test "when given malformed JSON, captures exception" do
      actual_malformed_dealerrater_response = """
      <html>
      <head><title>503 Service Temporarily Unavailable</title></head>
      <body>
      <center><h1>503 Service Temporarily Unavailable</h1></center>
      </body>
      </html>
      """

      fake_out = fn request ->
        {request,
         Req.Response.new(
           status: 500,
           headers: [{"content-type", "application/json"}],
           body: actual_malformed_dealerrater_response
         )}
      end

      assert {:error, :json_decode_error} =
               TestImpl.request(method: :get, url: "https://www.example.com/", adapter: fake_out)
    end
  end

  describe "validate_options!/1" do
    test "raises" do
      assert_raise NimbleOptions.ValidationError, fn ->
        CarReq.validate_options!(not_client_options: :what!)
      end
    end
  end

  describe "telemetry events" do
    test "sends a start and stop event when making a request" do
      TestImpl.request(method: :get, url: "https://www.example.com/")
      assert_receive {:event, [:http_car_req, :request, :start], _, _}
      assert_receive {:event, [:http_car_req, :request, :stop], _, _}
    end

    test "sends an exception event when a pool timeout occurs" do
      defmodule PoolTimeoutClient do
        use CarReq,
          pool_timeout: 0

        @impl true
        def base_url, do: "https://www.example.com"
      end

      PoolTimeoutClient.request(url: "http://www.sssnakes.com")
      assert_receive {:event, [:http_car_req, :request, :start], _, _}
      assert_receive {:event, [:http_car_req, :request, :stop], _, %{reason: :pool_timeout}}
    end

    test "adds an error reason to stop message when req response is error" do
      defmodule TimeoutClient do
        use CarReq,
          receive_timeout: 0

        @impl true
        def base_url, do: "https://www.example.com"
      end

      TimeoutClient.request(method: :get, url: "/200", adapter: &Req.Steps.run_finch/1)

      assert_receive {:event, [:http_car_req, :request, :stop], _,
                      %{reason: %Mint.TransportError{reason: :timeout}}}
    end

    test "allows service name to be set on client" do
      defmodule ServiceNameClient do
        use CarReq,
          telemetry_service_name: :foo_bar_baz

        @impl true
        def base_url, do: "https://www.example.com"
      end

      ServiceNameClient.request(method: :get, url: "/200", adapter: &Adapter.success/1)

      assert_receive {:event, [:http_car_req, :request, :start], _,
                      %{telemetry_service_name: :foo_bar_baz}}
    end

    test "allows service name to be set per-request on the client" do
      defmodule ServiceNameRuntimeClient do
        use CarReq,
          telemetry_service_name: :foo_bar_baz

        @impl true
        def base_url, do: "https://www.example.com"
      end

      ServiceNameRuntimeClient.request(
        method: :get,
        url: "/200",
        adapter: &Adapter.success/1,
        telemetry_service_name: :guu_car_caz
      )

      assert_receive {:event, [:http_car_req, :request, :start], _,
                      %{telemetry_service_name: :guu_car_caz}}
    end

    test "determines service name for external namespaced clients" do
      defmodule Test.Foo.Bar.External.Service.ServiceNameClient do
        use CarReq

        @impl true
        def base_url, do: "https://www.example.com"
      end

      Test.Foo.Bar.External.Service.ServiceNameClient.request(
        method: :get,
        url: "/200",
        adapter: &Adapter.success/1
      )

      assert_receive {:event, [:http_car_req, :request, :start], _,
                      %{telemetry_service_name: :service_service_name_client}}
    end

    test "defaults to the full module name" do
      defmodule Test.Foo.Bar.Service.ServiceNameClient do
        use CarReq

        @impl true
        def base_url, do: "https://www.example.com"
      end

      Test.Foo.Bar.Service.ServiceNameClient.request(
        method: :get,
        url: "/200",
        adapter: &Adapter.success/1
      )

      assert_receive {:event, [:http_car_req, :request, :start], _,
                      %{
                        telemetry_service_name:
                          :car_req_test_test_foo_bar_service_service_name_client
                      }}
    end
  end

  describe "client/1" do
    test "client/1 doesn't duplicate the auth header", %{name: name} do
      defmodule TestClientDupeHeaderImpl do
        use CarReq,
          fuse_name: name

        @impl true
        def base_url, do: "https://www.example.com"
      end

      auth_header = [{"authorization", "Token Shh, it's a secret"}]
      client = TestClientDupeHeaderImpl.client(headers: auth_header)

      assert client.headers == auth_header
    end
  end

  @doc """
  Support a custom delay for `:retry_delay`.
  `:retry_delay` must be of the form Mod.fun/arity.
  """
  def delay(_count) do
    100
  end
end
