defmodule Vutuv.AudiobookLengthTest do
  @moduledoc """
  The audiobook running-time lookup: a catalogue's MARC field 300 states the
  length in a handful of wordings, and only some records state one at all.
  """

  use ExUnit.Case, async: false

  alias Vutuv.AudiobookLength
  alias Vutuv.Posts.PostReview

  @isbn "9783837170825"

  setup do
    Application.put_env(:vutuv, :fetch_book_metadata, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :fetch_book_metadata, false)
      Application.delete_env(:vutuv, :dnb_req_options)
      Application.delete_env(:vutuv, :dnb_sru_url)
    end)

    :ok
  end

  # One SRU record whose MARC 300 field carries `extent`, shaped like the
  # answers services.dnb.de really sends (namespaced tags included).
  defp stub(extent) do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <searchRetrieveResponse xmlns="http://www.loc.gov/zing/srw/">
      <numberOfRecords>1</numberOfRecords>
      <records><record><recordData>
        <marc:record xmlns:marc="http://www.loc.gov/MARC21/slim">
          <marc:datafield tag="245" ind1="1" ind2="0">
            <marc:subfield code="a">Schönhauser Allee</marc:subfield>
          </marc:datafield>
          <marc:datafield tag="300" ind1=" " ind2=" ">
            <marc:subfield code="a">#{extent}</marc:subfield>
            <marc:subfield code="b">13 Tracks</marc:subfield>
          </marc:datafield>
        </marc:record>
      </recordData></record></records>
    </searchRetrieveResponse>
    """

    Application.put_env(:vutuv, :dnb_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/xml")
        |> Plug.Conn.resp(200, xml)
      end
    )
  end

  test "reads a plain minute count" do
    stub("Online-Ressource 75 Min.")

    assert AudiobookLength.minutes(@isbn) == 75
  end

  test "reads the approximate minutes inside a CD count" do
    stub("1 Online-Ressource (2 CDs (ca. 136 Min.))")

    assert AudiobookLength.minutes(@isbn) == 136
  end

  test "reads hours and minutes together" do
    stub("6 CDs (ca. 7 Std. 20 Min.)")

    assert AudiobookLength.minutes(@isbn) == 440
  end

  test "a record that states no length is simply unknown" do
    stub("1 Online-Ressource (2 CDs)")

    assert AudiobookLength.minutes(@isbn) == nil
  end

  test "an implausible length is dropped rather than shown" do
    stub("1 CD (ca. 99999 Min.)")

    assert AudiobookLength.minutes(@isbn) == nil
  end

  test "an empty result set is unknown, not a crash" do
    Application.put_env(:vutuv, :dnb_req_options,
      plug: fn conn ->
        Plug.Conn.resp(conn, 200, "<searchRetrieveResponse><numberOfRecords>0</numberOfRecords>
        </searchRetrieveResponse>")
      end
    )

    assert AudiobookLength.minutes(@isbn) == nil
  end

  test "a blank endpoint switches the lookup off" do
    # The per-installation off switch: no catalogue, no request.
    Application.put_env(:vutuv, :dnb_sru_url, "")
    stub("Online-Ressource 75 Min.")

    assert AudiobookLength.minutes(@isbn) == nil
  end

  test "with the fetch flag off nothing is looked up" do
    Application.put_env(:vutuv, :fetch_book_metadata, false)
    stub("Online-Ressource 75 Min.")

    assert AudiobookLength.minutes(@isbn) == nil
  end

  describe "lookup/1 falling back to the work's other audio editions" do
    # Most reviews carry the PRINT ISBN, so the by-ISBN answer is empty and
    # the catalogue is searched by title + author instead. These records are
    # shaped like the real DNB answers: RDA content type in 336$b, extent in
    # 300$a, the leading article wrapped in non-sorting markers.
    defp record(opts) do
      title = Keyword.fetch!(opts, :title)
      extent = Keyword.get(opts, :extent)
      content = Keyword.get(opts, :content, "spw")
      isbn = Keyword.get(opts, :isbn)
      subtitle = Keyword.get(opts, :subtitle)

      """
      <record><recordData><marc:record xmlns:marc="http://www.loc.gov/MARC21/slim">
        #{isbn && ~s(<marc:datafield tag="020"><marc:subfield code="a">#{isbn}</marc:subfield></marc:datafield>)}
        <marc:datafield tag="245"><marc:subfield code="a">#{title}</marc:subfield>
          #{subtitle && ~s(<marc:subfield code="b">#{subtitle}</marc:subfield>)}
        </marc:datafield>
        <marc:datafield tag="336"><marc:subfield code="b">#{content}</marc:subfield></marc:datafield>
        #{extent && ~s(<marc:datafield tag="300"><marc:subfield code="a">#{extent}</marc:subfield></marc:datafield>)}
      </marc:record></recordData></record>
      """
    end

    # The by-ISBN request answers empty (a print ISBN), the title search
    # answers with `records`.
    defp stub_search(records) do
      empty =
        "<searchRetrieveResponse><numberOfRecords>0</numberOfRecords></searchRetrieveResponse>"

      found =
        "<searchRetrieveResponse><records>" <>
          Enum.join(records) <> "</records></searchRetrieveResponse>"

      Application.put_env(:vutuv, :dnb_req_options,
        plug: fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)

          body =
            if String.starts_with?(conn.query_params["query"] || "", "num="),
              do: empty,
              else: found

          Plug.Conn.resp(conn, 200, body)
        end
      )
    end

    defp review(attrs \\ []) do
      struct(
        %PostReview{
          kind: "book",
          identifier: "9783442541683",
          title: "Schönhauser Allee",
          creator: "Wladimir Kaminer",
          medium: "audiobook"
        },
        attrs
      )
    end

    test "uses the one audio edition that states a length" do
      stub_search([
        record(title: "Schönhauser Allee", extent: "Online-Ressource 75 Min.", isbn: @isbn),
        # No stated length: nothing to disagree with.
        record(title: "Schönhauser Allee", extent: "1 CD", isbn: "9783898303545"),
        # A different work that the title search dragged in.
        record(title: "Russendisko", extent: "2 CDs (ca. 125 Min.)", isbn: "9783837112801")
      ])

      assert AudiobookLength.lookup(review()) == {75, @isbn}
    end

    test "refuses to choose when the audio editions disagree" do
      # Real case: "Russendisko" has a 73-minute reading and a 125-minute
      # sequel-ish edition. Which one did the member listen to? Unknowable,
      # so the card shows no running time rather than a wrong one.
      stub_search([
        record(title: "Russendisko", extent: "Online-Ressource 73 Min.", isbn: "9783837170207"),
        record(title: "Russendisko", extent: "2 CDs (ca. 125 Min.)", isbn: "9783837112801")
      ])

      assert AudiobookLength.lookup(review(title: "Russendisko")) == nil
    end

    test "ignores print editions of the same title" do
      # Content type `txt` is the printed book — it has no running time and
      # must never be mistaken for one.
      stub_search([
        record(
          title: "Schönhauser Allee",
          extent: "190 S.",
          content: "txt",
          isbn: "9783442541683"
        )
      ])

      assert AudiobookLength.lookup(review()) == nil
    end

    test "ignores a radio play" do
      # A Hörspiel is a different production from the audiobook someone
      # reviewed, and it is regularly the only record with a length.
      stub_search([
        record(
          title: "Schönhauser Allee",
          subtitle: "das Hörspiel zum Kinofilm",
          extent: "1 CD (ca. 81 Min.)",
          isbn: "9783867178525"
        )
      ])

      assert AudiobookLength.lookup(review()) == nil
    end

    test "matches a title the catalogue wraps in non-sorting markers" do
      stub_search([
        record(
          title: "&#152;Der&#156; Vorleser",
          extent: "4 CDs (ca. 4 Std. 30 Min.)",
          isbn: "9783895843532"
        )
      ])

      assert AudiobookLength.lookup(review(title: "Der Vorleser")) == {270, "9783895843532"}
    end

    test "matches a title the catalogue delivers decomposed (NFD)" do
      # Real DNB data is NFD ("Scho" + combining diaeresis) while anything
      # typed into the composer is composed — without normalizing, every
      # umlaut title silently failed to match.
      decomposed = String.normalize("Schönhauser Allee", :nfd)
      refute decomposed == "Schönhauser Allee"

      stub_search([record(title: decomposed, extent: "75 Min.", isbn: @isbn)])

      assert AudiobookLength.lookup(review()) == {75, @isbn}
    end

    test "the review's own ISBN wins over any search" do
      stub("Online-Ressource 75 Min.")

      # An exact answer carries no source ISBN: the card prints it plain,
      # not as an approximation.
      assert AudiobookLength.lookup(review(identifier: @isbn)) == {75, nil}
    end

    test "a review without a title or author never searches" do
      stub_search([record(title: "Schönhauser Allee", extent: "75 Min.", isbn: @isbn)])

      assert AudiobookLength.lookup(review(creator: nil)) == nil
    end
  end
end
