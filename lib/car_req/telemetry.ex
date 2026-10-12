defmodule CarReq.Telemetry do
  @moduledoc """
  Wrap Req steps in a telemetry span.

  Step exception events expose only the exception module name, with an empty
  stacktrace because stacktrace arguments can contain sensitive values. The
  original exception and stacktrace are re-raised for the caller to handle.
  Throw and exit events retain their original metadata.
  """

  @doc "Wrap request steps in spans with sanitized exception metadata."
  def request_spanner(steps) do
    span_steps(steps, :request)
  end

  @doc "Wrap response steps in spans with sanitized exception metadata."
  def response_spanner(steps) do
    span_steps(steps, :response)
  end

  @doc false
  @spec exception_reason(Exception.t()) :: {:unexpected_exception, String.t()}
  def exception_reason(error) do
    {:unexpected_exception, inspect(error.__struct__)}
  end

  defp span_steps(steps, phase) do
    Enum.map(steps, fn {name, step_fn} ->
      meta = %{step_name: name, step_phase: phase}

      {name,
       fn request ->
         span_step(step_fn, request, meta)
       end}
    end)
  end

  # telemetry.span/3 emits the raw exception before re-raising it, so sanitization
  # must happen here rather than in the outer request rescue.
  defp span_step(step_fn, request, metadata) do
    start_time = System.monotonic_time()
    metadata = Map.put(metadata, :telemetry_span_context, make_ref())

    :telemetry.execute(
      [:req, :step, :start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      metadata
    )

    try do
      result = step_fn.(request)
      :telemetry.execute([:req, :step, :stop], stop_measurements(start_time), metadata)
      result
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        exception_metadata = exception_metadata(kind, reason, stacktrace)

        :telemetry.execute(
          [:req, :step, :exception],
          stop_measurements(start_time),
          Map.merge(metadata, exception_metadata)
        )

        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp exception_metadata(:error, reason, stacktrace) do
    error = Exception.normalize(:error, reason, stacktrace)
    %{kind: :error, reason: exception_reason(error), stacktrace: []}
  end

  defp exception_metadata(kind, reason, stacktrace) do
    %{kind: kind, reason: reason, stacktrace: stacktrace}
  end

  defp stop_measurements(start_time) do
    stop_time = System.monotonic_time()
    %{duration: stop_time - start_time, monotonic_time: stop_time}
  end
end
