defmodule Sftpd.Test.TelemetryHelper do
  def attach(test_pid, events) do
    handler_id = "sftpd-test-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, measurements, metadata, pid ->
          send(pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        test_pid
      )

    handler_id
  end
end
