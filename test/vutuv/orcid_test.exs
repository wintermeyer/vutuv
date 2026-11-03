defmodule Vutuv.OrcidTest do
  @moduledoc """
  The ORCID iD primitives (issue #2350): reading an iD out of whatever a member
  pastes, the ISO 7064 MOD 11-2 check digit, and the public record lookup.

  Not async: the Req seam (`:orcid_req_options`) lives in the application env.
  """
  use Vutuv.DataCase

  alias Vutuv.Orcid

  @id "0000-0002-1825-0097"

  defp stub(fun) do
    Application.put_env(:vutuv, :orcid_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :orcid_req_options) end)
  end

  describe "parse/1" do
    test "keeps a bare iD" do
      assert Orcid.parse(@id) == @id
    end

    test "reads the iD out of every address shape ORCID hands out" do
      for input <- [
            "https://orcid.org/#{@id}",
            "http://orcid.org/#{@id}",
            "orcid.org/#{@id}/",
            "https://www.orcid.org/#{@id}",
            # The "my ORCID" page a member copies from the browser bar — the
            # shape issue #2350 was reported with.
            "https://orcid.org/my-orcid?orcid=#{@id}",
            "https://orcid.org/#{@id}/print",
            "ORCID iD: #{@id}"
          ] do
        assert Orcid.parse(input) == @id, input
      end
    end

    test "hyphenates a run of digits and upper-cases a trailing x" do
      assert Orcid.parse("0000000218250097") == @id
      assert Orcid.parse("0000-0002-1694-233x") == "0000-0002-1694-233X"
    end

    test "hands back the trimmed input when it carries no iD" do
      assert Orcid.parse("  alice  ") == "alice"
      assert Orcid.parse("0000-0002-1825") == "0000-0002-1825"
    end
  end

  describe "valid?/1" do
    test "accepts an iD whose check digit is right" do
      assert Orcid.valid?(@id)
      # The iD from the issue, and ORCID's own documented example whose check
      # digit is the X for 10.
      assert Orcid.valid?("0009-0000-8766-3947")
      assert Orcid.valid?("0000-0002-1694-233X")
    end

    test "rejects a typo: the check digit no longer matches" do
      refute Orcid.valid?("0000-0002-1825-0098")
      refute Orcid.valid?("0000-0002-1852-0097")
    end

    test "rejects anything that is not the hyphenated 16-character form" do
      refute Orcid.valid?("0000000218250097")
      refute Orcid.valid?("alice")
      refute Orcid.valid?("")
      refute Orcid.valid?(nil)
    end
  end

  test "url/1 is the canonical https address" do
    assert Orcid.url(@id) == "https://orcid.org/#{@id}"
  end

  describe "fetch_researcher_urls/1" do
    test "answers the public URLs of the record, and asks the public API" do
      test_pid = self()

      stub(fn conn ->
        send(
          test_pid,
          {:req, conn.host, conn.request_path, Plug.Conn.get_req_header(conn, "accept")}
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "researcher-url" => [
              %{"url-name" => "Lab", "url" => %{"value" => "https://lab.example.org/"}},
              %{"url-name" => "vutuv", "url" => %{"value" => "https://vutuv.example/alice"}}
            ]
          })
        )
      end)

      assert {:ok, ["https://lab.example.org/", "https://vutuv.example/alice"]} =
               Orcid.fetch_researcher_urls(@id)

      assert_receive {:req, "pub.orcid.org", "/v3.0/" <> rest, ["application/json"]}
      assert rest == @id <> "/researcher-urls"
    end

    test "a record with no links answers an empty list" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"researcher-url" => []}))
      end)

      assert {:ok, []} = Orcid.fetch_researcher_urls(@id)
    end

    test "an unknown or deactivated iD is gone, an outage is transient" do
      for {status, expected} <- [
            {404, :gone},
            {409, :gone},
            {500, :transient},
            {429, :transient}
          ] do
        stub(fn conn -> Plug.Conn.send_resp(conn, status, "{}") end)
        assert {:error, ^expected} = Orcid.fetch_researcher_urls(@id)
      end
    end

    test "a malformed iD never reaches the network" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, :req)
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      assert {:error, :gone} = Orcid.fetch_researcher_urls("alice")
      refute_receive :req
    end
  end
end
