defmodule CarReq.Adapter do
  @moduledoc """
  Defines a behaviour for a lower-level HTTP client that will make the actual requests.
  It has to implement `c:CarReq.Adapter.run/1`.
  """

  @doc """
    Invoked when a request step runs.

    ## Arguments

    - `request` - `Req.Request` struct that stores the request data
  """
  @callback run(request :: Req.Request.t()) ::
              {Req.Request.t(), Req.Response.t() | Exception.t()}
end
