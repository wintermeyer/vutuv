defmodule VutuvWeb.WellKnownController do
  @moduledoc """
  The /.well-known endpoints.

  **Agent skills** (Cloudflare-led draft v0.2.0): an index.json naming the
  skill files, each carrying a sha256 digest over the exact served bytes.
  The skill (`priv/agent_skills/SKILL.md`) is compiled in like the dev
  docs, and the digest is computed at compile time from the same binary
  that is served — it cannot drift. Both responses are CORS-open for
  browser-based agents.

  **security.txt** (RFC 9116): the vulnerability-report contact, served
  under /.well-known and the root alias (the latter is already whitelisted
  in `VutuvWeb.Plug.AgentFormat`).

  **NodeInfo** (issue #1448): how the fediverse's directory layer discovers
  that this installation exists. `/.well-known/nodeinfo` is the link
  document; the documents themselves live at `/system/nodeinfo/2.1` and
  `/system/nodeinfo/2.0`. `Vutuv.NodeInfo` decides what they say.
  """

  use VutuvWeb, :controller

  alias Vutuv.Languages
  alias Vutuv.NodeInfo
  alias VutuvWeb.AgentDocs

  @external_resource "priv/agent_skills/SKILL.md"
  @skill_md File.read!("priv/agent_skills/SKILL.md")
  @skill_digest "sha256:" <> Base.encode16(:crypto.hash(:sha256, @skill_md), case: :lower)
  @skill_description @skill_md
                     |> then(&Regex.run(~r/^description: (.+)$/m, &1, capture: :all_but_first))
                     |> hd()

  @skills_schema "https://schemas.agentskills.io/discovery/0.2.0/schema.json"
  @skill_path "/.well-known/agent-skills/vutuv/SKILL.md"

  def agent_skills_index(conn, _params) do
    index = %{
      "$schema" => @skills_schema,
      "skills" => [
        %{
          "name" => "vutuv",
          "type" => "skill-md",
          "description" => @skill_description,
          "url" => AgentDocs.abs_url(@skill_path),
          "digest" => @skill_digest
        }
      ]
    }

    conn
    |> well_known_headers()
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(index, pretty: true))
  end

  def agent_skill(conn, _params) do
    conn
    |> well_known_headers()
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, @skill_md)
  end

  @doc """
  The NodeInfo link document (a JRD): which schema versions this installation
  serves and where. The specification names no media type for this one, so it
  goes out as plain JSON, which is what every implementation serves and every
  consumer expects.
  """
  def nodeinfo_links(conn, _params) do
    conn
    |> well_known_headers()
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"links" => NodeInfo.links()}))
  end

  @doc """
  One NodeInfo document. An unserved schema version 404s rather than answering
  something the consumer would then have to guess at.

  The content type is the one the specification asks for: `application/json`
  with a `profile` parameter naming the schema, so a consumer knows which
  document it got without parsing it.
  """
  def nodeinfo(conn, %{"version" => version}) do
    case NodeInfo.document(version) do
      nil ->
        conn |> put_status(:not_found) |> text("Not Found")

      document ->
        profile = ~s(profile="http://nodeinfo.diaspora.software/ns/schema/#{version}#")

        conn
        |> well_known_headers()
        |> put_resp_header("content-type", "application/json; #{profile}; charset=utf-8")
        |> send_resp(200, Jason.encode!(document))
    end
  end

  def security_txt(conn, _params) do
    expires = DateTime.utc_now() |> DateTime.add(180, :day) |> DateTime.truncate(:second)
    {_name, operator_email} = Application.fetch_env!(:vutuv, :operator_recipient)

    body = """
    Contact: mailto:#{operator_email}
    Expires: #{DateTime.to_iso8601(expires)}
    Preferred-Languages: #{Enum.join(Languages.site_locales(), ", ")}
    Canonical: #{AgentDocs.abs_url("/.well-known/security.txt")}
    """

    conn
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  defp well_known_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("cache-control", "public, max-age=3600")
  end
end
