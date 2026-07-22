defmodule Vutuv.AudiobookLengthTest do
  @moduledoc """
  The audiobook running-time lookup: a catalogue's MARC field 300 states the
  length in a handful of wordings, and only some records state one at all.
  """

  use ExUnit.Case, async: false

  alias Vutuv.AudiobookLength

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
end
