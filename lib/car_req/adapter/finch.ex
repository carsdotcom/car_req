defmodule CarReq.Adapter.Finch do
  @moduledoc """
  Default implementation of `CarReq.Adapter` that uses [finch](https://github.com/sneako/finch).
  """
  @behaviour CarReq.Adapter

  @impl true
  def run(%Req.Request{} = request), do: Req.Steps.run_finch(request)
end
