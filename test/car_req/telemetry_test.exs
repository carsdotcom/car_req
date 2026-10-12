defmodule CarReq.TelemetryTest do
  use ExUnit.Case, async: false

  alias CarReq.Adapter

  def raise_with_arguments(credential) do
    :erlang.error(%CaseClauseError{term: credential}, [credential])
  end

  defmodule TestTelemetryMod do
    use CarReq, compressed: true
  end

  for {phase, spanner} <- [request: :request_spanner, response: :response_spanner] do
    test "#{phase} step exceptions are sanitized without changing the raised exception" do
      phase = unquote(phase)
      credential = "synthetic-step-secret-CORE-7947"
      exception = %CaseClauseError{term: credential}

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:req, :step, :start],
          [:req, :step, :stop],
          [:req, :step, :exception]
        ])

      steps = [sensitive_step: &__MODULE__.raise_with_arguments/1]

      [{:sensitive_step, step}] = apply(CarReq.Telemetry, unquote(spanner), [steps])

      stacktrace =
        try do
          step.(credential)
          flunk("expected the step to raise")
        rescue
          error in CaseClauseError ->
            assert error == exception
            __STACKTRACE__
        end

      assert [{__MODULE__, :raise_with_arguments, [^credential], _} | _] = stacktrace

      assert_received {[:req, :step, :start], ^ref, start_measurements, start_metadata}
      assert_received {[:req, :step, :exception], ^ref, measurements, metadata}
      assert metadata.kind == :error
      assert metadata.reason == {:unexpected_exception, "CaseClauseError"}
      assert metadata.stacktrace == []
      assert metadata.step_name == :sensitive_step
      assert metadata.step_phase == phase
      assert metadata.telemetry_span_context == start_metadata.telemetry_span_context
      assert measurements.duration >= 0
      assert measurements.monotonic_time >= start_measurements.monotonic_time
      assert is_integer(start_measurements.system_time)
      refute inspect([start_metadata, metadata], limit: :infinity) =~ credential
      refute_received {[:req, :step, :stop], ^ref, _, _}
    end

    test "#{phase} step success preserves its result and span context" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:req, :step, :start],
          [:req, :step, :stop],
          [:req, :step, :exception]
        ])

      [{:identity, step}] =
        apply(CarReq.Telemetry, unquote(spanner), [[identity: fn value -> value end]])

      assert step.(:result) == :result
      assert step.(:result) == :result

      assert_receive {[:req, :step, :start], ^ref, _, first_start}
      assert_receive {[:req, :step, :stop], ^ref, first_measurements, first_stop}
      assert_receive {[:req, :step, :start], ^ref, _, second_start}
      assert_receive {[:req, :step, :stop], ^ref, _, second_stop}
      assert first_start == first_stop
      assert second_start == second_stop
      assert first_stop.step_name == :identity
      assert first_stop.step_phase == unquote(phase)
      assert first_measurements.duration >= 0
      refute first_start.telemetry_span_context == second_start.telemetry_span_context
      refute_received {[:req, :step, :exception], ^ref, _, _}
    end
  end

  for kind <- [:throw, :exit] do
    test "step #{kind} keeps its original propagation and telemetry" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:req, :step, :exception]])

      [{:failure, step}] =
        CarReq.Telemetry.request_spanner(
          failure: fn _ -> :erlang.raise(unquote(kind), :original_reason, []) end
        )

      assert catch_kind(unquote(kind), step) == :original_reason
      assert_received {[:req, :step, :exception], ^ref, _, metadata}
      assert metadata.kind == unquote(kind)
      assert metadata.reason == :original_reason
      assert metadata.stacktrace == []
    end
  end

  defp catch_kind(:throw, step), do: catch_throw(step.(:request))
  defp catch_kind(:exit, step), do: catch_exit(step.(:request))

  test "raw Erlang errors expose only their normalized exception module" do
    credential = "synthetic-erlang-secret-CORE-7947"
    ref = :telemetry_test.attach_event_handlers(self(), [[:req, :step, :exception]])

    [{:failure, step}] =
      CarReq.Telemetry.request_spanner(failure: fn term -> :erlang.error(:badarg, [term]) end)

    assert_raise ArgumentError, fn -> step.(credential) end

    assert_received {[:req, :step, :exception], ^ref, _, metadata}
    assert metadata.reason == {:unexpected_exception, "ArgumentError"}
    assert metadata.stacktrace == []
    refute inspect(metadata, limit: :infinity) =~ credential
  end

  test "steps emit telemtry events" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:req, :step, :start],
        [:req, :step, :stop]
      ])

    {:ok, resp} =
      TestTelemetryMod.request(
        method: :get,
        url: "http://www.example.com/200",
        adapter: &Adapter.success/1
      )

    assert resp.status == 200

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :fuse, step_phase: :request}}

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :put_user_agent, step_phase: :request}}

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :compressed, step_phase: :request}}

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :auth, step_phase: :request}}

    assert_received {[:req, :step, :stop], ^ref, %{duration: duration},
                     %{step_name: :fuse, step_phase: :request}}

    assert duration > 0

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :fuse, step_phase: :response}}

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :decompress_body, step_phase: :response}}

    assert_received {[:req, :step, :stop], ^ref, %{duration: duration},
                     %{step_name: :decompress_body, step_phase: :response}}

    assert duration > 0

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :decode_body, step_phase: :response}}

    assert_received {[:req, :step, :stop], ^ref, %{duration: duration},
                     %{step_name: :decode_body}}

    assert duration > 0
  end

  @tag :capture_log
  test "when the circuit breaker blows, telemetry still emitted" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:req, :step, :start],
        [:req, :step, :stop]
      ])

    for _i <- 0..10 do
      {:ok, _resp} =
        TestTelemetryMod.request(
          method: :get,
          url: "http://www.example.com",
          adapter: &Adapter.failed/1
        )

      assert_received {[:req, :step, :start], ^ref, _timestamps,
                       %{step_name: :fuse, step_phase: :request}}

      assert_received {[:req, :step, :stop], ^ref, %{duration: _duration},
                       %{step_name: :fuse, step_phase: :request}}
    end

    {:error, %RuntimeError{message: "circuit breaker is open"}} =
      TestTelemetryMod.request(
        method: :get,
        url: "http://www.example.com",
        adapter: &Adapter.failed/1
      )

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :fuse, step_phase: :request}}

    assert_received {[:req, :step, :stop], ^ref, %{duration: duration},
                     %{step_name: :fuse, step_phase: :request}}

    assert duration > 0

    # reset the circuit
    :fuse.reset(TestTelemetryMod)
  end
end
