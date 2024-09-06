defmodule CarReq.Adapter do
  @moduledoc "Mock adapter used for testing with `Utils.HTTPCarReq`"

  def success(request) do
    response = Req.Response.new(status: 200)
    {request, response}
  end

  def success_204(request) do
    response = Req.Response.new(status: 204)
    {request, response}
  end

  def not_found(request) do
    response = Req.Response.new(status: 404)
    {request, response}
  end

  def failed(request) do
    response = Req.Response.new(status: 500)
    {request, response}
  end

  def closed(request) do
    {request, %Req.TransportError{reason: :closed}}
  end
end
