defmodule Vutuv.HttpTest do
  @moduledoc """
  The `Req` `into:` body collector bounds memory during receipt, so a hostile
  large body is dropped once the cap is crossed instead of being buffered whole.
  """
  use ExUnit.Case, async: true

  test "capped_collector accumulates until the cap, then halts the stream" do
    collector = Vutuv.Http.capped_collector(10)
    start = {%Req.Request{}, %Req.Response{body: ""}}

    # Under the cap: keep reading.
    assert {:cont, {_req, resp}} = collector.({:data, "12345"}, start)
    assert resp.body == "12345"

    # Crossing the cap halts the stream (no further chunks are read).
    assert {:halt, {_req, resp}} =
             collector.({:data, "67890EXTRA"}, {%Req.Request{}, resp})

    assert byte_size(resp.body) >= 10
  end

  test "capped_collector rejects a non-positive cap" do
    assert_raise FunctionClauseError, fn -> Vutuv.Http.capped_collector(0) end
  end
end
