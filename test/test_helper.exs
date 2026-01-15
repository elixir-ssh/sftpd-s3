# Start required applications for tests
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:hackney)
{:ok, _} = Application.ensure_all_started(:ssh)

# Compile test support modules
Code.require_file("support/ssh_keys.ex", __DIR__)

ExUnit.start()
