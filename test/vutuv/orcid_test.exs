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

  describe "fetch_works/1" do
    # The summary listing (groups, first summary preferred) and the bulk
    # detail call (where the contributors are), as the public API answers.
    defp serve_works(groups, bulk) do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:req, conn.request_path})

        body =
          if String.ends_with?(conn.request_path, "/works"),
            do: %{"group" => groups},
            else: %{"bulk" => bulk}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)
    end

    defp group(put_codes),
      do: %{"work-summary" => Enum.map(put_codes, &%{"put-code" => &1, "title" => %{}})}

    defp work(put_code, attrs) do
      Map.merge(
        %{
          "put-code" => put_code,
          "title" => %{"title" => %{"value" => "Paper #{put_code}"}},
          "journal-title" => nil,
          "type" => "journal-article",
          "publication-date" => nil,
          "external-ids" => %{"external-id" => []},
          "contributors" => %{"contributor" => []},
          "url" => nil
        },
        attrs
      )
    end

    test "reads one work per group, with authors, venue, date and the DOI as a link" do
      serve_works([group([11, 12]), group([13])], [
        %{
          "work" =>
            work(11, %{
              "title" => %{"title" => %{"value" => " On Bridges "}},
              "journal-title" => %{"value" => "Span Review"},
              "publication-date" => %{
                "year" => %{"value" => "2019"},
                "month" => %{"value" => "03"}
              },
              "external-ids" => %{
                "external-id" => [
                  %{"external-id-type" => "issn", "external-id-value" => "1234-5678"},
                  %{"external-id-type" => "doi", "external-id-value" => "10.5555/spans"}
                ]
              },
              "contributors" => %{
                "contributor" => [
                  %{"credit-name" => %{"value" => "Gradient, G."}},
                  %{"credit-name" => nil},
                  %{"credit-name" => %{"value" => "Span, S."}}
                ]
              },
              "url" => %{"value" => "https://example.org/ignored-in-favour-of-the-doi"}
            })
        },
        %{"work" => work(13, %{"url" => %{"value" => "https://example.org/13"}})}
      ])

      assert {:ok, [bridges, other]} = Orcid.fetch_works(@id)

      assert bridges == %{
               put_code: 11,
               title: "On Bridges",
               authors: "Gradient, G., Span, S.",
               publisher: "Span Review",
               published_year: 2019,
               published_month: 3,
               url: "https://doi.org/10.5555/spans",
               type: "journal-article"
             }

      assert other.url == "https://example.org/13"
      assert other.authors == nil
      assert other.published_year == nil

      # The summary call, then ONE bulk call naming the preferred put code of
      # each group — never the second summary of the first group.
      assert_receive {:req, "/v3.0/" <> _ = summary_path}
      assert summary_path == "/v3.0/#{@id}/works"
      assert_receive {:req, "/v3.0/" <> _ = bulk_path}
      assert bulk_path == "/v3.0/#{@id}/works/11,13"
      refute_receive {:req, _}
    end

    test "a work without a title is dropped, an empty record answers an empty list" do
      serve_works([group([21])], [%{"work" => work(21, %{"title" => %{"title" => nil}})}])
      assert {:ok, []} = Orcid.fetch_works(@id)

      serve_works([], [])
      assert {:ok, []} = Orcid.fetch_works(@id)
    end

    test "an unknown iD is gone, an outage transient, a malformed iD never asked" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end)
      assert {:error, :gone} = Orcid.fetch_works(@id)

      stub(fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
      assert {:error, :transient} = Orcid.fetch_works(@id)

      test_pid = self()

      stub(fn conn ->
        send(test_pid, :req)
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      assert {:error, :gone} = Orcid.fetch_works("alice")
      refute_receive :req
    end
  end
end
