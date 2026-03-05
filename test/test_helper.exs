Code.require_file("support/integration_helpers.exs", __DIR__)

run_integration? = System.get_env("RUN_INTEGRATION") in ["1", "true", "TRUE"]

ExUnit.start(exclude: if(run_integration?, do: [], else: [integration: true]))
