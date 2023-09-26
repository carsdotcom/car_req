defmodule LogStepTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias CarReq.Adapter
  alias CarReq.LogStep

  require Logger

  describe "attach/3" do
    test "no logger behavior when :none" do
      module = This.Name.Should.Not.Appear.In.The.Log
      options = [implementing_module: module, log_function: :none, retry: false]

      req =
        Req.new(adapter: &Adapter.failed/1)
        |> LogStep.attach()
        |> Req.Request.merge_options(options)

      log =
        capture_log(fn ->
          Req.request!(req)
        end)

      # assert no CarReq logs appear.
      refute log =~ "[warning] CarReq request failed"
      refute log =~ "module=#{module}"
    end

    test "log_function as atom other than `:none` raises exception" do
      options = [log_function: :what_did_you_expect_to_happen?, retry: false]

      req =
        Req.new(adapter: &Adapter.failed/1)
        |> LogStep.attach()
        |> Req.Request.merge_options(options)

      # It's not that this is the desired outcome, but arbitrary atoms aren't supported in
      # the LogStep module, so this is what you get.
      assert_raise BadFunctionError, fn -> Req.request!(req) end
    end

    test "no log for successes under default logger behavior when not configured" do
      module = This.Name.Should.Not.Appear.In.The.Log
      options = [implementing_module: module]

      req =
        Req.new(adapter: &Adapter.success/1)
        |> LogStep.attach()
        |> Req.Request.merge_options(options)

      log =
        capture_log(fn ->
          Req.request!(req)
        end)

      # assert no CarReq logs appear.
      refute log =~ "[warning] CarReq request failed"
      refute log =~ "module=#{module}"
    end

    test "emit log in default logger behavior when log_fn not configured and status >= 500" do
      module = This.Test.Module
      options = [implementing_module: module, retry: false]

      stub_adapter = fn request ->
        response =
          Req.Response.new(
            status: 500,
            body: "uh-oh spaghetti-Os"
          )

        {request, response}
      end

      req =
        Req.new(adapter: stub_adapter, url: "http://uh-oh.com")
        |> LogStep.attach()
        |> Req.Request.merge_options(options)

      logs =
        capture_log(fn ->
          Req.request!(req)
        end)

      assert logs =~ "[warning] CarReq request failed"
      assert logs =~ "module: This.Test.Module"
      assert logs =~ "status: 500"
      assert logs =~ "body: \"uh-oh spaghetti-Os\""
      assert logs =~ "url: \"http://uh-oh.com\""
    end

    test "handle body when a map" do
      module = This.Test.Module
      options = [implementing_module: module, retry: false]
      error_json = Jason.encode!(%{error: "there's an error"})

      stub_adapter = fn request ->
        response =
          Req.Response.new(
            status: 500,
            body: error_json,
            headers: [{"content-type", "application/json"}]
          )

        {request, response}
      end

      req =
        Req.new(adapter: stub_adapter, url: "http://uh-oh.com")
        |> LogStep.attach()
        |> Req.Request.merge_options(options)

      logs =
        capture_log(fn ->
          Req.request!(req)
        end)

      assert logs =~ "[warning] CarReq request failed"
      assert logs =~ "module: This.Test.Module"
      assert logs =~ "body: \"%{\\\"error\\\" => \\\"there's an error\\\"}\""
    end

    test "emit log in with a configured logger function" do
      module = This.Test.Module

      adapter412 = fn request ->
        response =
          Req.Response.new(
            status: 412,
            body: "this is a very special kind of warn-able state"
          )

        {request, response}
      end

      adapter500 = fn request ->
        response =
          Req.Response.new(
            status: 500,
            body: "this is a very typical error state"
          )

        {request, response}
      end

      adapter200 = fn request ->
        response =
          Req.Response.new(
            status: 200,
            body: "this is a the happiest path"
          )

        {request, response}
      end

      log_func = fn {_request, response} ->
        cond do
          response.status > 411 && response.status < 500 ->
            message =
              Enum.reduce(
                [
                  module: module,
                  status: response.status,
                  body: response.body
                ],
                "",
                fn
                  {key, value}, acc -> acc <> "#{key}: #{inspect(value)}\n"
                  value, acc -> acc <> "#{inspect(value)}\n"
                end
              )

            Logger.warning("this is my WARNING logger state " <> message)

          response.status > 499 ->
            message =
              Enum.reduce(
                [
                  module: module,
                  status: response.status,
                  body: response.body
                ],
                "",
                fn
                  {key, value}, acc -> acc <> "#{key}: #{inspect(value)}\n"
                  value, acc -> acc <> "#{inspect(value)}\n"
                end
              )

            Logger.error("this is my ERROR logger state " <> message)

          true ->
            :ok
        end
      end

      options = [implementing_module: module, retry: false, log_function: log_func]

      req =
        Req.new(adapter: adapter412)
        |> Req.Request.register_options([:implementing_module])
        |> LogStep.attach()
        |> Req.Request.merge_options(options)

      logs =
        capture_log(fn ->
          Req.request!(req)
        end)

      assert logs =~ "[warning] this is my WARNING logger state"
      assert logs =~ "module: This.Test.Module"

      req =
        Req.new(adapter: adapter500)
        |> Req.Request.register_options([:implementing_module])
        |> LogStep.attach()
        |> Req.Request.merge_options(options)

      logs =
        capture_log(fn ->
          Req.request!(req)
        end)

      assert logs =~ "[error] this is my ERROR logger state"
      assert logs =~ "module: This.Test.Module"

      req =
        Req.new(adapter: adapter200)
        |> Req.Request.register_options([:implementing_module])
        |> LogStep.attach()
        |> Req.Request.merge_options(options)

      logs =
        capture_log(fn ->
          Req.request!(req)
        end)

      # assert no CarReq logs appear.
      refute logs =~ "[warning] CarReq request"
      refute logs =~ "module=#{module}"
    end

    test "emit log with logger function as ModFnArity" do
      module = This.Test.Module

      adapter412 = fn request ->
        response =
          Req.Response.new(
            status: 412,
            body: "this is a very special kind of warn-able state"
          )

        {request, response}
      end

      defmodule MyLoggger do
        def emit({_request, response}) do
          cond do
            response.status > 411 && response.status < 500 ->
              Logger.warning("this is my ModFnArity WARNING logger state",
                module: __MODULE__,
                status: response.status,
                body: response.body
              )

            response.status > 499 ->
              Logger.error("this is my ERROR logger state")

            true ->
              :ok
          end
        end
      end

      options = [implementing_module: module, retry: false, log_function: &MyLoggger.emit/1]

      req =
        Req.new(adapter: adapter412)
        |> Req.Request.register_options([:implementing_module])
        |> LogStep.attach()
        |> Req.Request.merge_options(options)

      logs =
        capture_log(fn ->
          Req.request!(req)
        end)

      assert logs =~ "[warning] this is my ModFnArity WARNING logger state"
    end
  end
end
