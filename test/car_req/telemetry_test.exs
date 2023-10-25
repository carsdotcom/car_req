defmodule CarReq.TelemetryTest do
  use ExUnit.Case, async: false

  alias CarReq.Adapter

  defmodule TestTelemetryMod do
    use CarReq, compressed: true
  end

  test "steps emit telemtry events" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:req, :step, :start],
        [:req, :step, :stop]
      ])

    {:ok, resp} = TestTelemetryMod.request(method: :get, url: "http://www.example.com/200", adapter: &Adapter.success/1)
    assert resp.status == 200

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :fuse, step_phase: :request}}

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :put_user_agent, step_phase: :request}}

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :compressed, step_phase: :request}}

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :auth, step_phase: :request}}

    assert_received {[:req, :step, :stop], ^ref, %{duration: duration}, %{step_name: :fuse, step_phase: :request}}

    assert duration > 0

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :fuse, step_phase: :response}}

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :decompress_body, step_phase: :response}}

    assert_received {[:req, :step, :stop], ^ref, %{duration: duration}, %{step_name: :decompress_body, step_phase: :response}}
    assert duration > 0
    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :decode_body, step_phase: :response}}

    assert_received {[:req, :step, :stop], ^ref, %{duration: duration}, %{step_name: :decode_body}}
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
      {:ok, _resp} = TestTelemetryMod.request(method: :get, url: "http://www.example.com", adapter: &Adapter.failed/1)

      assert_received {[:req, :step, :start], ^ref, _timestamps,
                       %{step_name: :fuse, step_phase: :request}}
      assert_received {[:req, :step, :stop], ^ref, %{duration: _duration}, %{step_name: :fuse, step_phase: :request}}
    end

    {:error, %RuntimeError{message: "circuit breaker is open"}} = TestTelemetryMod.request(method: :get, url: "http://www.example.com", adapter: &Adapter.failed/1)

    assert_received {[:req, :step, :start], ^ref, _timestamps,
                     %{step_name: :fuse, step_phase: :request}}
    assert_received {[:req, :step, :stop], ^ref, %{duration: duration}, %{step_name: :fuse, step_phase: :request}}
    assert duration > 0

    # reset the circuit
    :fuse.reset(TestTelemetryMod)
  end
end