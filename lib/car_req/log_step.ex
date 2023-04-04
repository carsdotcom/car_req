defmodule CarReq.LogStep do
  @moduledoc """
  Handle logging in CarReq.

  By default will emit a log for any status >= 500.

  Logging can be skipped by passing the atom: `:none` in the `:log_function` option.

  You can configure a custom log function to handle the specific loggable cases by implementing a
  1-arity function that receives a `{request, response}` tuple, emits any log messages you deisre,
  and returns the same `{request, response}` tuple.

  ### Example
  ```elixir
    defmodule MyLoggerMod do
      require Logger
      def emit({request, response}) do
        # some logic, probably based on the response
        Logger.warning("a WARN-able situation")
        {request, response}
      end
    end

    defmodule ExampleImpl do
      use CarReq, log_function: &MyLoggerMod.emit/1
    end
  ```
  """

  require Logger

  @doc """
  Attach logging step.

  ## Request Options

    * `:log_function` - (optional) a user-defined function to handle logging
    * `:implementing_module` - a reference to the module where `use CarReq` is invoked.

  Explicit opt-out via `log_function: :none`
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = request, _options \\ []) do
    request
    |> Req.Request.register_options([:log_function, :implementing_module])
    |> Req.Request.append_response_steps(log_function: &log_function/1)
  end

  defp log_function({request, response}) do
    _ =
      request.options
      |> Map.get(:log_function)
      |> case do
        nil ->
          emit_log({request, response})

        :none ->
          :ok

        log_function ->
          log_function.({request, response})
      end

    {request, response}
  end

  defp emit_log({request, response}) do
    if response.status > 499 do
      message =
        Enum.reduce(
          [
            module: request.options.implementing_module,
            status: response.status,
            body: set_body(response.body),
            url: to_string(request.url)
          ],
          "",
          fn
            {key, value}, acc -> acc <> "#{key}: #{inspect(value)}\n"
            value, acc -> acc <> "#{inspect(value)}\n"
          end
        )

      Logger.warning("CarReq request failed " <> message)
    else
      :ok
    end
  end

  defp set_body(body) when is_binary(body), do: body
  defp set_body(body), do: inspect(body)
end
