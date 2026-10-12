defmodule CarReq.Telemetry do
  @moduledoc """
  Telemetry spans for CarReq requests and Req steps.

  Exception events carry sanitized metadata, because exception fields, exit
  reasons, and stacktrace arguments can contain response bodies or credentials:

    * raised exceptions report `{:unexpected_exception, "<exception module name>"}`
    * throw and exit reasons keep only an atom reason, or the leading atom of a
      tuple reason, such as `:timeout`. Any other reason reports `:redacted`.
    * stacktrace frames keep module, function, arity, file, and line

  The original exception, reason, and stacktrace still propagate to the caller.
  """

  @location_keys [:file, :line]

  @doc "Wrap request steps in spans with sanitized exception metadata."
  def request_spanner(steps) do
    span_steps(steps, :request)
  end

  @doc "Wrap response steps in spans with sanitized exception metadata."
  def response_spanner(steps) do
    span_steps(steps, :response)
  end

  @doc """
  Same contract as `:telemetry.span/3` for a span function returning
  `{result, stop_metadata}`, except that `exception` events carry sanitized
  `reason` and `stacktrace` values.
  """
  @spec span(:telemetry.event_prefix(), map(), (-> {term(), map()})) :: term()
  def span(event_prefix, start_metadata, span_function) do
    start_time = System.monotonic_time()
    start_metadata = Map.put_new(start_metadata, :telemetry_span_context, make_ref())

    :telemetry.execute(
      event_prefix ++ [:start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      start_metadata
    )

    try do
      {result, stop_metadata} = span_function.()

      stop_metadata =
        Map.put_new(stop_metadata, :telemetry_span_context, start_metadata.telemetry_span_context)

      :telemetry.execute(event_prefix ++ [:stop], stop_measurements(start_time), stop_metadata)
      result
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__

        :telemetry.execute(
          event_prefix ++ [:exception],
          stop_measurements(start_time),
          Map.merge(start_metadata, %{
            kind: kind,
            reason: sanitize_reason(kind, reason, stacktrace),
            stacktrace: sanitize_stacktrace(stacktrace)
          })
        )

        :erlang.raise(kind, reason, stacktrace)
    end
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
         span([:req, :step], meta, fn -> {step_fn.(request), meta} end)
       end}
    end)
  end

  defp sanitize_reason(:error, reason, stacktrace) do
    :error
    |> Exception.normalize(reason, stacktrace)
    |> exception_reason()
  end

  defp sanitize_reason(_kind, reason, _stacktrace) when is_atom(reason), do: reason

  defp sanitize_reason(_kind, reason, _stacktrace)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp sanitize_reason(_kind, _reason, _stacktrace), do: :redacted

  # Location lists may also hold :error_info, whose :cause can be any term.
  defp sanitize_stacktrace(stacktrace) do
    Enum.map(stacktrace, fn {module, function, arity_or_args, location} ->
      {module, function, arity(arity_or_args), Keyword.take(location, @location_keys)}
    end)
  end

  defp arity(args) when is_list(args), do: length(args)
  defp arity(arity), do: arity

  defp stop_measurements(start_time) do
    stop_time = System.monotonic_time()
    %{duration: stop_time - start_time, monotonic_time: stop_time}
  end
end
