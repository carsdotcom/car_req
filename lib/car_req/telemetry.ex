defmodule CarReq.Telemetry do
  @moduledoc """
  Wrap Req steps in a telemetry span.
  """

  def request_spanner(steps) do
    span_steps(steps, :request)
  end

  def response_spanner(steps) do
    span_steps(steps, :response)
  end

  defp span_steps(steps, phase) do
    Enum.map(steps, fn {name, step_fn} ->
      meta = %{step_name: name, step_phase: phase}
      {name,
        fn request -> :telemetry.span([:req, :step], meta,
          fn ->
            {step_fn.(request), meta}
          end)
        end
      }
    end)
  end
end
